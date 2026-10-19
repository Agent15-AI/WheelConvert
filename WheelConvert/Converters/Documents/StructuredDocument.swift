import Foundation

/// Format-neutral document used between every document reader and writer:
/// DOCX, Pages, Markdown, text, EPUB, RTF and PDF all read into this, and every
/// document output is written from it.
struct StructuredDocument: Codable, Equatable {
    var title: String?
    var author: String?
    var language: String?
    /// Page geometry in points, when the source has one.
    var page: PageSetup?
    var blocks: [Block] = []

    struct PageSetup: Codable, Equatable {
        var width: Double
        var height: Double
        var top: Double = 72
        var right: Double = 72
        var bottom: Double = 72
        var left: Double = 72
    }

    struct Run: Codable, Equatable {
        var text: String
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var code = false
        var superscript = false
        var subscripted = false
        var link: String?
        /// Hex RGB without '#', nil for the default color.
        var color: String?
        /// Footnote text anchored after this run.
        var note: String?

        init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.link = link
        }

        func sameStyle(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && underline == other.underline && strike == other.strike
                && code == other.code && superscript == other.superscript && subscripted == other.subscripted
                && link == other.link && color == other.color && note == nil && other.note == nil
        }
    }

    enum ListKind: String, Codable { case unordered, ordered }

    enum Alignment: Int, Codable { case left = 0, right = 1, center = 2, justified = 3 }

    struct Table: Codable, Equatable {
        var rows: [[Cell]]
        var headerRows = 0
    }

    struct Cell: Codable, Equatable {
        var blocks: [Block]
        var rowSpan = 1
        var columnSpan = 1
        init(_ runs: [Run]) { blocks = [.paragraph(Paragraph(runs: runs))] }
        init(blocks: [Block], rowSpan: Int = 1, columnSpan: Int = 1) {
            self.blocks = blocks
            self.rowSpan = rowSpan
            self.columnSpan = columnSpan
        }
        var plainText: String { blocks.map(\.plainText).joined(separator: "\n") }
    }

    struct Paragraph: Codable, Equatable {
        var runs: [Run]
        var alignment: Alignment = .left
        var list: ListKind?
        var listLevel = 0
        /// Start number for the first item of an ordered list.
        var listStart: Int?
        var rtl = false
        var plainText: String { runs.map(\.text).joined() }
    }

    struct Image: Codable, Equatable {
        var data: Data
        /// Displayed size in points, when known.
        var width: Double?
        var height: Double?
        var alt: String?
        var name: String?
        var mime: String { ImageSniffer.mime(data) }
    }

    indirect enum Block: Codable, Equatable {
        case heading(level: Int, runs: [Run])
        case paragraph(Paragraph)
        case quote([Block])
        case code(String, language: String?)
        case table(Table)
        case image(Image)
        case rule
        case pageBreak

        var plainText: String {
            switch self {
            case .heading(_, let runs): runs.map(\.text).joined()
            case .paragraph(let p): p.plainText
            case .quote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
            case .code(let text, _): text
            case .table(let table): table.rows.map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
            case .image(let image): image.alt ?? ""
            case .rule, .pageBreak: ""
            }
        }
    }

    var isEmpty: Bool { blocks.allSatisfy { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.isImageOrTable } }

    /// Joins adjacent runs with identical styling.
    static func merge(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs where !run.text.isEmpty || run.note != nil {
            if let last = out.last, last.sameStyle(as: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// The first heading (or first line) as a title fallback.
    var inferredTitle: String? {
        if let title, !title.isEmpty { return title }
        for block in blocks {
            if case .heading(_, let runs) = block { return runs.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}

extension StructuredDocument.Block {
    var isImageOrTable: Bool {
        switch self {
        case .image, .table: true
        default: false
        }
    }
}

/// Identifies image bytes by their magic numbers.
enum ImageSniffer {
    static func mime(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if b.starts(with: [0x3C]) || String(decoding: data.prefix(256), as: UTF8.self).contains("<svg") { return "image/svg+xml" }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return "image/heic" }
        if b.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        return "application/octet-stream"
    }

    static func fileExtension(_ data: Data) -> String {
        switch mime(data) {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/svg+xml": "svg"
        case "image/heic": "heic"
        case "image/bmp": "bmp"
        case "image/tiff": "tiff"
        default: "bin"
        }
    }

    /// Converts formats that EPUB/DOCX readers can't display (HEIC, TIFF, BMP, WebP) to PNG.
    static func portable(_ data: Data) -> Data {
        switch mime(data) {
        case "image/png", "image/jpeg", "image/gif": return data
        default:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return data }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return data }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : data
        }
    }

    /// PNG, JPEG or GIF bytes for formats that only accept those (DOCX, Pages); nil when the image
    /// can't be decoded (SVG without a raster version, unknown data).
    static func raster(_ data: Data) -> Data? {
        let converted = portable(data)
        return ["image/png", "image/jpeg", "image/gif"].contains(mime(converted)) ? converted : nil
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }
}

import ImageIO
