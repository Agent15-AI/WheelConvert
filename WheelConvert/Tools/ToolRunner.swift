import Foundation

/// A fully configured tool run.
enum ToolRequest {
    case compress(ToolOptions.Compress)
    case metadata(ToolOptions.Metadata)
    case editImage(ToolOptions.Adjustments)
    case annotate(ToolOptions.Annotate)
    case frame(ToolOptions.Background)
    case crop(ToolOptions.Crop)
    case redactImage(ToolOptions.Redact)
    case createPDF(ToolOptions.Order)
    case collage(ToolOptions.Collage)
    case trim(ToolOptions.Trim)
    case cropVideo(ToolOptions.VideoCrop)
    case speed(ToolOptions.Speed)
    case mute
    case extractAudio
    case join(ToolOptions.Order)
    case snapshots(ToolOptions.Snapshots)
    case split(ToolOptions.Split)
    case redactVideo(ToolOptions.Redact)
    case normalize(ToolOptions.Normalize)
    case visualize(ToolOptions.Visualizer)
    case channels(ToolOptions.Channels)
    case bleep(ToolOptions.Bleep)
    case mergePDF(ToolOptions.Order)
    case organizePDF(ToolOptions.OrganizePDF)
    case splitPDF(ToolOptions.SplitPDF)
    case extract
    case extractText

    /// Tools that turn the whole selection into one result.
    var isBatch: Bool {
        switch self {
        case .createPDF, .collage, .join, .mergePDF: true
        default: false
        }
    }

    /// Decodes options JSON for a tool (CLI and tests).
    static func decode(_ tool: ToolKind, json: Data?) throws -> ToolRequest {
        let data = json ?? Data("{}".utf8)
        let d = JSONDecoder()
        switch tool {
        case .compress: return .compress(try d.decode(ToolOptions.Compress.self, from: data, defaults: ToolOptions.Compress()))
        case .removeMetadata: return .metadata(try d.decode(ToolOptions.Metadata.self, from: data, defaults: ToolOptions.Metadata()))
        case .editImage: return .editImage(try d.decode(ToolOptions.Adjustments.self, from: data, defaults: ToolOptions.Adjustments()))
        case .annotateImage: return .annotate(try d.decode(ToolOptions.Annotate.self, from: data, defaults: ToolOptions.Annotate()))
        case .frameImage: return .frame(try d.decode(ToolOptions.Background.self, from: data, defaults: ToolOptions.Background()))
        case .cropImage: return .crop(try d.decode(ToolOptions.Crop.self, from: data, defaults: ToolOptions.Crop()))
        case .redactImage: return .redactImage(try d.decode(ToolOptions.Redact.self, from: data, defaults: ToolOptions.Redact()))
        case .createPDF: return .createPDF(try d.decode(ToolOptions.Order.self, from: data, defaults: ToolOptions.Order()))
        case .createCollage: return .collage(try d.decode(ToolOptions.Collage.self, from: data, defaults: ToolOptions.Collage()))
        case .trimVideo, .trimAudio: return .trim(try d.decode(ToolOptions.Trim.self, from: data, defaults: ToolOptions.Trim()))
        case .cropVideo: return .cropVideo(try d.decode(ToolOptions.VideoCrop.self, from: data, defaults: ToolOptions.VideoCrop()))
        case .changeVideoSpeed: return .speed(try d.decode(ToolOptions.Speed.self, from: data, defaults: ToolOptions.Speed()))
        case .muteVideo: return .mute
        case .extractAudio: return .extractAudio
        case .joinVideos: return .join(try d.decode(ToolOptions.Order.self, from: data, defaults: ToolOptions.Order()))
        case .videoSnapshots: return .snapshots(try d.decode(ToolOptions.Snapshots.self, from: data, defaults: ToolOptions.Snapshots()))
        case .splitVideo: return .split(try d.decode(ToolOptions.Split.self, from: data, defaults: ToolOptions.Split()))
        case .redactVideo: return .redactVideo(try d.decode(ToolOptions.Redact.self, from: data, defaults: ToolOptions.Redact()))
        case .normalizeAudio: return .normalize(try d.decode(ToolOptions.Normalize.self, from: data, defaults: ToolOptions.Normalize()))
        case .audioToVideo: return .visualize(try d.decode(ToolOptions.Visualizer.self, from: data, defaults: ToolOptions.Visualizer()))
        case .audioChannels: return .channels(try d.decode(ToolOptions.Channels.self, from: data, defaults: ToolOptions.Channels()))
        case .redactAudio: return .bleep(try d.decode(ToolOptions.Bleep.self, from: data, defaults: ToolOptions.Bleep()))
        case .mergePDF: return .mergePDF(try d.decode(ToolOptions.Order.self, from: data, defaults: ToolOptions.Order()))
        case .organizePDF: return .organizePDF(try d.decode(ToolOptions.OrganizePDF.self, from: data, defaults: ToolOptions.OrganizePDF()))
        case .splitPDF: return .splitPDF(try d.decode(ToolOptions.SplitPDF.self, from: data, defaults: ToolOptions.SplitPDF()))
        case .extractArchive: return .extract
        case .extractText: return .extractText
        case .readQRCode: throw WheelError("QR reading has no options.")
        }
    }
}

enum ToolRunner {
    /// Runs one file through a per-file tool.
    static func run(_ request: ToolRequest, on url: URL, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let format = FileFormat.detect(url)
        switch request {
        case .compress(let options):
            switch format?.category {
            case .images: return [try await ImageTools.compress(url, options: options)]
            case .video: return [try await MediaTools.compressVideo(url, options: options, progress: progress)]
            case .audio: return [try await MediaTools.compressAudio(url, options: options, progress: progress)]
            case .pdf: return [try await PDFTools.compress(url, options: options, progress: progress)]
            default: throw WheelError("Compress is unavailable for this file type.")
            }
        case .metadata(let options): return [try await MetadataTools.apply(url, options: options, progress: progress)]
        case .editImage(let options): return [try await ImageTools.edit(url, adjustments: options)]
        case .annotate(let options): return [try await ImageTools.annotate(url, options: options)]
        case .frame(let options): return [try await ImageTools.frame(url, options: options)]
        case .crop(let options): return [try await ImageTools.crop(url, options: options)]
        case .redactImage(let options): return [try await ImageTools.redact(url, options: options)]
        case .trim(let options): return [try await MediaTools.trim(url, options: options, progress: progress)]
        case .cropVideo(let options): return [try await MediaTools.crop(url, options: options, progress: progress)]
        case .speed(let options): return [try await MediaTools.speed(url, options: options, progress: progress)]
        case .mute: return [try await MediaTools.mute(url, progress: progress)]
        case .extractAudio: return [try await MediaTools.extractAudio(url, progress: progress)]
        case .snapshots(let options): return [try await MediaTools.snapshots(url, options: options, progress: progress)]
        case .split(let options): return [try await MediaTools.split(url, options: options, progress: progress)]
        case .redactVideo(let options): return [try await MediaTools.redact(url, options: options, progress: progress)]
        case .normalize(let options): return [try await MediaTools.normalize(url, options: options, progress: progress)]
        case .visualize(let options): return [try await MediaTools.visualize(url, options: options, progress: progress)]
        case .channels(let options): return [try await MediaTools.channels(url, options: options, progress: progress)]
        case .bleep(let options): return [try await MediaTools.bleep(url, options: options, progress: progress)]
        case .organizePDF(let options): return [try await PDFTools.organize(url, options: options)]
        case .splitPDF(let options): return [try await PDFTools.split(url, options: options)]
        case .extract: return [try await ArchiveConverter.extract(url)]
        case .extractText: return [try await ImageTools.extractText(url, progress: progress)]
        case .createPDF, .collage, .join, .mergePDF: return try await runBatch(request, on: [url], progress: progress)
        }
    }

    /// Runs a whole-selection tool.
    static func runBatch(_ request: ToolRequest, on urls: [URL], progress: @escaping (Double) -> Void) async throws -> [URL] {
        switch request {
        case .createPDF(let order): return [try await ImageTools.createPDF(urls, order: order.paths)]
        case .collage(let options): return [try await ImageTools.collage(urls, options: options)]
        case .join(let order):
            let ordered = order.paths.isEmpty ? urls : order.paths.map { URL(fileURLWithPath: $0) }
            return [try await MediaTools.join(ordered, progress: progress)]
        case .mergePDF(let order): return [try await PDFTools.merge(urls, order: order.paths)]
        default:
            var outputs: [URL] = []
            for url in urls { outputs += try await run(request, on: url, progress: progress) }
            return outputs
        }
    }

    /// Queues a configured tool as a job with a progress panel.
    /// - Returns: The job, or nil when the person cancelled choosing where to save.
    @MainActor @discardableResult
    static func submit(_ tool: ToolKind, request: ToolRequest, urls: [URL], title: String? = nil, canAsk: Bool = true) -> JobState? {
        let title = title ?? tool.progressTitle
        if request.isBatch {
            return JobCenter.shared.runBatch(title: title, items: urls, canAsk: canAsk) { progress in
                try await runBatch(request, on: urls, progress: progress)
            }
        }
        // Muting and metadata edits copy the streams; WebM and GIF are encoded in software.
        let hardwareVideo = ![.muteVideo, .extractAudio, .removeMetadata].contains(tool)
            && urls.contains { FileFormat.detect($0).map { $0.category == .video && $0 != .webm && $0 != .gif } ?? false }
        return JobCenter.shared.run(title: title, items: urls, parallel: JobCenter.parallelLimit(hardwareVideo: hardwareVideo), canAsk: canAsk) { url, progress in
            try await run(request, on: url, progress: progress)
        }
    }
}
