import Foundation

/// Renders a StructuredDocument as HTML or EPUB XHTML.
struct HTMLWriter {
    enum Images {
        /// Inline data: URLs (single-file HTML and PDF printing).
        case embedded
        /// Calls back for a relative path, used by the EPUB writer.
        case referenced((StructuredDocument.Image) -> String)
    }

    var images: Images = .embedded
    var xhtml = false
    private var notes: [String] = []

    init(images: Images = .embedded, xhtml: Bool = false) {
        self.images = images
        self.xhtml = xhtml
    }

    static let printCSS = """
    html{-webkit-print-color-adjust:exact}
    body{font:11pt/1.45 -apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;color:#111;margin:0;overflow-wrap:break-word}
    h1,h2,h3,h4,h5,h6{line-height:1.2;margin:1.1em 0 .45em;break-after:avoid;page-break-after:avoid}
    h1{font-size:1.9em}h2{font-size:1.5em}h3{font-size:1.25em}h4{font-size:1.1em}h5,h6{font-size:1em}
    p{margin:0 0 .8em;orphans:2;widows:2}
    ul,ol{margin:0 0 .8em;padding-inline-start:1.6em}li{margin:.15em 0}
    blockquote{margin:0 0 .8em;padding-left:1em;border-left:3px solid #ccc;color:#444}
    pre{font:9.5pt/1.4 Menlo,monospace;background:#f5f5f7;padding:.7em .9em;border-radius:4px;white-space:pre-wrap;break-inside:avoid}
    code{font-family:Menlo,monospace;font-size:.92em}
    table{border-collapse:collapse;margin:0 0 1em;max-width:100%}
    td,th{border:.5pt solid #aaa;padding:.3em .5em;vertical-align:top;text-align:start}
    th{background:#eee}tr{break-inside:avoid}
    img{max-width:100%;height:auto}figure{margin:.6em 0 1em;text-align:center;break-inside:avoid}
    hr{border:0;border-top:1px solid #bbb;margin:1.2em 0}
    .pagebreak{break-after:page;page-break-after:always;height:0}
    .footnotes{font-size:.85em;border-top:1px solid #ccc;margin-top:2em;padding-top:.5em}
    """

    static let screenCSS = """
    body{font:16px/1.55 -apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;color:#111;max-width:46em;margin:2em auto;padding:0 1.2em;overflow-wrap:break-word}
    @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}pre{background:#2c2c2e!important}th{background:#333!important}a{color:#7ab7ff}}
    h1,h2,h3{line-height:1.2}pre{font:14px/1.45 Menlo,monospace;background:#f5f5f7;padding:.8em 1em;border-radius:6px;overflow:auto}
    code{font-family:Menlo,monospace;font-size:.92em}blockquote{margin:0 0 1em;padding-left:1em;border-left:3px solid #ccc;color:#555}
    table{border-collapse:collapse;margin:0 0 1em}td,th{border:1px solid #aaa;padding:.35em .6em;vertical-align:top}th{background:#eee}
    img{max-width:100%;height:auto}figure{margin:1em 0;text-align:center}hr{border:0;border-top:1px solid #bbb}
    .footnotes{font-size:.9em;border-top:1px solid #ccc;margin-top:2em}
    """

    /// A complete standalone page.
    mutating func document(_ doc: StructuredDocument, css: String) -> String {
        let lang = doc.language ?? "en"
        let title = escape(doc.inferredTitle ?? "Document")
        let body = blocks(doc.blocks)
        return """
        <!DOCTYPE html>
        <html lang="\(escape(lang))"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>\
        <title>\(title)</title><style>\(css)</style></head><body>
        \(body)\(footnotes())
        </body></html>
        """
    }

    /// Body markup only, plus collected footnotes.
    mutating func fragment(_ blocks: [StructuredDocument.Block]) -> String {
        let body = self.blocks(blocks)
        return body + footnotes()
    }

    private mutating func footnotes() -> String {
        guard !notes.isEmpty else { return "" }
        var html = xhtml ? "<section class=\"footnotes\" epub:type=\"footnotes\"><ol>" : "<section class=\"footnotes\"><ol>"
        for (i, note) in notes.enumerated() {
            html += "<li id=\"fn\(i + 1)\"\(xhtml ? " epub:type=\"footnote\"" : "")><p>\(escape(note)) <a href=\"#fnref\(i + 1)\">↩</a></p></li>"
        }
        notes = []
        return html + "</ol></section>"
    }

    mutating func blocks(_ blocks: [StructuredDocument.Block]) -> String {
        var html = ""
        var index = 0
        while index < blocks.count {
            // Consecutive list paragraphs become one nested list.
            if case .paragraph(let p) = blocks[index], let kind = p.list {
                // A top-level item of another kind starts a separate list.
                var items: [StructuredDocument.Paragraph] = []
                let topLevel = p.listLevel
                while index < blocks.count, case .paragraph(let q) = blocks[index], let qKind = q.list,
                      items.isEmpty || q.listLevel > topLevel || qKind == kind {
                    items.append(q)
                    index += 1
                }
                html += list(items[...])
                continue
            }
            html += block(blocks[index])
            index += 1
        }
        return html
    }

    private mutating func list(_ items: ArraySlice<StructuredDocument.Paragraph>) -> String {
        guard let first = items.first else { return "" }
        let level = first.listLevel
        let tag = first.list == .ordered ? "ol" : "ul"
        let start = first.list == .ordered && (first.listStart ?? 1) != 1 ? " start=\"\(first.listStart!)\"" : ""
        var html = "<\(tag)\(start)>"
        var i = items.startIndex
        while i < items.endIndex {
            let item = items[i]
            if item.listLevel > level {
                // Deeper items without a parent at this level still nest.
                var j = i
                while j < items.endIndex, items[j].listLevel > level { j += 1 }
                html += "<li>" + list(items[i..<j]) + "</li>"
                i = j
                continue
            }
            html += "<li>" + runs(item.runs)
            var j = i + 1
            while j < items.endIndex, items[j].listLevel > level { j += 1 }
            if j > i + 1 { html += list(items[(i + 1)..<j]) }
            html += "</li>"
            i = j
        }
        return html + "</\(tag)>"
    }

    private mutating func block(_ block: StructuredDocument.Block) -> String {
        switch block {
        case .heading(let level, let r):
            let n = min(max(level, 1), 6)
            return "<h\(n)>\(runs(r))</h\(n)>\n"
        case .paragraph(let p):
            var attributes = ""
            switch p.alignment {
            case .center: attributes += " style=\"text-align:center\""
            case .right: attributes += " style=\"text-align:right\""
            case .justified: attributes += " style=\"text-align:justify\""
            case .left: break
            }
            if p.rtl { attributes += " dir=\"rtl\"" }
            let content = runs(p.runs)
            return "<p\(attributes)>\(content.isEmpty ? (xhtml ? "<br/>" : "<br>") : content)</p>\n"
        case .quote(let inner):
            return "<blockquote>\(blocks(inner))</blockquote>\n"
        case .code(let text, let language):
            let cls = language.map { " class=\"language-\(escape($0))\"" } ?? ""
            return "<pre><code\(cls)>\(escape(text))</code></pre>\n"
        case .table(let table):
            var html = "<table>"
            for (r, row) in table.rows.enumerated() {
                html += "<tr>"
                for cell in row {
                    let tag = r < table.headerRows ? "th" : "td"
                    var spans = ""
                    if cell.rowSpan > 1 { spans += " rowspan=\"\(cell.rowSpan)\"" }
                    if cell.columnSpan > 1 { spans += " colspan=\"\(cell.columnSpan)\"" }
                    html += "<\(tag)\(spans)>\(cellContent(cell))</\(tag)>"
                }
                html += "</tr>"
            }
            return html + "</table>\n"
        case .image(let image):
            let src: String
            switch images {
            case .embedded: src = "data:\(image.mime);base64,\(image.data.base64EncodedString())"
            case .referenced(let reference): src = reference(image)
            }
            var size = ""
            if let w = image.width, w > 0 { size += " width=\"\(Int(w.rounded()))\"" }
            let alt = escape(image.alt ?? "")
            return "<figure><img src=\"\(src)\" alt=\"\(alt)\"\(size)\(xhtml ? "/" : "")></figure>\n"
        case .rule:
            return xhtml ? "<hr/>\n" : "<hr>\n"
        case .pageBreak:
            return "<div class=\"pagebreak\"></div>\n"
        }
    }

    private mutating func cellContent(_ cell: StructuredDocument.Cell) -> String {
        // Single-paragraph cells skip the <p> wrapper so tables stay compact.
        if cell.blocks.count == 1, case .paragraph(let p) = cell.blocks[0], p.list == nil { return runs(p.runs) }
        return blocks(cell.blocks)
    }

    mutating func runs(_ runs: [StructuredDocument.Run]) -> String {
        var html = ""
        for run in runs {
            var text = escape(run.text).replacingOccurrences(of: "\n", with: xhtml ? "<br/>" : "<br>")
            if run.code { text = "<code>\(text)</code>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.underline { text = "<u>\(text)</u>" }
            if run.strike { text = "<s>\(text)</s>" }
            if run.superscript { text = "<sup>\(text)</sup>" }
            if run.subscripted { text = "<sub>\(text)</sub>" }
            if let color = run.color, color.count == 6, color.allSatisfy(\.isHexDigit) { text = "<span style=\"color:#\(color)\">\(text)</span>" }
            if let link = run.link, let safe = Self.safeLink(link) { text = "<a href=\"\(escape(safe))\">\(text)</a>" }
            html += text
            if let note = run.note {
                notes.append(note)
                let n = notes.count
                html += "<sup><a id=\"fnref\(n)\" href=\"#fn\(n)\"\(xhtml ? " epub:type=\"noteref\"" : "")>\(n)</a></sup>"
            }
        }
        return html
    }

    /// Only web, mail and in-document links survive; script URLs are dropped.
    static func safeLink(_ link: String) -> String? {
        let lower = link.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("#") { return link }
        return nil
    }

    func escape(_ text: String) -> String { Self.escape(text) }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Control characters other than tab/newline are invalid in XML.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                if scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
