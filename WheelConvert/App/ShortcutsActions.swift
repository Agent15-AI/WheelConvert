import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions. They run inside WheelConvert (launching it in the background if needed), show the
// usual progress panel, and return the saved files so a shortcut can keep working with them.

struct ConvertFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert File"
    static let description = IntentDescription("Converts files to another format on this Mac, with the options from WheelConvert Settings → Conversion.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Format")
    var format: ShortcutFormat

    static var parameterSummary: some ParameterSummary { Summary("Convert \(\.$files) to \(\.$format)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await Self.convert(files, to: format))
    }

    static func convert(_ files: [IntentFile], to format: ShortcutFormat) async throws -> [IntentFile] {
        guard let target = FileFormat(rawValue: format.rawValue) else { throw WheelError("This format is not supported.") }
        return try await ShortcutJob.run(files) { urls in JobCenter.shared.convert(urls, to: target, canAsk: false) }
    }
}

struct CompressFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress File"
    static let description = IntentDescription("Makes images, videos, audio and PDFs smaller, by strength or to a target size.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.image", "public.movie", "public.audio", "com.adobe.pdf"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Strength", default: .balanced)
    var strength: ShortcutStrength

    @Parameter(title: "Target Size (MB)", description: "When set, each file is made at most this size and Strength is ignored.")
    var targetMegabytes: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$files)") {
            \.$strength
            \.$targetMegabytes
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await Self.compress(files, strength: strength, targetMegabytes: targetMegabytes))
    }

    static func compress(_ files: [IntentFile], strength: ShortcutStrength, targetMegabytes: Double?) async throws -> [IntentFile] {
        var options = ToolOptions.Compress(strength: CompressionStrength(rawValue: strength.rawValue) ?? .balanced)
        if let targetMegabytes {
            guard targetMegabytes > 0.001 else { throw WheelError("Enter a target size of at least 1 KB.") }
            options.mode = .fileSize
            options.targetBytes = Int64(targetMegabytes * 1_000_000)
        }
        return try await ShortcutJob.run(files) { urls in
            guard ToolKind.available(for: urls.map(FileFormat.detect)).contains(.compress) else {
                throw WheelError("Compress works with images, videos, audio and PDFs of one kind at a time.")
            }
            return ToolRunner.submit(.compress, request: .compress(options), urls: urls, canAsk: false)
        }
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let description = IntentDescription("Runs one of your WheelConvert presets, such as Instagram 1080 px JPG, on files.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset) to \(\.$files)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await Self.apply(preset.id, to: files))
    }

    static func apply(_ id: UUID, to files: [IntentFile]) async throws -> [IntentFile] {
        try await ShortcutJob.run(files) { urls in
            guard let preset = AppSettings.shared.presets.first(where: { $0.id == id }) else { throw WheelError("This preset no longer exists.") }
            guard preset.applies(to: urls) else { throw WheelError("“\(preset.name)” doesn’t apply to these files.") }
            return preset.run(on: urls, canAsk: false)
        }
    }
}

/// Files in, a WheelConvert job, files out.
enum ShortcutJob {
    static func run(_ files: [IntentFile], start: @MainActor ([URL]) throws -> JobState?) async throws -> [IntentFile] {
        guard !files.isEmpty else { throw WheelError("Choose at least one file.") }
        // Files Shortcuts hands over as data (not from disk) are written here first; results saved
        // beside them are returned as data before the folder goes away.
        let scratch = try ScratchDirectory()
        var urls: [URL] = []
        for (index, file) in files.enumerated() {
            if let url = file.fileURL, FileManager.default.isReadableFile(atPath: url.path) {
                urls.append(url)
            } else {
                let folder = scratch.file("\(index)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(OutputNaming.sanitize(file.filename))
                try file.data.write(to: url)
                urls.append(url)
            }
        }
        let inputs = urls
        guard let job = try await MainActor.run(body: { try start(inputs) }) else { throw WheelError("WheelConvert couldn’t start.") }
        await withTaskCancellationHandler {
            await job.task?.value
        } onCancel: {
            Task { @MainActor in job.cancel() }
        }
        let (outputs, failures) = await MainActor.run { (job.outputs, job.failures) }
        try Task.checkCancellation()
        if !failures.isEmpty { throw WheelError(verbatim: failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")) }
        let scratchPath = scratch.url.resolvingSymlinksInPath().path
        return try outputs.flatMap(expand).map { url in
            guard url.resolvingSymlinksInPath().path.hasPrefix(scratchPath) else { return IntentFile(fileURL: url, filename: url.lastPathComponent) }
            return IntentFile(data: try Data(contentsOf: url), filename: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
        }
    }

    /// Multi-file results come back as the files in their folder, in name order.
    static func expand(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [url] }
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Parameters

struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PresetEntity] { await all() }

    private func all() async -> [PresetEntity] {
        await MainActor.run { AppSettings.shared.presets.map { PresetEntity(id: $0.id, name: $0.name) } }
    }
}

enum ShortcutStrength: String, AppEnum {
    case light, balanced, strong

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Strength"
    static let caseDisplayRepresentations: [ShortcutStrength: DisplayRepresentation] = [
        .light: "Light", .balanced: "Balanced", .strong: "Strong",
    ]
}

/// The formats Shortcuts can convert to. Raw values match `FileFormat`.
enum ShortcutFormat: String, AppEnum {
    case jpg, png, webp, heic, tiff, avif, bmp, pdf
    case mp4, mov, mkv, webm, avi, wmv, gif
    case mp3, m4a, wav, flac, ogg, opus, aiff
    case docx, pages, md, txt, epub, kindle, mobi, html
    case pptx, xlsx, ods, csv, tsv
    case srt, vtt
    case zip, tar, gzip, sevenZip = "7z"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [ShortcutFormat: DisplayRepresentation] = [
        .jpg: "JPG", .png: "PNG", .webp: "WebP", .heic: "HEIC", .tiff: "TIFF", .avif: "AVIF", .bmp: "BMP", .pdf: "PDF",
        .mp4: "MP4", .mov: "MOV", .mkv: "MKV", .webm: "WebM", .avi: "AVI", .wmv: "WMV", .gif: "GIF",
        .mp3: "MP3", .m4a: "M4A", .wav: "WAV", .flac: "FLAC", .ogg: "OGG", .opus: "Opus", .aiff: "AIFF",
        .docx: "Word (DOCX)", .pages: "Pages", .md: "Markdown", .txt: "Plain Text", .epub: "EPUB", .kindle: "Kindle (EPUB for Send to Kindle)", .mobi: "MOBI", .html: "HTML",
        .pptx: "PowerPoint (PPTX)", .xlsx: "Excel (XLSX)", .ods: "ODS", .csv: "CSV", .tsv: "TSV",
        .srt: "SRT", .vtt: "VTT",
        .zip: "ZIP", .tar: "TAR", .gzip: "GZIP", .sevenZip: "7-Zip",
    ]
}
