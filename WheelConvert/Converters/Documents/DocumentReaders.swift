import AppKit

/// Plain text: blank lines separate paragraphs; line breaks inside a paragraph are kept.
enum PlainTextReader {
    static func read(_ url: URL) throws -> StructuredDocument {
        parse(try TextDecoding.read(url, limit: 32 * 1024 * 1024))
    }

    static func parse(_ text: String) -> StructuredDocument {
        var doc = StructuredDocument()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            doc.blocks.append(.paragraph(.init(runs: [.init(current.joined(separator: "\n"))])))
            current = []
        }
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else if line == "\u{0C}" { flush(); doc.blocks.append(.pageBreak) }
            else { current.append(line) }
        }
        flush()
        return doc
    }
}

/// Converts (X)HTML into blocks. Used for EPUB chapters.
struct HTMLReader {
    /// Returns image bytes for a src attribute (relative to the chapter), or nil.
    var imageLoader: (String) -> Data?

    func parse(_ data: Data) -> [StructuredDocument.Block] {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard head.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return [] }
        let document = (try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]))
            ?? (try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]))
        guard let root = document?.rootElement() else { return [] }
        let body = Self.firstElement(root, named: "body") ?? root
        var collector = Collector(loader: imageLoader)
        collector.walk(children: body)
        collector.flush()
        return collector.blocks
    }

    static func firstElement(_ element: XMLElement, named name: String) -> XMLElement? {
        if element.localName?.lowercased() == name { return element }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, let found = firstElement(child, named: name) { return found }
        }
        return nil
    }

    private struct Collector {
        let loader: (String) -> Data?
        var blocks: [StructuredDocument.Block] = []
        var runs: [StructuredDocument.Run] = []
        var style = StructuredDocument.Run("")
        var listStack: [StructuredDocument.ListKind] = []
        var depth = 0

        init(loader: @escaping (String) -> Data?) { self.loader = loader }

        mutating func flush(alignment: StructuredDocument.Alignment = .left) {
            let merged = StructuredDocument.merge(runs)
            runs = []
            guard !merged.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || merged.contains(where: { $0.note != nil }) else { return }
            var paragraph = StructuredDocument.Paragraph(runs: Self.trimmed(merged), alignment: alignment)
            if let kind = listStack.last {
                paragraph.list = kind
                paragraph.listLevel = listStack.count - 1
            }
            blocks.append(.paragraph(paragraph))
        }

        static func trimmed(_ runs: [StructuredDocument.Run]) -> [StructuredDocument.Run] {
            var copy = runs
            let isBlank = { (c: Character) -> Bool in c == " " || c == "\n" }
            if !copy.isEmpty { copy[0].text = String(copy[0].text.drop(while: isBlank)) }
            if let last = copy.indices.last {
                var text = copy[last].text
                while let ch = text.last, isBlank(ch) { text.removeLast() }
                copy[last].text = text
            }
            return copy.filter { !$0.text.isEmpty || $0.note != nil }
        }

        mutating func walk(children element: XMLElement) {
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { return }
            for node in element.children ?? [] {
                if let child = node as? XMLElement { visit(child) }
                else if node.kind == .text, let text = node.stringValue {
                    let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    if !collapsed.isEmpty { var run = style; run.text = collapsed; runs.append(run) }
                }
            }
        }

        mutating func visit(_ element: XMLElement) {
            let name = element.localName?.lowercased() ?? ""
            let css = element.attribute(forName: "style")?.stringValue?.lowercased() ?? ""
            let alignment: StructuredDocument.Alignment = css.contains("text-align:center") || css.contains("text-align: center") ? .center
                : css.contains("text-align:right") || css.contains("text-align: right") ? .right : .left
            switch name {
            case "script", "style", "head", "title":
                return
            case "nav" where element.attribute(forName: "epub:type")?.stringValue == "toc":
                return
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                walk(children: element)
                let merged = Self.trimmed(StructuredDocument.merge(runs))
                runs = []
                if !merged.isEmpty { blocks.append(.heading(level: Int(String(name.last!)) ?? 1, runs: merged)) }
            case "p", "div", "section", "article", "header", "footer", "aside", "figcaption", "dt", "dd", "caption":
                flush()
                walk(children: element)
                flush(alignment: alignment)
            case "br":
                var run = style; run.text = "\n"; runs.append(run)
            case "hr":
                flush(); blocks.append(.rule)
            case "ul", "ol":
                flush()
                listStack.append(name == "ol" ? .ordered : .unordered)
                walk(children: element)
                flush()
                listStack.removeLast()
            case "li":
                flush()
                walk(children: element)
                flush()
            case "blockquote":
                flush()
                var inner = Collector(loader: loader)
                inner.walk(children: element)
                inner.flush()
                if !inner.blocks.isEmpty { blocks.append(.quote(inner.blocks)) }
            case "pre":
                flush()
                blocks.append(.code(element.stringValue ?? "", language: nil))
            case "table":
                flush()
                if let table = table(element) { blocks.append(.table(table)) }
            case "img", "image":
                let src = element.attribute(forName: "src")?.stringValue ?? element.attribute(forName: "xlink:href")?.stringValue
                    ?? element.attribute(forName: "href")?.stringValue ?? ""
                if let data = loader(src) {
                    flush()
                    let width = element.attribute(forName: "width")?.stringValue.flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }
                    blocks.append(.image(.init(data: data, width: width.map { $0 * 0.75 }, alt: element.attribute(forName: "alt")?.stringValue)))
                }
            case "svg":
                // Inline SVG (often an EPUB cover wrapper) — use the referenced image if there is one.
                walk(children: element)
            default:
                let saved = style
                switch name {
                case "b", "strong": style.bold = true
                case "i", "em", "cite", "var": style.italic = true
                case "u", "ins": style.underline = true
                case "s", "del", "strike": style.strike = true
                case "code", "kbd", "samp", "tt": style.code = true
                case "sup": style.superscript = true
                case "sub": style.subscripted = true
                case "a":
                    if let href = element.attribute(forName: "href")?.stringValue, href.hasPrefix("http") || href.hasPrefix("mailto:") { style.link = href }
                    if element.attribute(forName: "epub:type")?.stringValue == "noteref" { style = saved; return }
                case "span":
                    if css.contains("font-weight:bold") || css.contains("font-weight: bold") || css.contains("font-weight:700") { style.bold = true }
                    if css.contains("font-style:italic") || css.contains("font-style: italic") { style.italic = true }
                default: break
                }
                walk(children: element)
                style = saved
            }
        }

        func table(_ element: XMLElement) -> StructuredDocument.Table? {
            var rows: [[StructuredDocument.Cell]] = []
            var headerRows = 0
            func collect(_ node: XMLElement, inHead: Bool) {
                for child in node.children ?? [] {
                    guard let child = child as? XMLElement else { continue }
                    switch child.localName?.lowercased() {
                    case "thead": collect(child, inHead: true)
                    case "tbody", "tfoot": collect(child, inHead: false)
                    case "tr":
                        var cells: [StructuredDocument.Cell] = []
                        var allHeader = true
                        for cellNode in child.children ?? [] {
                            guard let cellElement = cellNode as? XMLElement, let tag = cellElement.localName?.lowercased(), tag == "td" || tag == "th" else { continue }
                            if tag == "td" { allHeader = false }
                            var inner = Collector(loader: loader)
                            inner.walk(children: cellElement)
                            inner.flush()
                            let rowSpan = Int(cellElement.attribute(forName: "rowspan")?.stringValue ?? "1") ?? 1
                            let colSpan = Int(cellElement.attribute(forName: "colspan")?.stringValue ?? "1") ?? 1
                            cells.append(.init(blocks: inner.blocks.isEmpty ? [.paragraph(.init(runs: []))] : inner.blocks,
                                               rowSpan: min(max(1, rowSpan), 1000), columnSpan: min(max(1, colSpan), 1000)))
                        }
                        if (inHead || (allHeader && rows.count == headerRows)) && !cells.isEmpty { headerRows = rows.count + 1 }
                        if !cells.isEmpty { rows.append(cells) }
                    default: break
                    }
                }
            }
            collect(element, inHead: false)
            return rows.isEmpty ? nil : .init(rows: rows, headerRows: headerRows)
        }
    }
}

/// EPUB reader: follows the package's spine and reads each chapter's XHTML.
enum EPUBReader {
    static func read(_ url: URL) throws -> StructuredDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 256 * 1024 * 1024 else { throw WheelError("The EPUB archive is too large to open safely.") }
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch { throw WheelError("The file is not a valid EPUB container.") }
        if zip.contains("META-INF/encryption.xml") { throw WheelError("Encrypted or font-obfuscated EPUB files are not supported.") }
        let package = try packageDocument(zip)
        var doc = StructuredDocument()
        doc.title = package.title
        doc.author = package.creator
        doc.language = package.language
        for chapter in package.spine {
            guard let data = try? zip.read(chapter) else { continue }
            let folder = (chapter as NSString).deletingLastPathComponent
            let reader = HTMLReader { src in
                guard !src.contains("://"), !src.hasPrefix("data:") else {
                    if src.hasPrefix("data:image/"), let comma = src.firstIndex(of: ",") { return Data(base64Encoded: String(src[src.index(after: comma)...])) }
                    return nil
                }
                let path = DOCXReader.normalize(folder + "/" + (src.removingPercentEncoding ?? src).components(separatedBy: "#")[0])
                return try? zip.read(path)
            }
            var blocks = reader.parse(data)
            if !doc.blocks.isEmpty, !blocks.isEmpty, case .heading = blocks[0] {} else if !doc.blocks.isEmpty && !blocks.isEmpty { blocks.insert(.pageBreak, at: 0) }
            doc.blocks += blocks
        }
        guard !doc.blocks.isEmpty else { throw WheelError("The EPUB has no readable chapters.") }
        return doc
    }

    struct Package {
        var title: String?
        var creator: String?
        var language: String?
        var spine: [String] = []
        var fixedLayout = false
    }

    static func packageDocument(_ zip: ZipArchive) throws -> Package {
        guard let container = try? zip.read("META-INF/container.xml"),
              let containerXML = try? XMLDocument(data: container, options: [.nodeLoadExternalEntitiesNever]),
              let rootfile = try containerXML.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw WheelError("The EPUB does not identify a readable package document.")
        }
        guard let opfData = try? zip.read(rootfile), let opf = try? XMLDocument(data: opfData, options: [.nodeLoadExternalEntitiesNever]) else {
            throw WheelError("The EPUB package document is malformed.")
        }
        let folder = (rootfile as NSString).deletingLastPathComponent
        var package = Package()
        package.title = try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue
        package.creator = try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']").first?.stringValue
        package.language = try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='language']").first?.stringValue
        package.fixedLayout = (try opf.nodes(forXPath: "//*[local-name()='meta' and @property='rendition:layout']").first?.stringValue) == "pre-paginated"
        var manifest: [String: (href: String, type: String)] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let element = item as? XMLElement, let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = (DOCXReader.normalize(folder + "/" + (href.removingPercentEncoding ?? href)), element.attribute(forName: "media-type")?.stringValue ?? "")
        }
        for ref in try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let element = ref as? XMLElement, let id = element.attribute(forName: "idref")?.stringValue, let item = manifest[id] else { continue }
            if element.attribute(forName: "linear")?.stringValue == "no" { continue }
            if item.type.contains("html") || item.href.hasSuffix(".xhtml") || item.href.hasSuffix(".html") { package.spine.append(item.href) }
        }
        guard !package.spine.isEmpty else { throw WheelError("The EPUB has no readable chapters.") }
        return package
    }
}

/// RTF, RTFD and Finder text clippings through AppKit's text system.
enum RichTextReader {
    static func read(_ url: URL, format: FileFormat) throws -> StructuredDocument {
        let attributed: NSAttributedString
        switch format {
        case .textClipping:
            attributed = try clipping(url)
        case .rtfd:
            attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        default:
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 128 * 1024 * 1024 else { throw WheelError("Rich text exceeds the conversion limit.") }
            do {
                attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            } catch {
                throw WheelError("The file is not valid RTF.")
            }
        }
        return document(from: attributed)
    }

    /// Text clippings keep their data as a property list in the data fork (modern) or resource fork (legacy).
    static func clipping(_ url: URL) throws -> NSAttributedString {
        var candidates: [Data] = []
        if let data = try? Data(contentsOf: url), !data.isEmpty { candidates.append(data) }
        let fork = url.appendingPathComponent("..namedfork/rsrc")
        if let data = try? Data(contentsOf: fork), !data.isEmpty { candidates.append(data) }
        for data in candidates {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let types = plist["UTI-Data"] as? [String: Any] else { continue }
            if let rtfd = types["com.apple.flat-rtfd"] as? Data, let text = NSAttributedString(rtfd: rtfd, documentAttributes: nil) { return text }
            if let rtf = types["public.rtf"] as? Data, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) { return text }
            if let utf8 = types["public.utf8-plain-text"] as? String { return NSAttributedString(string: utf8) }
            if let utf8 = types["public.utf8-plain-text"] as? Data { return NSAttributedString(string: String(decoding: utf8, as: UTF8.self)) }
            if let utf16 = types["public.utf16-plain-text"] as? Data, let s = String(data: utf16, encoding: .utf16) { return NSAttributedString(string: s) }
            if let utf16 = types["public.utf16-external-plain-text"] as? Data, let s = String(data: utf16, encoding: .utf16) { return NSAttributedString(string: s) }
        }
        throw WheelError("This text clipping has an unsupported or malformed format.")
    }

    static func document(from attributed: NSAttributedString) -> StructuredDocument {
        var doc = StructuredDocument()
        let string = attributed.string as NSString
        guard string.length > 0 else { return doc }
        // The most common font size is the body size; clearly larger short lines are headings.
        var sizes: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize, default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12

        var tableRows: [[StructuredDocument.Cell]] = []
        var tableObject: NSTextTable?
        var tableRow: [StructuredDocument.Cell] = []
        var tableRowIndex = -1

        func flushTable() {
            if !tableRow.isEmpty { tableRows.append(tableRow); tableRow = [] }
            if !tableRows.isEmpty { doc.blocks.append(.table(.init(rows: tableRows, headerRows: 0))) }
            tableRows = []
            tableObject = nil
            tableRowIndex = -1
        }

        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            var runs: [StructuredDocument.Run] = []
            var images: [StructuredDocument.Block] = []
            var maxSize: CGFloat = 0
            var allBold = true
            attributed.enumerateAttributes(in: range) { attributes, sub, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents, ImageSniffer.mime(data).hasPrefix("image/") {
                        let bounds = attachment.bounds
                        images.append(.image(.init(data: data, width: bounds.width > 0 ? bounds.width : nil, height: bounds.height > 0 ? bounds.height : nil)))
                    }
                    return
                }
                var text = string.substring(with: sub).replacingOccurrences(of: "\u{2028}", with: "\n")
                text = text.replacingOccurrences(of: "\n", with: "", options: .anchored, range: nil)
                if text.hasSuffix("\n") { text.removeLast() }
                if text.hasSuffix("\u{2029}") { text.removeLast() }
                guard !text.isEmpty else { return }
                var run = StructuredDocument.Run(text)
                if let font = attributes[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    run.bold = traits.contains(.boldFontMask)
                    run.italic = traits.contains(.italicFontMask)
                    run.code = font.isFixedPitch || traits.contains(.fixedPitchFontMask)
                    maxSize = max(maxSize, font.pointSize)
                }
                if !run.bold && !text.trimmingCharacters(in: .whitespaces).isEmpty { allBold = false }
                if let underline = attributes[.underlineStyle] as? Int, underline != 0 { run.underline = true }
                if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { run.strike = true }
                if let superscript = attributes[.superscript] as? Int { run.superscript = superscript > 0; run.subscripted = superscript < 0 }
                if let link = attributes[.link] { run.link = (link as? URL)?.absoluteString ?? link as? String }
                if let color = attributes[.foregroundColor] as? NSColor, let rgb = color.usingColorSpace(.sRGB) {
                    // Extended-range colors can fall outside 0…1; clamp so the hex stays six digits.
                    let byte = { (c: CGFloat) in max(0, min(255, Int((c * 255).rounded()))) }
                    let hex = String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
                    if hex != "000000" && hex != "FFFFFF" { run.color = hex }
                }
                runs.append(run)
            }
            let merged = StructuredDocument.merge(runs)
            let text = merged.map(\.text).joined()

            // Tables: each paragraph is a cell, tagged with its table and position.
            if let block = style?.textBlocks.last as? NSTextTableBlock {
                if tableObject !== block.table { flushTable(); tableObject = block.table }
                if block.startingRow != tableRowIndex {
                    if !tableRow.isEmpty { tableRows.append(tableRow) }
                    tableRow = []
                    tableRowIndex = block.startingRow
                }
                tableRow.append(.init(blocks: [.paragraph(.init(runs: merged))] + images, rowSpan: block.rowSpan, columnSpan: block.columnSpan))
                continue
            } else if tableObject != nil {
                flushTable()
            }

            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !images.isEmpty else { continue }
            var alignment: StructuredDocument.Alignment = .left
            switch style?.alignment {
            case .center: alignment = .center
            case .right: alignment = .right
            case .justified: alignment = .justified
            default: break
            }
            if !text.isEmpty {
                let lists = style?.textLists ?? []
                if let list = lists.last {
                    var paragraph = StructuredDocument.Paragraph(runs: stripMarker(merged), alignment: alignment)
                    let format = list.markerFormat.rawValue
                    paragraph.list = format.contains("decimal") || format.contains("alpha") || format.contains("roman") ? .ordered : .unordered
                    paragraph.listLevel = lists.count - 1
                    doc.blocks.append(.paragraph(paragraph))
                } else if text.count < 120 && !text.contains("\n") && (maxSize >= body * 1.35 || (allBold && maxSize >= body * 1.15)) {
                    let level = maxSize >= body * 1.9 ? 1 : maxSize >= body * 1.5 ? 2 : 3
                    doc.blocks.append(.heading(level: level, runs: merged.map { var r = $0; r.bold = false; return r }))
                } else if merged.allSatisfy(\.code) {
                    doc.blocks.append(.code(text, language: nil))
                } else {
                    doc.blocks.append(.paragraph(.init(runs: merged, alignment: alignment)))
                }
            }
            doc.blocks += images
        }
        flushTable()
        return doc
    }

    /// AppKit stores list markers ("\t•\t") in the text itself.
    private static func stripMarker(_ runs: [StructuredDocument.Run]) -> [StructuredDocument.Run] {
        guard var first = runs.first else { return runs }
        if let range = first.text.range(of: #"^\t?[^\t]{1,8}\t"#, options: .regularExpression) {
            first.text.removeSubrange(range)
        }
        return [first] + runs.dropFirst()
    }
}
