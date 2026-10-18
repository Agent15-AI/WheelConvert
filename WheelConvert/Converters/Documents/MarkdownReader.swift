import Foundation

/// Parses Markdown (CommonMark with GitHub tables, task lists, strikethrough and footnotes).
struct MarkdownReader {
    /// Folder used to resolve relative image paths; nil disables local images.
    var baseURL: URL?
    private var footnotes: [String: String] = [:]
    private var depth = 0

    init(baseURL: URL?) { self.baseURL = baseURL }

    static func read(_ url: URL) throws -> StructuredDocument {
        let text = try TextDecoding.read(url, limit: 32 * 1024 * 1024)
        var reader = MarkdownReader(baseURL: url.deletingLastPathComponent())
        return reader.parse(text)
    }

    mutating func parse(_ text: String) -> StructuredDocument {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        // Front matter is metadata, not content.
        var title: String?
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            for line in lines[1..<end] where line.lowercased().hasPrefix("title:") {
                title = line.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            lines.removeSubrange(0...end)
        }
        // Footnote definitions can appear anywhere; collect them first.
        var kept: [String] = []
        for line in lines {
            if let match = line.range(of: #"^\[\^([^\]]+)\]:\s?"#, options: .regularExpression) {
                let label = String(line[match].dropFirst(2).prefix { $0 != "]" })
                footnotes[label] = String(line[match.upperBound...])
            } else {
                kept.append(line)
            }
        }
        var doc = StructuredDocument()
        doc.title = title
        doc.blocks = blocks(kept[...])
        return doc
    }

    // MARK: Blocks

    private mutating func blocks(_ lines: ArraySlice<String>) -> [StructuredDocument.Block] {
        depth += 1
        defer { depth -= 1 }
        guard depth < 40 else { return [.paragraph(.init(runs: [.init(lines.joined(separator: "\n"))]))] }
        var out: [StructuredDocument.Block] = []
        var i = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph(_ me: inout MarkdownReader, _ out: inout [StructuredDocument.Block]) {
            guard !paragraph.isEmpty else { return }
            out += me.paragraphBlocks(paragraph)
            paragraph = []
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = Self.indentation(line)

            if trimmed.isEmpty {
                flushParagraph(&self, &out)
                i += 1
                continue
            }
            // Fenced code.
            if indent < 4, let fence = Self.fence(trimmed) {
                flushParagraph(&self, &out)
                var code: [String] = []
                i += 1
                while i < lines.endIndex {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker), candidate.allSatisfy({ $0 == fence.marker.first! }) { break }
                    code.append(Self.dropIndent(lines[i], max: indent))
                    i += 1
                }
                i = min(i + 1, lines.endIndex)
                out.append(.code(code.joined(separator: "\n"), language: fence.info.isEmpty ? nil : fence.info))
                continue
            }
            // ATX heading.
            if indent < 4, let heading = Self.atxHeading(trimmed) {
                flushParagraph(&self, &out)
                out.append(.heading(level: heading.level, runs: inline(heading.text)))
                i += 1
                continue
            }
            // Setext heading underline.
            if indent < 4, !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                let level = trimmed.first == "=" ? 1 : 2
                out.append(.heading(level: level, runs: inline(paragraph.joined(separator: " "))))
                paragraph = []
                i += 1
                continue
            }
            // Thematic break.
            if indent < 4, Self.isRule(trimmed) {
                flushParagraph(&self, &out)
                out.append(.rule)
                i += 1
                continue
            }
            // Block quote.
            if indent < 4, trimmed.hasPrefix(">") {
                flushParagraph(&self, &out)
                var quoted: [String] = []
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else {
                        if t.isEmpty || quoted.isEmpty { break }
                        quoted.append(t) // lazy continuation
                        i += 1
                        continue
                    }
                    var content = t.dropFirst()
                    if content.first == " " { content = content.dropFirst() }
                    quoted.append(String(content))
                    i += 1
                }
                out.append(.quote(blocks(quoted[...])))
                continue
            }
            // Table.
            if indent < 4, trimmed.contains("|"), i + 1 < lines.endIndex, Self.isTableDelimiter(lines[i + 1]) {
                flushParagraph(&self, &out)
                let header = Self.tableCells(trimmed)
                var rows = [header.map { StructuredDocument.Cell(inline($0)) }]
                i += 2
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") || !t.isEmpty && rows.count > 0 && t.first != "#" else { break }
                    guard t.contains("|") else { break }
                    var cells = Self.tableCells(t)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(cells.prefix(max(header.count, 1)).map { StructuredDocument.Cell(inline($0)) })
                    i += 1
                }
                out.append(.table(.init(rows: rows, headerRows: 1)))
                continue
            }
            // List.
            if indent < 4, Self.listMarker(line) != nil {
                flushParagraph(&self, &out)
                let (items, next) = list(lines, from: i, baseIndent: indent)
                out += items
                i = next
                continue
            }
            // Indented code (not inside a paragraph).
            if indent >= 4, paragraph.isEmpty {
                var code: [String] = []
                while i < lines.endIndex, Self.indentation(lines[i]) >= 4 || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(Self.dropIndent(lines[i], max: 4))
                    i += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                out.append(.code(code.joined(separator: "\n"), language: nil))
                continue
            }
            // HTML comment blocks are skipped.
            if trimmed.hasPrefix("<!--") {
                while i < lines.endIndex, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph(&self, &out)
        return out
    }

    /// List items (and nested lists) starting at `start`; returns paragraphs with list levels.
    private mutating func list(_ lines: ArraySlice<String>, from start: Int, baseIndent: Int, level: Int = 0) -> ([StructuredDocument.Block], Int) {
        var out: [StructuredDocument.Block] = []
        var i = start
        var first = true
        while i < lines.endIndex {
            let line = lines[i]
            let indent = Self.indentation(line)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends the list unless an item (or continuation) follows.
                var j = i + 1
                while j < lines.endIndex, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.endIndex, Self.listMarker(lines[j]) != nil || Self.indentation(lines[j]) > baseIndent else { return (out, j) }
                i = j
                continue
            }
            guard let marker = Self.listMarker(line), indent >= baseIndent else {
                if indent > baseIndent, !out.isEmpty, case .paragraph(var p) = out[out.count - 1] {
                    // Continuation text of the last item.
                    p.runs += [.init(" ")] + inline(line.trimmingCharacters(in: .whitespaces))
                    p.runs = StructuredDocument.merge(p.runs)
                    out[out.count - 1] = .paragraph(p)
                    i += 1
                    continue
                }
                return (out, i)
            }
            if indent > baseIndent + 1 && !first {
                let (nested, next) = list(lines, from: i, baseIndent: indent, level: level + 1)
                out += nested
                i = next
                continue
            }
            if indent < baseIndent { return (out, i) }
            var text = marker.content
            var prefix = ""
            if text.hasPrefix("[ ] ") { prefix = "☐ "; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { prefix = "☑ "; text.removeFirst(4) }
            var paragraph = StructuredDocument.Paragraph(runs: (prefix.isEmpty ? [] : [.init(prefix)]) + inline(text))
            paragraph.list = marker.ordered ? .ordered : .unordered
            paragraph.listLevel = level
            if marker.ordered && first { paragraph.listStart = marker.number }
            out.append(.paragraph(paragraph))
            first = false
            i += 1
        }
        return (out, i)
    }

    private mutating func paragraphBlocks(_ lines: [String]) -> [StructuredDocument.Block] {
        var runs: [StructuredDocument.Run] = []
        var images: [StructuredDocument.Block] = []
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var hardBreak = raw.hasSuffix("  ") || line.hasSuffix("\\")
            if line.hasSuffix("\\") { line.removeLast() }
            if line.lowercased().hasSuffix("<br>") || line.lowercased().hasSuffix("<br/>") { hardBreak = true }
            let parsed = inline(line, images: &images)
            runs += parsed
            if index < lines.count - 1 { runs.append(.init(hardBreak ? "\n" : " ")) }
        }
        var out: [StructuredDocument.Block] = []
        let merged = StructuredDocument.merge(runs)
        if !merged.map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty || merged.contains(where: { $0.note != nil }) {
            out.append(.paragraph(.init(runs: merged)))
        }
        return out + images
    }

    // MARK: Inline

    private mutating func inline(_ text: String) -> [StructuredDocument.Run] {
        var images: [StructuredDocument.Block] = []
        return inline(text, images: &images)
    }

    private struct Style { var bold = false, italic = false, strike = false, sup = false, sub = false, link: String? }

    private mutating func inline(_ text: String, images: inout [StructuredDocument.Block]) -> [StructuredDocument.Run] {
        var runs: [StructuredDocument.Run] = []
        var style = Style()
        var buffer = ""
        let chars = Array(text)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = StructuredDocument.Run(buffer, bold: style.bold, italic: style.italic, link: style.link)
            run.strike = style.strike
            run.superscript = style.sup
            run.subscripted = style.sub
            runs.append(run)
            buffer = ""
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>\"'".contains(chars[i + 1]) {
                buffer.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                var ticks = 0
                while i + ticks < chars.count, chars[i + ticks] == "`" { ticks += 1 }
                let fence = String(repeating: "`", count: ticks)
                let rest = String(chars[(i + ticks)...])
                if let end = rest.range(of: fence) {
                    flush()
                    let code = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                    runs.append(.init(code, bold: style.bold, italic: style.italic, code: true, link: style.link))
                    i += ticks + rest.distance(from: rest.startIndex, to: end.upperBound)
                    continue
                }
            }
            // Images and links.
            if c == "!" || c == "[", let link = Self.parseLink(chars, at: c == "!" ? i + 1 : i) {
                if c == "!" {
                    flush()
                    if let image = loadImage(link.destination, alt: link.text) { images.append(.image(image)) }
                    else if !link.text.isEmpty { buffer += link.text }
                    i = link.end
                    continue
                }
                if link.text.hasPrefix("^"), let note = footnotes[String(link.text.dropFirst())], link.destination.isEmpty {
                    flush()
                    var mark = StructuredDocument.Run("")
                    mark.note = note
                    runs.append(mark)
                    i = link.end
                    continue
                }
                flush()
                let saved = style.link
                style.link = link.destination.isEmpty ? nil : link.destination
                var nested: [StructuredDocument.Block] = []
                let inner = inline(link.text, images: &nested)
                runs += inner.map { var r = $0; r.link = style.link ?? r.link; r.bold = r.bold || style.bold; r.italic = r.italic || style.italic; return r }
                images += nested
                style.link = saved
                i = link.end
                continue
            }
            // Footnote reference without a link destination: [^label]
            if c == "[", i + 1 < chars.count, chars[i + 1] == "^", let close = chars[i...].firstIndex(of: "]") {
                let label = String(chars[(i + 2)..<close])
                if let note = footnotes[label] {
                    flush()
                    var mark = StructuredDocument.Run("")
                    mark.note = note
                    runs.append(mark)
                    i = close + 1
                    continue
                }
            }
            // Autolinks.
            if c == "<", let close = chars[i...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    flush()
                    runs.append(.init(inner.replacingOccurrences(of: "mailto:", with: ""), bold: style.bold, italic: style.italic, link: inner))
                    i = close + 1
                    continue
                }
                let tag = inner.lowercased().trimmingCharacters(in: .whitespaces)
                let handled: Bool
                switch tag {
                case "b", "strong": flush(); style.bold = true; handled = true
                case "/b", "/strong": flush(); style.bold = false; handled = true
                case "i", "em": flush(); style.italic = true; handled = true
                case "/i", "/em": flush(); style.italic = false; handled = true
                case "sup": flush(); style.sup = true; handled = true
                case "/sup": flush(); style.sup = false; handled = true
                case "sub": flush(); style.sub = true; handled = true
                case "/sub": flush(); style.sub = false; handled = true
                case "s", "del", "strike": flush(); style.strike = true; handled = true
                case "/s", "/del", "/strike": flush(); style.strike = false; handled = true
                case "br", "br/", "br /": buffer += "\n"; handled = true
                default: handled = tag.range(of: #"^/?[a-z][a-z0-9]*(\s[^>]*)?/?$"#, options: .regularExpression) != nil
                }
                if handled { i = close + 1; continue }
            }
            // Emphasis.
            if c == "*" || c == "_" || c == "~" {
                var count = 0
                while i + count < chars.count, chars[i + count] == c { count += 1 }
                let before = i > 0 ? chars[i - 1] : " ", after = i + count < chars.count ? chars[i + count] : " "
                let canOpen = !after.isWhitespace && (c != "_" || !before.isLetter && !before.isNumber)
                let canClose = !before.isWhitespace && (c != "_" || !after.isLetter && !after.isNumber)
                if c == "~" {
                    if count >= 2 && (canOpen || canClose) {
                        flush()
                        if style.strike && canClose { style.strike = false } else if canOpen { style.strike = true }
                        i += count
                        continue
                    }
                } else if canOpen || canClose {
                    flush()
                    var remaining = min(count, 3)
                    if remaining >= 2 {
                        if style.bold && canClose { style.bold = false } else if canOpen && Self.hasCloser(chars, from: i + count, marker: c, count: 2) { style.bold = true } else { buffer += String(repeating: c, count: 2) }
                        remaining -= 2
                    }
                    if remaining == 1 {
                        if style.italic && canClose { style.italic = false } else if canOpen && Self.hasCloser(chars, from: i + count, marker: c, count: 1) { style.italic = true } else { buffer.append(c) }
                    }
                    i += count
                    continue
                }
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return StructuredDocument.merge(Self.decodeEntities(runs))
    }

    private static func hasCloser(_ chars: [Character], from start: Int, marker: Character, count: Int) -> Bool {
        var i = start
        while i < chars.count {
            if chars[i] == marker {
                var run = 0
                while i + run < chars.count, chars[i + run] == marker { run += 1 }
                if run >= count, i > 0, !chars[i - 1].isWhitespace { return true }
                i += run
            } else {
                i += 1
            }
        }
        return false
    }

    private static func decodeEntities(_ runs: [StructuredDocument.Run]) -> [StructuredDocument.Run] {
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": "\u{00A0}", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&copy;": "©"]
        return runs.map { run in
            guard run.text.contains("&") else { return run }
            var copy = run
            for (key, value) in entities { copy.text = copy.text.replacingOccurrences(of: key, with: value) }
            return copy
        }
    }

    /// `[text](destination "title")` starting at the "[" index.
    private static func parseLink(_ chars: [Character], at start: Int) -> (text: String, destination: String, end: Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var depth = 0, i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "[" { depth += 1 }
            if chars[i] == "]" { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        guard i < chars.count, i + 1 < chars.count, chars[i + 1] == "(" else { return nil }
        let text = String(chars[(start + 1)..<i])
        var j = i + 2, parens = 1
        while j < chars.count {
            if chars[j] == "(" { parens += 1 }
            if chars[j] == ")" { parens -= 1; if parens == 0 { break } }
            j += 1
        }
        guard j < chars.count else { return nil }
        var inside = String(chars[(i + 2)..<j]).trimmingCharacters(in: .whitespaces)
        if inside.hasPrefix("<"), let close = inside.firstIndex(of: ">") { inside = String(inside[inside.index(after: inside.startIndex)..<close]) }
        else if let space = inside.firstIndex(of: " ") { inside = String(inside[..<space]) }
        return (text, inside, j + 1)
    }

    private func loadImage(_ source: String, alt: String) -> StructuredDocument.Image? {
        if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
           let data = Data(base64Encoded: String(source[source.index(after: comma)...])) {
            return .init(data: data, alt: alt)
        }
        // Only local files next to the document; remote images are never fetched.
        guard let baseURL, !source.contains("://"), !source.hasPrefix("/") else { return nil }
        let path = source.removingPercentEncoding ?? source
        let url = baseURL.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(baseURL.standardizedFileURL.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 50 * 1024 * 1024,
              let data = try? Data(contentsOf: url), ImageSniffer.mime(data).hasPrefix("image/") else { return nil }
        return .init(data: data, alt: alt)
    }

    // MARK: Line helpers

    static func indentation(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break }
        }
        return n
    }

    static func dropIndent(_ line: String, max: Int) -> String {
        var dropped = 0
        var index = line.startIndex
        while index < line.endIndex, dropped < max, line[index] == " " || line[index] == "\t" {
            dropped += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    static func fence(_ trimmed: String) -> (marker: String, info: String)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let run = trimmed.prefix { $0 == marker.first! }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if marker == "```" && info.contains("`") { return nil }
            return (String(run), String(info.split(separator: " ").first ?? ""))
        }
        return nil
    }

    static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"\s+#+\s*$"#, options: .regularExpression) { text.removeSubrange(range) }
        if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes, text)
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listMarker(_ line: String) -> (ordered: Bool, number: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " || trimmed.count == 1 {
            if isRule(trimmed) { return nil }
            return (false, 0, String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " || rest.count == 1 else { return nil }
        return (true, Int(digits) ?? 1, String(rest.dropFirst(2)))
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let cells = tableCells(trimmed)
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil }
    }

    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for c in text {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; current.append(c); continue }
            if c == "`" { inCode.toggle() }
            if c == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(c)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }
}

/// Text file decoding with BOM detection and sensible fallbacks.
enum TextDecoding {
    static func read(_ url: URL, limit: Int) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw WheelError("The text file is unreadable or exceeds the \(limit / 1024 / 1024) MB import limit.") }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { if let s = String(data: data, encoding: .utf16LittleEndian) { return String(s.drop { $0 == "\u{FEFF}" }) } }
        if data.starts(with: [0xFE, 0xFF]) { if let s = String(data: data, encoding: .utf16BigEndian) { return String(s.drop { $0 == "\u{FEFF}" }) } }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.macOSRoman.rawValue]], convertedString: &converted, usedLossyConversion: nil)
        if encoding != 0, let converted { return converted as String }
        if let latin = String(data: data, encoding: .windowsCP1252) { return latin }
        throw WheelError("The file has invalid text encoding. Save it as UTF-8 in TextEdit and try again.")
    }
}
