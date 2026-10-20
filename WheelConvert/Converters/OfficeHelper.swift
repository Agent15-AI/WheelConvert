import Foundation

/// Runs the bundled Java helper (Apache POI + PDFBox) for slides and spreadsheets.
enum OfficeHelper {
    static let timeLimit: TimeInterval = 300

    /// Runs one helper command. Returns the files it reported writing.
    static func run(_ command: String, _ input: URL, _ output: URL, extra: [String] = [], progress: @escaping (Double) -> Void) async throws -> [URL] {
        let scratch = try ScratchDirectory()
        let memory = ProcessInfo.processInfo.physicalMemory
        let heap = memory >= 16 << 30 ? "2g" : "1g"
        let arguments = [
            "-XX:+UseSerialGC", "-XX:TieredStopAtLevel=1", "-XX:-UsePerfData", "-Xshare:auto", "-Xss4m", "-Xmx\(heap)",
            "-Djava.awt.headless=true", "-Dapple.awt.UIElement=true", "-Dfile.encoding=UTF-8",
            "-Djava.io.tmpdir=\(scratch.url.path)", "-Dlog4j2.loggerContextFactory=org.apache.logging.log4j.simple.SimpleLoggerContextFactory",
            "-cp", Bundled.officeLib.path + "/*", "WheelConvertOffice", command, input.path, output.path,
        ] + extra
        let outputs = OutputList()
        let runner = Task {
            try await ProcessRunner.run(Bundled.java, arguments, onStdoutLine: { line in
                if line.hasPrefix("PROGRESS:"), let value = Double(line.dropFirst(9)) { progress(value) }
                if line.hasPrefix("OUT:") { outputs.append(URL(fileURLWithPath: String(line.dropFirst(4)))) }
            })
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeLimit * 1_000_000_000))
            runner.cancel()
        }
        defer { watchdog.cancel() }
        let result: ProcessOutput
        do {
            result = try await withTaskCancellationHandler { try await runner.value } onCancel: { runner.cancel() }
        } catch is CancellationError {
            if !Task.isCancelled { throw WheelError("The Office converter stopped or exceeded its five-minute limit.") }
            throw CancellationError()
        }
        guard result.status == 0 else {
            let message = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if result.status == 2, !message.isEmpty { throw WheelError(verbatim: Bundle.main.localizedString(forKey: message, value: message, table: nil)) }
            if message.contains("OutOfMemoryError") { throw WheelError("This document is too large to convert on this Mac.") }
            // Java exception names mean nothing to people; an unreadable input is by far the common cause.
            throw WheelError("The file couldn’t be read. It may be damaged, password-protected or in an unsupported format.")
        }
        let files = outputs.values.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { throw WheelError("The converter finished without creating an output file.") }
        return files
    }

    static func slides(_ source: URL, to target: FileFormat, staging: URL, base: String, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let name = OutputNaming.sanitize(base)
        switch target {
        case .pdf:
            return try await run("slides", source, staging.appendingPathComponent(name + ".pdf"), extra: ["pdf"], progress: progress)
        case .png, .jpg:
            let folder = staging.appendingPathComponent("slides", isDirectory: true)
            var files = try await run("slides", source, folder, extra: [target.fileExtension, "2"], progress: progress)
            if files.count == 1, let only = files.first {
                // A one-slide deck becomes one image with the deck's name.
                let renamed = staging.appendingPathComponent(name + "." + target.fileExtension)
                try FileManager.default.moveItem(at: only, to: renamed)
                files = [renamed]
            }
            return files
        default:
            throw WheelError("Conversion to \(target.title) is unavailable.")
        }
    }

    static func spreadsheet(_ source: URL, from input: FileFormat, to target: FileFormat, staging: URL, base: String,
                            progress: @escaping (Double) -> Void) async throws -> [URL] {
        let name = OutputNaming.sanitize(base)
        if target == .pdf {
            let html = staging.appendingPathComponent(".sheet.html")
            _ = try await run("sheet2html", source, html, progress: { progress($0 * 0.5) })
            let markup = try String(contentsOf: html, encoding: .utf8)
            try? FileManager.default.removeItem(at: html)
            let destination = staging.appendingPathComponent(name + ".pdf")
            var page = DOCXWriter.defaultPage()
            let columns = Int(markup.range(of: #"<!--columns:(\d+)-->"#, options: .regularExpression).map { markup[$0].filter(\.isNumber) } ?? "") ?? 0
            if columns > 7 { page = .init(width: page.height, height: page.width) }
            page.top = 36; page.bottom = 36; page.left = 36; page.right = 36
            try await DocumentPrinter.printHTML(markup, page: page, to: destination)
            return [destination]
        }
        return try await run("sheet", source, staging.appendingPathComponent(name + "." + target.fileExtension), progress: progress)
    }
}

private final class OutputList: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var values: [URL] { lock.withLock { urls } }
}
