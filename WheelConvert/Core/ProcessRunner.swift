import Foundation

/// A failure worth showing to the person, worded for them.
struct WheelError: LocalizedError, Equatable {
    let message: String
    init(_ message: LocalizedStringResource) { self.message = String(localized: message) }
    /// Text that is already worded for people, such as a helper's own message or an already localized one.
    init(verbatim message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Locates the tools embedded in WheelConvert.app/Contents/Resources.
enum Bundled {
    static var resources: URL { Bundle.main.resourceURL! }
    static var ffmpeg: URL { resources.appendingPathComponent("Tools/ffmpeg") }
    static var ffprobe: URL { resources.appendingPathComponent("Tools/ffprobe") }
    static var exiftool: URL { resources.appendingPathComponent("Tools/ExifTool/exiftool") }
    static var java: URL { resources.appendingPathComponent("Office/runtime/bin/java") }
    static var officeLib: URL { resources.appendingPathComponent("Office/lib") }
    static var pagesBridge: URL { resources.appendingPathComponent("JS/pages-bridge.js") }
    static var docxRenderer: URL { resources.appendingPathComponent("JS/docx-render.js") }
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/tar")
}

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: String
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a helper process off the main thread, streaming lines and honoring task cancellation.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onStdoutLine: ((String) -> Void)? = nil,
        onStderrLine: ((String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector(onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                // One blocking reader per pipe keeps each stream's chunks in order; the result is
                // delivered once the process has exited and both pipes reached end of file.
                let done = DispatchGroup()
                func drain(_ handle: FileHandle, _ append: @escaping (Data) -> Void) {
                    done.enter()
                    DispatchQueue.global(qos: .utility).async {
                        while case let data = handle.availableData, !data.isEmpty { append(data) }
                        done.leave()
                    }
                }
                done.enter()
                process.terminationHandler = { _ in done.leave() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: WheelError("Could not start \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                collector.process = process
                drain(outPipe.fileHandleForReading, collector.appendStdout)
                drain(errPipe.fileHandleForReading, collector.appendStderr)
                done.notify(queue: .global(qos: .utility)) {
                    collector.finish()
                    if collector.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: ProcessOutput(status: process.terminationStatus, stdout: collector.stdout, stderr: collector.stderrText))
                    }
                }
            }
        } onCancel: {
            collector.cancel()
        }
    }
}

/// Thread-safe line splitter shared by the pipe handlers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stdout = Data()
    private var stderrData = Data()
    private var outLine = Data(), errLine = Data()
    private let onStdoutLine: ((String) -> Void)?
    private let onStderrLine: ((String) -> Void)?
    var process: Process? {
        get { lock.withLock { _process } }
        set { lock.withLock { _process = newValue }; if cancelled { cancel() } }
    }
    private var _process: Process?
    private(set) var cancelled = false

    init(onStdoutLine: ((String) -> Void)?, onStderrLine: ((String) -> Void)?) {
        self.onStdoutLine = onStdoutLine
        self.onStderrLine = onStderrLine
    }

    var stderrText: String { lock.withLock { String(decoding: stderrData, as: UTF8.self) } }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            stdout.append(data)
            return split(&outLine, data)
        }
        lines.forEach { onStdoutLine?($0) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            // Keep the tail only; ffmpeg can print megabytes of progress.
            stderrData.append(data)
            if stderrData.count > 512 * 1024 { stderrData = stderrData.suffix(256 * 1024) }
            return split(&errLine, data)
        }
        lines.forEach { onStderrLine?($0) }
    }

    func finish() {
        let (out, err): (String?, String?) = lock.withLock {
            defer { outLine.removeAll(); errLine.removeAll() }
            return (outLine.isEmpty ? nil : String(decoding: outLine, as: UTF8.self), errLine.isEmpty ? nil : String(decoding: errLine, as: UTF8.self))
        }
        if let out { onStdoutLine?(out) }
        if let err { onStderrLine?(err) }
    }

    func cancel() {
        let running: Process? = lock.withLock { cancelled = true; return _process }
        guard let running, running.isRunning else { return }
        running.terminate()
        // Escalate if the helper ignores SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    /// ffmpeg ends progress lines with \r as well as \n.
    private func split(_ buffer: inout Data, _ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<index]
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}
