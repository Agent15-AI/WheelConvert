import Foundation

/// Runs the bundled ffmpeg with machine-readable progress.
enum FFmpeg {
    /// - Parameters:
    ///   - duration: Expected output duration in seconds, used to turn timestamps into a fraction.
    static func run(_ arguments: [String], duration: Double, progress: @escaping (Double) -> Void) async throws {
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        let output = try await ProcessRunner.run(Bundled.ffmpeg, full, onStdoutLine: { line in
            guard duration > 0 else { return }
            if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)), micros >= 0 {
                progress(min(1, micros / 1_000_000 / duration))
            } else if line == "progress=end" {
                progress(1)
            }
        })
        guard output.status == 0 else { throw failure(output.stderr) }
    }

    /// Runs ffmpeg for analysis output (silencedetect, loudnorm, volumedetect) and returns stderr.
    static func analyze(_ arguments: [String]) async throws -> String {
        let output = try await ProcessRunner.run(Bundled.ffmpeg, ["-hide_banner", "-nostdin", "-nostats"] + arguments)
        guard output.status == 0 else { throw failure(output.stderr) }
        return output.stderr
    }

    static func failure(_ stderr: String) -> WheelError {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        let detail = lines.suffix(2).joined(separator: " ")
        if detail.localizedCaseInsensitiveContains("Invalid data found") || detail.localizedCaseInsensitiveContains("could not find codec") {
            return WheelError("The source file could not be read.")
        }
        if detail.localizedCaseInsensitiveContains("No space left") {
            return WheelError("There isn't enough disk space to save the result.")
        }
        return WheelError(detail.isEmpty ? "The conversion process failed." : "The conversion process failed: \(detail)")
    }

    /// Escapes a path or text for use inside an ffmpeg filter argument.
    static func filterEscape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\':[],;=".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
