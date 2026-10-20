import Foundation

/// A saved recipe: a target format with conversion options, or a tool with its options. Presets show
/// as petals on the Convert wheel and run from watch folders and Shortcuts.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Short text on the wheel petal.
    var label: String
    /// Convert to this format…
    var target: FileFormat?
    /// …or run this tool.
    var tool: ToolKind?
    /// Conversion or tool options as JSON; fields added in later versions take their defaults.
    var options = "{}"
    /// Only offered for files of this kind; nil means every kind the recipe accepts.
    var category: FormatCategory?
    var showOnWheel = true

    /// Tools whose settings don't depend on one particular file, so they can be saved in a preset.
    static let tools: [ToolKind] = [.compress, .removeMetadata, .normalizeAudio]

    var conversionOptions: ConversionOptions {
        get { decoded(ConversionOptions.defaults(for: target ?? .jpg)) }
        set { encode(newValue) }
    }

    func decoded<T: Codable>(_ fallback: T) -> T {
        (try? JSONDecoder().decode(T.self, from: Data(options.utf8), defaults: fallback)) ?? fallback
    }

    mutating func encode<T: Codable>(_ value: T) {
        options = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A preset may "convert" photos and audio to their own format: its options (a smaller size, a
    /// lower bitrate) are the point. Documents and video would only go through a lossy round trip.
    static func reencodes(_ input: FileFormat, to target: FileFormat) -> Bool {
        input == target && [.images, .audio].contains(input.category) && !input.isInputOnly
    }

    /// Whether every file can go through this recipe.
    func applies(to urls: [URL]) -> Bool {
        let formats = urls.map(FileFormat.detect)
        let known = formats.compactMap { $0 }
        guard !urls.isEmpty, known.count == urls.count else { return false }
        if let category, !known.allSatisfy({ $0.category == category }) { return false }
        if let target { return known.allSatisfy { ConversionMatrix.outputs(for: $0).contains(target) || Self.reencodes($0, to: target) } }
        if let tool { return ToolKind.available(for: formats).contains(tool) }
        return false
    }

    /// One line describing the recipe, for Settings.
    var summary: String {
        if let target {
            let options = conversionOptions
            var details: [String] = []
            if options.imageMaxWidth > 0, target.category == .images { details.append(String(localized: "\(options.imageMaxWidth) px wide")) }
            if [.mp3, .m4a, .ogg, .opus].contains(target) { details.append(String(localized: "\(options.audioBitrate) kbps")) }
            if category == .pdf, [.jpg, .png].contains(target) { details.append(String(localized: "\(options.pdfImageDPI) DPI")) }
            return ([String(localized: "Convert to \(target.title)")] + details).joined(separator: " · ")
        }
        guard let tool else { return "" }
        if tool == .compress {
            let options = decoded(ToolOptions.Compress())
            let summary = switch options.mode {
            case .fileSize: String(localized: "Compress to \(ByteCountFormatter.string(fromByteCount: options.targetBytes, countStyle: .file))")
            case .percentage: String(localized: "Compress by \(options.reduction)%")
            case .preset: String(localized: "Compress (\(options.strength.title))")
            }
            return options.videoFormat.map { String(localized: "\(summary) as \($0.title)", comment: "A compression preset's summary, then the video format it saves") } ?? summary
        }
        return tool.title
    }

    // MARK: Defaults

    /// Presets shipped with WheelConvert. Fixed ids let watch folders keep pointing at them after
    /// "Restore Default Presets".
    static let defaults: [Preset] = {
        var instagram = Preset(id: UUID(uuidString: "6C3F1D0E-1A51-4C6B-9C1B-0D2F5B6A0001")!, name: String(localized: "Instagram 1080 px JPG"), label: String(localized: "INSTAGRAM"), target: .jpg, category: .images)
        var photo = ConversionOptions.defaults(for: .jpg)
        photo.imageMaxWidth = 1080
        photo.preserveMetadata = false // no location in shared photos
        instagram.conversionOptions = photo

        var web = Preset(id: UUID(uuidString: "6C3F1D0E-1A51-4C6B-9C1B-0D2F5B6A0002")!, name: String(localized: "Web-ready WebP (1600 px)"), label: String(localized: "WEB"), target: .webp, category: .images)
        var webOptions = ConversionOptions.defaults(for: .webp)
        webOptions.quality = .balanced
        webOptions.imageMaxWidth = 1600
        webOptions.preserveMetadata = false
        web.conversionOptions = webOptions

        // 24 MB keeps the file under the 25 MB attachment limit of most mail services.
        var email = Preset(id: UUID(uuidString: "6C3F1D0E-1A51-4C6B-9C1B-0D2F5B6A0003")!, name: String(localized: "Email-size MP4 (under 25 MB)"), label: String(localized: "EMAIL"), tool: .compress, category: .video)
        email.encode(ToolOptions.Compress(mode: .fileSize, targetBytes: 24_000_000, videoFormat: .mp4))

        var podcast = Preset(id: UUID(uuidString: "6C3F1D0E-1A51-4C6B-9C1B-0D2F5B6A0004")!, name: String(localized: "Podcast MP3 (128 kbps)"), label: String(localized: "PODCAST"), target: .mp3)
        var audio = ConversionOptions.defaults(for: .mp3)
        audio.audioBitrate = 128
        podcast.conversionOptions = audio

        var printing = Preset(id: UUID(uuidString: "6C3F1D0E-1A51-4C6B-9C1B-0D2F5B6A0005")!, name: String(localized: "PDF pages for print (300 DPI PNG)"), label: String(localized: "PRINT"), target: .png, category: .pdf)
        var pages = ConversionOptions.defaults(for: .png)
        pages.pdfImageDPI = 300
        printing.conversionOptions = pages

        return [instagram, web, email, podcast, printing]
    }()

    /// A user preset with this name (ignoring case), else a default one.
    static func named(_ name: String, in presets: [Preset]) -> Preset? {
        (presets + defaults).first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }
}

extension Preset {
    /// Runs the recipe as a job. nil when choosing where to save was cancelled.
    @MainActor @discardableResult
    func run(on urls: [URL], canAsk: Bool = true) -> JobState? {
        if let target {
            return JobCenter.shared.convert(urls, to: target, options: conversionOptions, title: name, canAsk: canAsk)
        }
        guard let tool, let request = try? ToolRequest.decode(tool, json: Data(options.utf8)) else { return nil }
        return ToolRunner.submit(tool, request: request, urls: urls, title: name, canAsk: canAsk)
    }
}
