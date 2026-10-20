import Foundation

/// Per-output-format conversion settings. Each format only uses the fields that apply to it
/// (see `ConversionSetting.applicable(to:)`); defaults are tuned per format.
struct ConversionOptions: Codable, Equatable {
    enum Quality: String, Codable, CaseIterable, Identifiable {
        case compact, balanced, high
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum SampleDepth: String, Codable, CaseIterable, Identifiable {
        case matchSource, bit16, bit24, bit32, float32
        var id: String { rawValue }
        var title: String {
            switch self {
            case .matchSource: "Match Source"
            case .bit16: "16-bit"
            case .bit24: "24-bit"
            case .bit32: "32-bit"
            case .float32: "32-bit Float"
            }
        }
    }

    enum ArchiveCompression: String, Codable, CaseIterable, Identifiable {
        case fast, balanced, maximum
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var level: Int { self == .fast ? 1 : self == .balanced ? 6 : 9 }
    }

    enum EPUBLayout: String, Codable, CaseIterable, Identifiable {
        case adjustableText, preservePages
        var id: String { rawValue }
        var title: String { self == .adjustableText ? "Adjustable Text" : "Preserve Pages" }
        var detail: String {
            switch self {
            case .adjustableText: "Reflowable, selectable text with headings and tables. Illustrations and complex equations stay as artwork."
            case .preservePages: "A fixed-layout book of page images. Text can't be resized, selected, or searched."
            }
        }
    }

    enum OfficeLayout: String, Codable, CaseIterable, Identifiable {
        case editable, preservePages
        var id: String { rawValue }
        var title: String { self == .editable ? "Editable Text" : "Preserve Pages" }
        var detail: String {
            switch self {
            case .editable: "Text you can edit: paragraphs, headings and tables in documents; text boxes over the page artwork in PowerPoint. Scanned pages are read with OCR in documents."
            case .preservePages: "Every page kept as a sharp image, including tables, equations, and scans. Text can't be edited."
            }
        }
    }

    var quality: Quality = .balanced
    var preserveMetadata = true
    /// 0 keeps the source height.
    var videoMaxHeight = 0
    /// kbps for lossy audio.
    var audioBitrate = 192
    var audioSampleDepth: SampleDepth = .matchSource
    var gifFrameRate = 15
    /// 0 keeps the source width.
    var gifMaxWidth = 480
    var compression: ArchiveCompression = .balanced
    var epubLayout: EPUBLayout = .adjustableText
    var officeLayout: OfficeLayout = .editable
    /// Pixels per inch for PDF pages saved as JPG or PNG.
    var pdfImageDPI = 150
    /// Images wider than this are scaled down; 0 keeps the source width.
    var imageMaxWidth = 0

    static func defaults(for format: FileFormat) -> ConversionOptions {
        var options = ConversionOptions()
        switch format {
        case .mp3: options.audioBitrate = 192
        case .m4a: options.audioBitrate = 256
        case .ogg: options.audioBitrate = 192
        case .opus: options.audioBitrate = 128
        case .heic, .avif: options.quality = .high
        case .jpg, .webp: options.quality = .high
        default: break
        }
        return options
    }
}

/// The settings a format exposes in Settings → Conversion.
enum ConversionSetting: CaseIterable {
    case quality, preserveMetadata, videoMaxHeight, audioBitrate, audioSampleDepth, gifFrameRate, gifMaxWidth, compression, epubLayout, officeLayout, pdfImageDPI, imageMaxWidth

    static func applicable(to format: FileFormat) -> [ConversionSetting] {
        switch format {
        case .jpg: [.quality, .imageMaxWidth, .preserveMetadata, .pdfImageDPI]
        case .webp, .heic, .avif: [.quality, .imageMaxWidth, .preserveMetadata]
        case .png: [.imageMaxWidth, .preserveMetadata, .pdfImageDPI]
        case .tiff, .bmp: [.imageMaxWidth, .preserveMetadata]
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: [.quality, .videoMaxHeight, .audioBitrate, .preserveMetadata]
        case .gif: [.gifFrameRate, .gifMaxWidth]
        case .mp3, .m4a, .ogg, .opus: [.audioBitrate, .preserveMetadata]
        case .wav, .aiff: [.audioSampleDepth, .preserveMetadata]
        case .flac: [.audioSampleDepth, .compression, .preserveMetadata]
        case .zip, .gzip: [.compression]
        case .epub: [.epubLayout]
        case .docx, .pages, .pptx: [.officeLayout]
        default: []
        }
    }

    static let bitrates = [96, 128, 160, 192, 256, 320]
    static let videoHeights = [0, 2160, 1440, 1080, 720, 480]
    static let gifFrameRates = [10, 12, 15, 20, 24, 30]
    static let gifWidths = [320, 480, 640, 800, 1080, 0]
    static let pdfImageDPIs = [72, 150, 300]
    static let imageWidths = [0, 3840, 2560, 1920, 1600, 1280, 1080, 800, 640]
}
