import Foundation

/// GitHub-flavored Markdown output. Images are embedded as data URLs so the file stands alone.
struct MarkdownWriter {
    private var notes: [String] = []

    mutating func write(_ doc: StructuredDocument) -> String {
        var out = blocks(doc.blocks, indent: "")
        if !notes.isEmpty {
            out += "\n"
            for (i, note) in notes.enumerated() { out += "[^\(i + 1)]: \(note.replacingOccurrences(of: "\n", with: " "))\n" }
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    private mutating func blocks(_ blocks: [StructuredDocument.Block], indent: String) -> String {
        var out = ""
        var counters: [Int: Int] = [:]
        var previousWasList = false
        for block in blocks {
            var isList = false
            if case .paragraph(let p) = block, p.list != nil { isList = true }
            // A list ends with a blank line before whatever follows it.
            if previousWasList && !isList { out += "\n" }
            switch block {
            case .heading(let level, let r):
                out += "\(String(repeating: "#", count: min(max(level, 1), 6))) \(runs(r).replacingOccurrences(of: "\n", with: " "))\n\n"
            case .paragraph(let p):
                if let list = p.list {
                    let pad = String(repeating: "   ", count: p.listLevel)
                    let marker: String
                    if list == .ordered {
                        let n = (counters[p.listLevel] ?? ((p.listStart ?? 1) - 1)) + 1
                        counters[p.listLevel] = n
                        for deeper in counters.keys where deeper > p.listLevel { counters[deeper] = nil }
                        marker = "\(n)."
                    } else {
                        marker = "-"
                    }
                    let body = runs(p.runs).replacingOccurrences(of: "\n", with: "  \n\(indent)\(pad)   ")
                    out += "\(indent)\(pad)\(marker) \(body)\n"
                } else {
                    let text = escapeLeading(runs(p.runs)).replacingOccurrences(of: "\n", with: "  \n\(indent)")
                    out += text.isEmpty ? "" : "\(indent)\(text)\n\n"
                }
            case .quote(let inner):
                let body = self.blocks(inner, indent: "").trimmingCharacters(in: .newlines)
                out += body.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            case .code(let text, let language):
                let fence = text.contains("```") ? "~~~~" : "```"
                out += "\(fence)\(language ?? "")\n\(text)\n\(fence)\n\n"
            case .table(let table):
                out += self.table(table) + "\n"
            case .image(let image):
                let alt = (image.alt ?? "").replacingOccurrences(of: "]", with: "\\]")
                out += "![\(alt)](data:\(image.mime);base64,\(image.data.base64EncodedString()))\n\n"
            case .rule:
                out += "---\n\n"
            case .pageBreak:
                out += "\n"
            }
            if !isList { counters = [:] }
            previousWasList = isList
        }
        if previousWasList { out += "\n" }
        return out
    }

    private mutating func table(_ table: StructuredDocument.Table) -> String {
        let width = table.rows.map { $0.reduce(0) { $0 + max(1, $1.columnSpan) } }.max() ?? 0
        guard width > 0 else { return "" }
        func row(_ cells: [StructuredDocument.Cell]) -> String {
            var values: [String] = []
            for cell in cells {
                let text = cell.blocks.map { b -> String in
                    if case .paragraph(let p) = b { return runs(p.runs) }
                    return b.plainText
                }.joined(separator: "<br>").replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|")
                values.append(text)
                for _ in 1..<max(1, cell.columnSpan) { values.append("") }
            }
            while values.count < width { values.append("") }
            return "| " + values.joined(separator: " | ") + " |"
        }
        var lines: [String] = []
        let header = table.headerRows > 0 ? table.rows[0] : Array(repeating: StructuredDocument.Cell([]), count: width)
        lines.append(row(header))
        lines.append("|" + Array(repeating: " --- |", count: width).joined())
        for r in table.rows.dropFirst(table.headerRows > 0 ? 1 : 0) { lines.append(row(r)) }
        return lines.joined(separator: "\n") + "\n"
    }

    private mutating func runs(_ runs: [StructuredDocument.Run]) -> String {
        var out = ""
        for run in runs {
            guard !run.text.isEmpty || run.note != nil else { continue }
            var text: String
            if run.code {
                let ticks = run.text.contains("`") ? "``" : "`"
                text = "\(ticks)\(run.text)\(ticks)"
            } else {
                text = escapeInline(run.text)
            }
            // Keep emphasis markers tight around the words.
            let leading = String(text.prefix { $0 == " " }), trailing = String(text.reversed().prefix { $0 == " " })
            var core = String(text.dropFirst(leading.count).dropLast(trailing.count))
            if !core.isEmpty {
                if run.strike { core = "~~\(core)~~" }
                if run.italic { core = "*\(core)*" }
                if run.bold { core = "**\(core)**" }
                if run.superscript { core = "<sup>\(core)</sup>" }
                if run.subscripted { core = "<sub>\(core)</sub>" }
                if let link = run.link, let safe = HTMLWriter.safeLink(link) { core = "[\(core)](\(safe.replacingOccurrences(of: ")", with: "%29")))" }
            }
            text = leading + core + trailing
            out += text
            if let note = run.note {
                notes.append(note)
                out += "[^\(notes.count)]"
            }
        }
        return out
    }

    private func escapeInline(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A paragraph that starts like a heading or list item must not become one.
    private func escapeLeading(_ text: String) -> String {
        if let first = text.first, "#>+-=".contains(first) { return "\\" + text }
        if let match = text.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
            let marker = text[match].dropLast(2)
            return marker + "\\" + text[text.index(match.upperBound, offsetBy: -2)...]
        }
        return text
    }
}

/// Plain text output with readable list markers and tab-separated tables.
enum PlainTextWriter {
    static func write(_ doc: StructuredDocument) -> String {
        var out = ""
        write(doc.blocks, into: &out)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func write(_ blocks: [StructuredDocument.Block], into out: inout String) {
        var counters: [Int: Int] = [:]
        var inList = false
        for block in blocks {
            switch block {
            case .heading(_, let runs):
                if inList { out += "\n" }
                out += runs.map(\.text).joined() + "\n\n"
                inList = false
            case .paragraph(let p):
                if let list = p.list {
                    let pad = String(repeating: "    ", count: p.listLevel)
                    let marker: String
                    if list == .ordered {
                        let n = (counters[p.listLevel] ?? ((p.listStart ?? 1) - 1)) + 1
                        counters[p.listLevel] = n
                        marker = "\(n)."
                    } else {
                        marker = ["•", "◦", "▪"][p.listLevel % 3]
                    }
                    out += "\(pad)\(marker) \(p.plainText)\n"
                    inList = true
                } else {
                    if inList { out += "\n" }
                    counters = [:]
                    let text = p.plainText
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { out += text + "\n\n" }
                    inList = false
                }
            case .quote(let inner):
                var nested = ""
                write(inner, into: &nested)
                out += nested.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n"
                inList = false
            case .code(let text, _):
                out += text + "\n\n"
                inList = false
            case .table(let table):
                for row in table.rows { out += row.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") + "\n" }
                out += "\n"
                inList = false
            case .image(let image):
                if let alt = image.alt, !alt.isEmpty { out += "[\(alt)]\n\n" }
            case .rule:
                out += "────────\n\n"
            case .pageBreak:
                out += "\u{0C}\n"
            }
        }
    }
}
