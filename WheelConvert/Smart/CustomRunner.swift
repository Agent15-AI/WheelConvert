import AppKit
import UniformTypeIdentifiers

/// Runs a custom petal. Items are handed over as arguments, input files or standard input — never pasted
/// into a command line — so a file name full of quotes, `$()`, backticks or newlines stays a name.
@MainActor
enum CustomRunner {
    nonisolated static let outputLimit = 10_000_000

    /// - Returns: The work, for the developer modes to wait on; nil when it didn't start or finished at once.
    @discardableResult
    static func run(_ petal: CustomPetal, content: DragContent) -> Task<Void, Never>? {
        guard petal.accepts(content) else { return nil }
        if petal.needsApproval && !SmartRunner.headless {
            guard approve(petal, content: content) else { return nil }
            if let index = AppSettings.shared.customPetals.firstIndex(where: { $0.id == petal.id }) {
                AppSettings.shared.customPetals[index].approved = petal.actionDescription
            }
        }
        let files = content.files
        switch petal.kind {
        case .shell, .shortcut:
            let name = files.count == 1 ? files[0].lastPathComponent : files.isEmpty ? petal.name : String(localized: "\(files.count) files")
            let job = JobCenter.shared.runBatch(title: petal.name, items: files, name: name) { _ in
                let output = petal.kind == .shell ? try await shell(petal, content: content) : try await shortcut(petal, content: content)
                guard let output, !output.isEmpty else { return [] }
                let base = (files.first.map(OutputNaming.baseName(of:)) ?? text(of: content).map(TextTools.fileName) ?? petal.name) + " " + petal.name
                let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: files.first), base: base, extension: fileExtension(for: output))
                return [try await AtomicOutput.write(to: destination) { try output.write(to: $0) }]
            }
            guard let job else { return nil }
            return Task {
                await job.task?.value
                if SmartRunner.headless {
                    job.outputs.forEach { print("OUT:\($0.path)") }
                    job.failures.forEach { print("FAIL:\($0.name)\t\($0.message)") }
                }
            }
        case .openWith:
            do {
                let items = try openableItems(content)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(items, withApplicationAt: URL(fileURLWithPath: petal.appPath), configuration: configuration) { _, error in
                    if let error { DispatchQueue.main.async { FileActions.alert(String(localized: "“\(petal.name)” couldn’t open the item: \(error.localizedDescription)")) } }
                }
            } catch {
                FileActions.alert(error.localizedDescription)
            }
        case .urlScheme:
            for url in urls(petal, content: content) {
                if SmartRunner.headless { print("OPEN:\(url.absoluteString)") } else { NSWorkspace.shared.open(url) }
            }
        }
        return nil
    }

    // MARK: Actions

    static func text(of content: DragContent) -> String? {
        switch content {
        case .text(let text, _): text
        case .link(let url): url.absoluteString
        default: nil
        }
    }

    /// Only the variables a login shell would have, plus the usual Homebrew folders on PATH; nothing else from
    /// WheelConvert's own environment.
    nonisolated static func environment(from inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] { environment[key] = inherited[key] }
        return environment
    }

    /// The person's script runs with zsh; files arrive as "$1", "$2"…, text and links on standard input.
    nonisolated static func shell(_ petal: CustomPetal, content: DragContent) async throws -> Data? {
        let files = content.files
        let input = await MainActor.run { text(of: content) }.map { Data($0.utf8) }
        let result = try await limited(petal.timeoutSeconds) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-c", petal.script, "WheelConvert"] + files.map(\.path),
                                        environment: environment(), replacingEnvironment: true, input: input, stdoutLimit: outputLimit,
                                        currentDirectory: files.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        guard result.status == 0 else {
            let detail = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw WheelError("The script stopped with exit code \(Int(result.status)). \(detail)")
        }
        return result.stdout
    }

    /// Runs the named Shortcut with the item as input; text and links go in as a .txt file.
    nonisolated static func shortcut(_ petal: CustomPetal, content: DragContent) async throws -> Data? {
        let scratch = try ScratchDirectory()
        var inputs = content.files
        if let text = await MainActor.run(body: { text(of: content) }) {
            let file = scratch.file("Input.txt")
            try text.write(to: file, atomically: false, encoding: .utf8)
            inputs = [file]
        }
        let output = scratch.file("output")
        // Options first and "--" before the name, so a name starting with "-" is still a name.
        let arguments = inputs.flatMap { ["--input-path", $0.path] } + ["--output-path", output.path, "--", petal.shortcutName]
        let result = try await limited(petal.timeoutSeconds) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments, environment: environment(), replacingEnvironment: true)
        }
        guard result.status == 0 else {
            let detail = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw WheelError("The Shortcut “\(petal.shortcutName)” didn’t finish. \(detail)")
        }
        guard let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
        guard size <= outputLimit else { throw WheelError("The Shortcut’s result is larger than 10 MB.") }
        return try Data(contentsOf: output)
    }

    /// Ends the work (and its process) when it runs over the petal's time limit.
    nonisolated static func limited<T: Sendable>(_ seconds: Int, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                throw WheelError("It took longer than \(max(1, seconds)) seconds and was stopped.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// What an app is given: files and links as they are, text as a .txt file.
    private static func openableItems(_ content: DragContent) throws -> [URL] {
        switch content {
        case .files(let urls): return urls
        case .link(let url): return [url]
        case .text(let text, _):
            let folder = DragContent.scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(TextTools.fileName(text) + ".txt")
            try text.write(to: file, atomically: false, encoding: .utf8)
            return [file]
        case .image: return []
        }
    }

    /// One URL per file (at most 20), or one for text and links.
    static func urls(_ petal: CustomPetal, content: DragContent) -> [URL] {
        let files = content.files
        if files.isEmpty {
            let value = text(of: content) ?? ""
            return [CustomPetal.url(from: petal.urlTemplate, path: "", text: value, link: value)].compactMap { $0 }
        }
        return files.prefix(20).compactMap { CustomPetal.url(from: petal.urlTemplate, path: $0.path, text: $0.path, link: $0.absoluteString) }
    }

    nonisolated static func fileExtension(for data: Data) -> String {
        if data.starts(with: Data("%PDF".utf8)) { return "pdf" }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
           let ext = UTType(type as String)?.preferredFilenameExtension { return ext }
        return String(data: data, encoding: .utf8) != nil ? "txt" : "data"
    }

    // MARK: Approval

    /// Shows exactly what will run before a petal's first run, and again after its action changes.
    private static func approve(_ petal: CustomPetal, content: DragContent) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Run “\(petal.name)”?")
        let input: String = switch content {
        case .files(let urls): urls.count == 1 ? String(localized: "“\(urls[0].lastPathComponent)” is passed as \"$1\" or input.")
            : String(localized: "\(urls.count) files are passed as \"$1\", \"$2\"… or input.")
        case .text: String(localized: "The text is passed on standard input or as a .txt file.")
        case .link: String(localized: "The link is passed on standard input or as text.")
        case .image: ""
        }
        alert.informativeText = String(localized: "This custom petal runs the action below, which you set up in Settings → Custom. Only run actions you wrote or understand.") + "\n\n" + input
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        text.string = petal.actionDescription
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        text.setAccessibilityLabel(String(localized: "Action"))
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        // Return cancels: running has to be a deliberate click.
        alert.addButton(withTitle: String(localized: "Run")).keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
