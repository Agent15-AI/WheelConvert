import AVFoundation
import AppIntents
import AppKit

/// `WheelConvert --convert <file> <format>` converts one file and prints the saved paths.
enum CommandLineMode {
    static func start() {
        let args = CommandLine.arguments
        Task { @MainActor in
            do {
                if let i = args.firstIndex(of: "--snapshot") {
                    try await SnapshotMode.run(Array(args[(i + 1)...]))
                    exit(0)
                }
                if let i = args.firstIndex(of: "--preview-check"), i + 1 < args.count {
                    try await previewCheck(URL(fileURLWithPath: args[i + 1]), seek: i + 2 < args.count ? Double(args[i + 2]) : nil)
                    exit(0)
                }
                if let i = args.firstIndex(of: "--batch"), i + 2 < args.count {
                    guard let format = FileFormat(rawValue: args[i + 1]) else { throw WheelError("Unknown format \(args[i + 1])") }
                    let end = args.firstIndex(of: "--cancel-after") ?? args.count
                    let files = args[(i + 2)..<end].map { URL(fileURLWithPath: $0).standardizedFileURL }
                    guard let job = JobCenter.shared.convert(files, to: format) else { throw WheelError("The batch did not start.") }
                    if end < args.count, let delay = Double(args[end + 1]) {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        job.cancel()
                    }
                    await job.task?.value
                    job.outputs.forEach { print("OUT:\($0.path)") }
                    job.failures.forEach { print("FAIL:\($0.name)\t\($0.message)") }
                    print("PHASE:\(job.phase)")
                    exit(0)
                }
                if let i = args.firstIndex(of: "--preset"), i + 2 < args.count {
                    guard let preset = Preset.named(args[i + 1], in: AppSettings.shared.presets) else { throw WheelError("Unknown preset \(args[i + 1])") }
                    let files = args[(i + 2)...].map { URL(fileURLWithPath: $0).standardizedFileURL }
                    guard preset.applies(to: files) else { throw WheelError("“\(preset.name)” doesn’t apply to these files.") }
                    guard let job = preset.run(on: files) else { throw WheelError("The preset did not start.") }
                    await job.task?.value
                    job.outputs.forEach { print("OUT:\($0.path)") }
                    job.failures.forEach { print("FAIL:\($0.name)\t\($0.message)") }
                    exit(job.failures.isEmpty ? 0 : 1)
                }
                if let i = args.firstIndex(of: "--watch"), i + 3 < args.count, let seconds = Double(args[i + 3]) {
                    guard let preset = Preset.named(args[i + 2], in: AppSettings.shared.presets) else { throw WheelError("Unknown preset \(args[i + 2])") }
                    var jobs: [JobState] = []
                    FolderWatcher.shared.onJob = { jobs.append($0) }
                    FolderWatcher.shared.watch([.init(folder: URL(fileURLWithPath: args[i + 1], isDirectory: true), preset: preset)])
                    FileHandle.standardOutput.write(Data("WATCHING\n".utf8))
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    FolderWatcher.shared.watch([])
                    for job in jobs {
                        await job.task?.value
                        job.outputs.forEach { print("OUT:\($0.path)") }
                        job.failures.forEach { print("FAIL:\($0.name)\t\($0.message)") }
                    }
                    exit(0)
                }
                if let i = args.firstIndex(of: "--intent"), i + 3 < args.count {
                    try await intentCheck(args[i + 1], args[i + 2], files: Array(args[(i + 3)...]))
                    exit(0)
                }
                if let i = args.firstIndex(of: "--outputs"), i + 1 < args.count {
                    let url = URL(fileURLWithPath: args[i + 1])
                    let formats = FileFormat.detect(url).map { ConversionMatrix.outputs(for: $0) } ?? []
                    print(formats.map(\.rawValue).joined(separator: " "))
                    exit(0)
                }
                if let i = args.firstIndex(of: "--convert"), i + 2 < args.count {
                    let source = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
                    guard let format = FileFormat(rawValue: args[i + 2]) else { throw WheelError("Unknown format \(args[i + 2])") }
                    var options = AppSettings.shared.options(for: format)
                    if let j = args.firstIndex(of: "--options"), j + 1 < args.count, let data = args[j + 1].data(using: .utf8) {
                        options = try JSONDecoder().decode(ConversionOptions.self, from: data, defaults: options)
                    }
                    let outputs = try await Converter.convert(source, to: format, options: options) { _ in }
                    outputs.forEach { print("OUT:\($0.path)") }
                    exit(0)
                }
                if let i = args.firstIndex(of: "--tool"), i + 2 < args.count {
                    guard let tool = ToolKind(rawValue: args[i + 1]) else { throw WheelError("Unknown tool \(args[i + 1])") }
                    let end = args.firstIndex(of: "--options") ?? args.count
                    let files = args[(i + 2)..<end].map { URL(fileURLWithPath: $0).standardizedFileURL }
                    let json = args.firstIndex(of: "--options").flatMap { $0 + 1 < args.count ? args[$0 + 1].data(using: .utf8) : nil }
                    if tool == .readQRCode {
                        for code in try ImageTools.readCodes(files, progress: { _ in }) { print("CODE:\(code.source)\t\(code.payload)") }
                        exit(0)
                    }
                    let request = try ToolRequest.decode(tool, json: json)
                    let outputs = request.isBatch
                        ? try await ToolRunner.runBatch(request, on: files) { _ in }
                        : try await files.asyncFlatMap { try await ToolRunner.run(request, on: $0) { _ in } }
                    outputs.forEach { print("OUT:\($0.path)") }
                    exit(0)
                }
                throw WheelError("usage: WheelConvert --convert <file> <format> [--options <json>] | --tool <tool> <files…> [--options <json>]")
            } catch {
                FileHandle.standardError.write(Data("ERROR:\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

extension CommandLineMode {
    /// `--intent convert <format> | compress <strength[:MB]> | preset <name>` runs a Shortcuts action on
    /// files ("data:<path>" passes a file as data, the way Shortcuts sometimes does).
    static func intentCheck(_ action: String, _ argument: String, files paths: [String]) async throws {
        let files = try paths.map { path -> IntentFile in
            guard path.hasPrefix("data:") else { return IntentFile(fileURL: URL(fileURLWithPath: path).standardizedFileURL) }
            let url = URL(fileURLWithPath: String(path.dropFirst(5)))
            return IntentFile(data: try Data(contentsOf: url), filename: url.lastPathComponent)
        }
        let outputs: [IntentFile]
        switch action {
        case "convert":
            guard let format = ShortcutFormat(rawValue: argument) else { throw WheelError("Unknown format \(argument)") }
            outputs = try await ConvertFileIntent.convert(files, to: format)
        case "compress":
            let parts = argument.split(separator: ":")
            outputs = try await CompressFileIntent.compress(files, strength: ShortcutStrength(rawValue: String(parts[0])) ?? .balanced,
                                                            targetMegabytes: parts.count > 1 ? Double(parts[1]) : nil)
        case "preset":
            guard let preset = await MainActor.run(body: { Preset.named(argument, in: AppSettings.shared.presets) }) else { throw WheelError("Unknown preset \(argument)") }
            outputs = try await ApplyPresetIntent.apply(preset.id, to: files)
        default:
            throw WheelError("Unknown action \(action)")
        }
        for file in outputs { print(file.fileURL.map { "OUT:\($0.path)" } ?? "DATA:\(file.filename)\t\(file.data.count)") }
    }

    /// `--preview-check <file> [seconds]`: how long a tool preview takes to start playing, and to play
    /// again after a seek. Prints `PLAYING:<s>` and `SEEKED:<s>`.
    @MainActor
    static func previewCheck(_ url: URL, seek target: Double?) async throws {
        let preview = MediaPreview(url: url)
        defer { preview.stop() }
        let started = Date()
        await preview.load(video: true)
        guard let player = preview.player else { throw WheelError(verbatim: preview.error ?? "No player.") }
        player.play()
        try await waitUntil(player, passes: 0.25, preview: preview)
        print(String(format: "PLAYING:%.2f", Date().timeIntervalSince(started)))
        guard let target else { return }
        let seeked = Date()
        preview.seek(target)
        player.play()
        try await waitUntil(player, passes: target + 0.25, preview: preview)
        print(String(format: "SEEKED:%.2f", Date().timeIntervalSince(seeked)))
    }

    @MainActor
    private static func waitUntil(_ player: AVPlayer, passes seconds: Double, preview: MediaPreview) async throws {
        let deadline = Date().addingTimeInterval(30)
        while player.currentTime().seconds < seconds {
            if let error = preview.error { throw WheelError(verbatim: error) }
            guard Date() < deadline else { throw WheelError("The preview did not start playing within 30 seconds.") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

extension Sequence {
    func asyncFlatMap<T>(_ transform: (Element) async throws -> [T]) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result += try await transform(element) }
        return result
    }
}
