import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String, CaseIterable, Codable, Identifiable {
    case images, video, audio, pdf, documents, slides, spreadsheets, subtitles, archives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .documents: "Documents"
        case .slides: "Slides"
        case .spreadsheets: "Spreadsheets"
        case .subtitles: "Subtitles"
        case .archives: "Archives"
        }
    }

    var symbol: String {
        switch self {
        case .images: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .documents: "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .spreadsheets: "tablecells"
        case .subtitles: "captions.bubble"
        case .archives: "archivebox"
        }
    }
}

/// Every file format WheelConvert reads or writes.
enum FileFormat: String, CaseIterable, Codable, Identifiable {
    case jpg, png, webp, heic, tiff, avif, bmp, svg
    case mp4, mov, mkv, webm, avi, wmv, gif
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case pdf
    case docx, pages, md, txt, epub, rtf, rtfd, textClipping, html
    case ppt, pptx
    case xlsx, xls, ods, csv, tsv
    case srt, vtt
    case zip, tar, gzip, rar

    var id: String { rawValue }

    /// Short label used on the wheel and in settings.
    var title: String {
        switch self {
        case .webp: "WebP"
        case .md: "Markdown"
        case .opus: "Opus"
        case .webm: "WebM"
        case .textClipping: "Text Clipping"
        case .gzip: "GZIP"
        case .pages: "Pages"
        default: rawValue.uppercased()
        }
    }

    /// Wheel petal label: compact and uppercase like a key cap.
    var wheelLabel: String {
        switch self {
        case .md: "MD"
        case .textClipping: "CLIPPING"
        default: rawValue.uppercased()
        }
    }

    var category: FormatCategory {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .svg: .images
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: .audio
        case .pdf: .pdf
        case .docx, .pages, .md, .txt, .epub, .rtf, .rtfd, .textClipping, .html: .documents
        case .ppt, .pptx: .slides
        case .xlsx, .xls, .ods, .csv, .tsv: .spreadsheets
        case .srt, .vtt: .subtitles
        case .zip, .tar, .gzip, .rar: .archives
        }
    }

    /// Extension written for outputs.
    var fileExtension: String {
        switch self {
        case .gzip: "tar.gz"
        default: extensions[0]
        }
    }

    /// Recognized input extensions (lowercased), preferred first.
    var extensions: [String] {
        switch self {
        case .jpg: ["jpg", "jpeg", "jpe", "jfif"]
        case .png: ["png"]
        case .webp: ["webp"]
        case .heic: ["heic", "heif", "hif"]
        case .tiff: ["tiff", "tif"]
        case .avif: ["avif"]
        case .bmp: ["bmp", "dib"]
        case .svg: ["svg"]
        case .mp4: ["mp4", "m4v"]
        case .mov: ["mov", "qt"]
        case .mkv: ["mkv"]
        case .webm: ["webm"]
        case .avi: ["avi"]
        case .wmv: ["wmv", "asf"]
        case .gif: ["gif"]
        case .mp3: ["mp3"]
        case .m4a: ["m4a"]
        case .wav: ["wav", "wave"]
        case .flac: ["flac"]
        case .ogg: ["ogg", "oga"]
        case .opus: ["opus"]
        case .aiff: ["aiff", "aif", "aifc"]
        case .wma: ["wma"]
        case .pdf: ["pdf"]
        case .docx: ["docx"]
        case .pages: ["pages"]
        case .md: ["md", "markdown", "mdown", "mkd"]
        case .txt: ["txt", "text"]
        case .epub: ["epub"]
        case .rtf: ["rtf"]
        case .rtfd: ["rtfd"]
        case .textClipping: ["textclipping"]
        case .html: ["html", "htm"]
        case .ppt: ["ppt"]
        case .pptx: ["pptx"]
        case .xlsx: ["xlsx"]
        case .xls: ["xls"]
        case .ods: ["ods"]
        case .csv: ["csv"]
        case .tsv: ["tsv", "tab"]
        case .srt: ["srt"]
        case .vtt: ["vtt"]
        case .zip: ["zip"]
        case .tar: ["tar"]
        case .gzip: ["tgz", "gz"]
        case .rar: ["rar"]
        }
    }

    var isLossyImage: Bool { [.jpg, .webp, .heic, .avif].contains(self) }
    var isLosslessAudio: Bool { [.wav, .flac, .aiff].contains(self) }

    /// Formats that only appear as conversion sources.
    var isInputOnly: Bool { [.svg, .wma, .rtf, .rtfd, .textClipping, .ppt, .xls, .rar].contains(self) }

    /// Formats that only appear as conversion targets.
    var isOutputOnly: Bool { self == .html }

    /// Detects the format of a local file or package from its name, falling back to its type identifier.
    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .gzip }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let match = byExtension[ext], match != .html { return match }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return nil }
        for (identifier, format) in typeFallbacks where type.conforms(to: UTType(identifier) ?? .data) && type != .data {
            return format
        }
        return nil
    }

    private static let byExtension: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for format in FileFormat.allCases { for ext in format.extensions where map[ext] == nil { map[ext] = format } }
        return map
    }()

    private static let typeFallbacks: [(String, FileFormat)] = [
        ("public.jpeg", .jpg), ("public.png", .png), ("org.webmproject.webp", .webp), ("public.heic", .heic),
        ("public.heif", .heic), ("public.tiff", .tiff), ("public.avif", .avif), ("com.microsoft.bmp", .bmp),
        ("public.svg-image", .svg), ("com.compuserve.gif", .gif), ("public.mpeg-4", .mp4),
        ("com.apple.quicktime-movie", .mov), ("public.mp3", .mp3), ("com.apple.m4a-audio", .m4a),
        ("com.microsoft.waveform-audio", .wav), ("public.aiff-audio", .aiff), ("com.adobe.pdf", .pdf),
        ("org.openxmlformats.wordprocessingml.document", .docx), ("com.apple.iwork.pages.sffpages", .pages),
        ("com.apple.iwork.pages.pages", .pages), ("net.daringfireball.markdown", .md), ("public.rtf", .rtf),
        ("com.apple.rtfd", .rtfd), ("com.apple.flat-rtfd", .rtfd), ("com.apple.finder.textclipping", .textClipping),
        ("org.idpf.epub-container", .epub), ("com.microsoft.powerpoint.ppt", .ppt),
        ("org.openxmlformats.presentationml.presentation", .pptx), ("org.openxmlformats.spreadsheetml.sheet", .xlsx),
        ("com.microsoft.excel.xls", .xls), ("org.oasis-open.opendocument.spreadsheet", .ods),
        ("public.comma-separated-values-text", .csv), ("public.tab-separated-values-text", .tsv),
        ("public.zip-archive", .zip), ("public.tar-archive", .tar), ("org.gnu.gnu-zip-archive", .gzip),
        ("com.rarlab.rar-archive", .rar), ("public.plain-text", .txt),
    ]
}
