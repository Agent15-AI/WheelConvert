import Foundation

/// Results are saved beside their originals (or in Downloads when that folder is read-only) and
/// never overwrite anything: a taken name gets a Finder-style number ("photo 2.png").
enum OutputNaming {
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for compound in [".tar.gz", ".tgz"] where name.lowercased().hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `directory/base.ext`, or the first free `base N.ext`.
    static func unique(in directory: URL, base: String, extension ext: String?, reserved: Set<String> = []) -> URL {
        let suffix = ext.map { $0.isEmpty ? "" : "." + $0 } ?? ""
        let clean = sanitize(base)
        var candidate = directory.appendingPathComponent(clean + suffix)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            candidate = directory.appendingPathComponent("\(clean) \(counter)\(suffix)")
            counter += 1
        }
        return candidate
    }

    /// Converted copy: same name, new extension.
    static func converted(_ source: URL, to format: FileFormat) -> URL {
        unique(in: Publisher.destinationDirectory(for: source), base: baseName(of: source), extension: format.fileExtension)
    }

    /// Tool result: "name Suffix.ext" (suffix like "Compressed"), keeping the source extension unless told otherwise.
    static func tool(_ source: URL, suffix: String, extension ext: String? = nil) -> URL {
        let keep = source.lastPathComponent.lowercased().hasSuffix(".tar.gz") ? "tar.gz" : source.pathExtension
        return unique(in: Publisher.destinationDirectory(for: source), base: "\(baseName(of: source)) \(suffix)", extension: ext ?? keep)
    }

    /// A new folder beside the source for multi-file results.
    static func folder(for source: URL, suffix: String? = nil) throws -> URL {
        let base = suffix.map { "\(baseName(of: source)) \($0)" } ?? baseName(of: source)
        let url = unique(in: Publisher.destinationDirectory(for: source), base: base, extension: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Path separators and NULs can't appear in a file name.
    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(200))
    }
}

/// Writes into a hidden temporary file beside the destination and moves it into place only when
/// the producer succeeds, so a failed or cancelled job never leaves a half-written file.
enum AtomicOutput {
    /// Returns where the file ended up: `destination`, or a freshly numbered name if something
    /// claimed `destination` while the producer ran. Existing files are never replaced.
    @discardableResult
    static func write(to destination: URL, _ produce: (URL) async throws -> Void) async throws -> URL {
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".wheelconvert-\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try await produce(temp)
            guard FileManager.default.fileExists(atPath: temp.path) else {
                throw WheelError("The converter finished without creating an output file.")
            }
            var final = destination
            while true {
                do {
                    try FileManager.default.moveItem(at: temp, to: final)
                    return final
                } catch CocoaError.fileWriteFileExists {
                    let ext = final.lastPathComponent.lowercased().hasSuffix(".tar.gz") ? "tar.gz" : final.pathExtension
                    final = OutputNaming.unique(in: directory, base: OutputNaming.baseName(of: destination), extension: ext.isEmpty ? nil : ext)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

/// Scratch space for intermediate files, removed when the job ends.
final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("WheelConvert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}
