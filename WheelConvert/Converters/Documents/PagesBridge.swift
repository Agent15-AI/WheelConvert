import Foundation
import JavaScriptCore
import Security

/// Reads and writes Apple Pages documents through the bundled cupertino-files library
/// running in JavaScriptCore.
enum PagesBridge {
    static func read(_ url: URL) throws -> StructuredDocument {
        let bytes = try packageBytes(url)
        let json = try call("wcPagesRead", [bytes.base64EncodedString()])
        guard let data = json.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WheelError("This Pages document could not be read.")
        }
        return document(from: object)
    }

    static func write(_ doc: StructuredDocument) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object(from: doc))
        let base64 = try call("wcPagesWrite", [String(decoding: json, as: UTF8.self)])
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { throw WheelError("The native Pages writer failed.") }
        return data
    }

    /// Modern Pages files are ZIP archives; older ones are folders, which are zipped in memory.
    static func packageBytes(_ url: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= 128 * 1024 * 1024 else { throw WheelError("The Pages archive exceeds the 128 MB import limit.") }
            return try Data(contentsOf: url)
        }
        var zip = ZipWriter()
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw WheelError("This Pages document could not be read.")
        }
        var total = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))
            let data = try Data(contentsOf: file)
            total += data.count
            guard total <= 128 * 1024 * 1024 else { throw WheelError("The Pages package contains unsafe entries or is too large.") }
            try zip.add(relative, data, compress: false)
        }
        return zip.finish()
    }

    private static let script: String? = try? String(contentsOf: Bundled.pagesBridge, encoding: .utf8)

    private static func call(_ function: String, _ arguments: [String]) throws -> String {
        guard let script else { throw WheelError("The native Pages writer is unavailable.") }
        guard let context = JSContext() else { throw WheelError("The native Pages writer is unavailable.") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "unknown error" }
        let random: @convention(block) (Int) -> [UInt8] = { count in
            var bytes = [UInt8](repeating: 0, count: max(0, min(count, 65_536)))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes
        }
        context.setObject(random, forKeyedSubscript: "wcRandomBytes" as NSString)
        context.evaluateScript(script)
        if let failure { throw WheelError("The native Pages writer failed: \(failure)") }
        let result = context.objectForKeyedSubscript(function)?.call(withArguments: arguments)
        if let failure {
            throw function == "wcPagesRead" ? WheelError("This Pages document couldn’t be read. It may be damaged, password-protected or from an unsupported Pages version.")
                                            : WheelError("The Pages document couldn’t be created: \(failure)")
        }
        guard let text = result?.toString(), result?.isString == true else { throw WheelError("The native Pages writer is unavailable.") }
        return text
    }

    // MARK: JSON → StructuredDocument

    static func document(from object: [String: Any]) -> StructuredDocument {
        var doc = StructuredDocument()
        if let page = object["page"] as? [String: Any], let w = page["width"] as? Double, let h = page["height"] as? Double {
            doc.page = .init(width: w, height: h, top: page["top"] as? Double ?? 72, right: page["right"] as? Double ?? 72,
                             bottom: page["bottom"] as? Double ?? 72, left: page["left"] as? Double ?? 72)
        }
        for item in object["blocks"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "paragraph":
                let runs = (item["runs"] as? [[String: Any]] ?? []).map(run(from:))
                let style = (item["style"] as? String ?? "").lowercased()
                if let level = headingLevel(style) {
                    if style == "title", doc.title == nil { doc.title = runs.map(\.text).joined() }
                    doc.blocks.append(.heading(level: level, runs: runs))
                    continue
                }
                var paragraph = StructuredDocument.Paragraph(runs: runs)
                if let list = item["list"] as? String {
                    let ordered = ["number", "letter", "legal", "harvard", "roman", "1"].contains { list.lowercased().contains($0) }
                    paragraph.list = ordered ? .ordered : .unordered
                }
                if let alignment = item["alignment"] as? Int { paragraph.alignment = .init(rawValue: alignment) ?? .left }
                if style.contains("quote") { doc.blocks.append(.quote([.paragraph(paragraph)])) } else { doc.blocks.append(.paragraph(paragraph)) }
            case "image":
                if let base64 = item["data"] as? String, let data = Data(base64Encoded: base64) {
                    doc.blocks.append(.image(.init(data: data, width: item["width"] as? Double, height: item["height"] as? Double, name: item["name"] as? String)))
                }
            case "table":
                let rows = item["rows"] as? [[String]] ?? []
                var cells = rows.map { $0.map { StructuredDocument.Cell([.init($0)]) } }
                var covered = Set<[Int]>()
                for merge in item["merges"] as? [[String: Int]] ?? [] {
                    guard let r = merge["row"], let c = merge["column"], r < cells.count, c < cells[r].count else { continue }
                    cells[r][c].rowSpan = max(1, merge["rowSpan"] ?? 1)
                    cells[r][c].columnSpan = max(1, merge["columnSpan"] ?? 1)
                    for rr in r..<(r + cells[r][c].rowSpan) { for cc in c..<(c + cells[r][c].columnSpan) where rr != r || cc != c { covered.insert([rr, cc]) } }
                }
                let kept = cells.enumerated().map { r, row in row.enumerated().filter { !covered.contains([r, $0.offset]) }.map(\.element) }
                doc.blocks.append(.table(.init(rows: kept, headerRows: item["headerRows"] as? Int ?? 0)))
            case "pageBreak":
                doc.blocks.append(.pageBreak)
            default:
                break
            }
        }
        return doc
    }

    static func headingLevel(_ style: String) -> Int? {
        switch style {
        case "title", "heading", "heading 1", "chapter title": return 1
        case "subtitle", "heading 2", "section", "chapter subtitle": return 2
        default:
            if style.hasPrefix("heading "), let n = Int(style.dropFirst(8)), (1...6).contains(n) { return n }
            return nil
        }
    }

    private static func run(from item: [String: Any]) -> StructuredDocument.Run {
        var run = StructuredDocument.Run((item["text"] as? String ?? "").replacingOccurrences(of: "\u{2028}", with: "\n"))
        run.bold = item["bold"] as? Bool ?? false
        run.italic = item["italic"] as? Bool ?? false
        run.underline = item["underline"] as? Bool ?? false
        run.strike = item["strike"] as? Bool ?? false
        run.superscript = item["superscript"] as? Bool ?? false
        run.subscripted = item["subscript"] as? Bool ?? false
        run.color = item["color"] as? String
        run.link = item["link"] as? String
        run.note = item["note"] as? String
        return run
    }

    // MARK: StructuredDocument → JSON

    static func object(from doc: StructuredDocument) -> [String: Any] {
        var blocks: [[String: Any]] = []
        func runs(_ runs: [StructuredDocument.Run], code: Bool = false, italic: Bool = false) -> [[String: Any]] {
            runs.map { r in
                var item: [String: Any] = ["text": r.text + (r.note.map { " (\($0))" } ?? "")]
                if r.bold { item["bold"] = true }
                if r.italic || italic { item["italic"] = true }
                if r.underline { item["underline"] = true }
                if r.strike { item["strike"] = true }
                if r.superscript { item["superscript"] = true }
                if r.subscripted { item["subscript"] = true }
                if r.code || code { item["code"] = true }
                if let color = r.color { item["color"] = color }
                if let link = r.link.flatMap(HTMLWriter.safeLink), !link.hasPrefix("#") { item["link"] = link }
                return item
            }
        }
        func add(_ block: StructuredDocument.Block, quoted: Bool = false) {
            switch block {
            case .heading(let level, let r):
                blocks.append(["type": "heading", "level": level, "runs": runs(r)])
            case .paragraph(let p):
                var item: [String: Any] = ["type": "paragraph", "runs": runs(p.runs, italic: quoted), "alignment": p.alignment.rawValue]
                if let list = p.list { item["list"] = list.rawValue }
                blocks.append(item)
            case .quote(let inner):
                inner.forEach { add($0, quoted: true) }
            case .code(let text, _):
                for line in text.components(separatedBy: "\n") {
                    blocks.append(["type": "paragraph", "runs": [["text": line, "code": true]]])
                }
            case .table(let table):
                let rows = table.rows.map { $0.flatMap { cell -> [String] in [cell.plainText] + Array(repeating: "", count: max(0, cell.columnSpan - 1)) } }
                blocks.append(["type": "table", "rows": rows, "headerRows": table.headerRows])
            case .image(let image):
                guard let data = ImageSniffer.raster(image.data) else {
                    if let alt = image.alt { blocks.append(["type": "paragraph", "alignment": 2, "runs": [["text": "[\(alt)]"]]]) }
                    return
                }
                var item: [String: Any] = ["type": "image", "data": data.base64EncodedString(), "name": "image.\(ImageSniffer.fileExtension(data))"]
                if let w = image.width { item["width"] = w }
                if let h = image.height { item["height"] = h }
                blocks.append(item)
            case .rule:
                blocks.append(["type": "paragraph", "alignment": 2, "runs": [["text": "⁂"]]])
            case .pageBreak:
                blocks.append(["type": "pageBreak"])
            }
        }
        doc.blocks.forEach { add($0) }
        var result: [String: Any] = ["blocks": blocks]
        if let page = doc.page {
            result["page"] = ["width": page.width, "height": page.height, "top": page.top, "right": page.right, "bottom": page.bottom, "left": page.left]
        }
        return result
    }
}
