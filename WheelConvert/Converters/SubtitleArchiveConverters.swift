import Foundation

/// SRT ⇄ WebVTT, and either to plain text.
enum SubtitleConverter {
    struct Cue: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    static func convert(_ source: URL, from input: FileFormat, to target: FileFormat, destination: URL) throws {
        let text = try TextDecoding.read(source, limit: 32 * 1024 * 1024)
        let cues = input == .vtt ? parseVTT(text) : parseSRT(text)
        guard !cues.isEmpty else { throw WheelError("No valid subtitle cues were found.") }
        let output: String
        switch target {
        case .srt: output = srt(cues)
        case .vtt: output = vtt(cues)
        case .txt: output = plainText(cues)
        default: throw WheelError("Conversion to \(target.title) is unavailable.")
        }
        try output.write(to: destination, atomically: false, encoding: .utf8)
    }

    static func parseSRT(_ text: String) -> [Cue] {
        let blocks = normalize(text).components(separatedBy: "\n\n")
        return blocks.compactMap { block -> Cue? in
            var lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            guard let (start, end) = timing(lines[timingIndex]) else { return nil }
            lines.removeFirst(timingIndex + 1)
            let body = lines.joined(separator: "\n")
            return body.isEmpty ? nil : Cue(start: start, end: end, text: body)
        }
    }

    static func parseVTT(_ text: String) -> [Cue] {
        var blocks = normalize(text).components(separatedBy: "\n\n")
        if let first = blocks.first, first.hasPrefix("WEBVTT") { blocks.removeFirst() }
        return blocks.compactMap { block -> Cue? in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE") || trimmed.hasPrefix("REGION") { return nil }
            var lines = trimmed.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }), let (start, end) = timing(lines[timingIndex]) else { return nil }
            lines.removeFirst(timingIndex + 1)
            let body = lines.joined(separator: "\n")
            return body.isEmpty ? nil : Cue(start: start, end: end, text: body)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n[ \t]+\n"#, with: "\n\n", options: .regularExpression)
    }

    /// "00:01:02,500 --> 00:01:04.000 align:start" → seconds.
    static func timing(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let endField = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)), let end = seconds(endField), end >= start else { return nil }
        return (start, end)
    }

    static func seconds(_ stamp: String) -> Double? {
        let fields = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func stamp(_ seconds: Double, separator: String) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, separator, millis % 1000)
    }

    /// WebVTT-only markup (voices, classes, inline timestamps) becomes plain SRT text; b/i/u survive.
    static func srtText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"<v(?:\.[^ >]+)?\s+([^>]+)>"#, with: "$1: ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"</?(?:c|v|lang|ruby|rt)(?:[. ][^>]*)?>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<\d{2}:[\d:.]+>"#, with: "", options: .regularExpression)
        return result
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(srtText(cue.text))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            // SRT's {\an8} style overrides have no VTT meaning; "-->" may not appear in cue text.
            let text = cue.text.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "-->", with: "→")
            return "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(text)\n"
        }.joined(separator: "\n")
    }

    static func plainText(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let clean = srtText(cue.text).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            for line in clean.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if lines.last != line { lines.append(line) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// ZIP, TAR and GZIP (tar.gz) conversions with the system's bsdtar (libarchive), which also reads RAR.
enum ArchiveConverter {
    static func formatArguments(_ target: FileFormat, options: ConversionOptions) -> [String] {
        switch target {
        case .zip: ["--format", "zip", "--options", "zip:compression-level=\(options.compression.level)"]
        case .gzip: ["-z", "--options", "gzip:compression-level=\(options.compression.level)"]
        default: ["--format", "pax"]
        }
    }

    static func convert(_ source: URL, from input: FileFormat, to target: FileFormat, options: ConversionOptions, destination: URL) async throws {
        let args = ["-c", "-f", destination.path] + formatArguments(target, options: options)
        if isPlainGzip(source) {
            // A .gz of a single file: decompress it, then archive that file (or its contents, if it was a tarball).
            let scratch = try ScratchDirectory()
            let file = try await gunzip(source, into: scratch.url)
            let result = try await ProcessRunner.run(Bundled.bsdtar, args + (isTar(file) ? ["@" + file.path] : ["-C", scratch.url.path, file.lastPathComponent]))
            guard result.status == 0 else { try? FileManager.default.removeItem(at: destination); throw failure(result.stderr) }
            return
        }
        // Re-pack straight from the source archive without extracting to disk.
        let result = try await ProcessRunner.run(Bundled.bsdtar, args + ["@" + source.path])
        guard result.status == 0 else { try? FileManager.default.removeItem(at: destination); throw failure(result.stderr) }
    }

    /// "name.gz" that isn't a ".tar.gz"/".tgz". bsdtar would misread its raw contents as a tar header.
    static func isPlainGzip(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".gz") && !name.hasSuffix(".tar.gz")
    }

    /// Decompresses a copy of `source` inside `folder`; gzip names the result without ".gz".
    static func gunzip(_ source: URL, into folder: URL) async throws -> URL {
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-d", "-f", copy.path])
        let file = copy.deletingPathExtension()
        guard result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            try? FileManager.default.removeItem(at: copy)
            throw failure(result.stderr.isEmpty ? "The archive is damaged." : result.stderr)
        }
        return file
    }

    /// POSIX/GNU tar files carry "ustar" at byte 257.
    static func isTar(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 262)) ?? Data()
        return header.count == 262 && header.suffix(5) == Data("ustar".utf8)
    }

    static func archiveFolder(_ folder: URL, to target: FileFormat, options: ConversionOptions, destination: URL) async throws {
        let args = ["-c", "-f", destination.path] + formatArguments(target, options: options)
            + ["--no-mac-metadata", "--exclude", ".DS_Store", "--exclude", ".wheelconvert-*", "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
        let result = try await ProcessRunner.run(Bundled.bsdtar, args)
        guard result.status == 0 else { throw failure(result.stderr) }
    }

    /// Extracts into a new folder named after the archive. bsdtar refuses absolute and parent paths.
    static func extract(_ archive: URL) async throws -> URL {
        let staging = try Publisher.staging(for: archive)
        let folder = staging.url.appendingPathComponent("__results", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tarball = archive
        if isPlainGzip(archive) {
            do { tarball = try await gunzip(archive, into: folder) } catch {
                try? FileManager.default.removeItem(at: staging.url)
                throw error
            }
        }
        if tarball == archive || isTar(tarball) {
            let result = try await ProcessRunner.run(Bundled.bsdtar, ["-x", "-f", tarball.path, "-C", folder.path, "--no-same-owner"])
            if tarball != archive { try? FileManager.default.removeItem(at: tarball) }
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: staging.url)
                throw failure(result.stderr)
            }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard !contents.isEmpty else {
            try? FileManager.default.removeItem(at: staging.url)
            throw WheelError("The source archive is empty.")
        }
        defer { try? FileManager.default.removeItem(at: staging.url) }
        // Like Archive Utility: a single top-level item is placed directly; several get a folder.
        if contents.count == 1, let only = contents.first {
            let ext = only.pathExtension
            let base = ext.isEmpty ? only.lastPathComponent : String(only.lastPathComponent.dropLast(ext.count + 1))
            return try OutputNaming.place(only, in: staging.directory, base: base, extension: ext.isEmpty ? nil : ext)
        }
        return try OutputNaming.place(folder, in: staging.directory, base: OutputNaming.baseName(of: archive), extension: nil)
    }

    static func failure(_ stderr: String) -> WheelError {
        let lower = stderr.lowercased()
        if lower.contains("passphrase") || lower.contains("encrypt") { return WheelError("Encrypted or password-protected archives are not supported.") }
        if lower.contains("unrecognized archive format") || lower.contains("error exit delayed") || lower.contains("truncated") || lower.contains("damaged") {
            return WheelError("The archive is damaged or uses an unsupported format.")
        }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return WheelError(line.isEmpty ? "The archive could not be converted." : "The archive could not be converted: \(line.replacingOccurrences(of: "tar: ", with: ""))")
    }
}
