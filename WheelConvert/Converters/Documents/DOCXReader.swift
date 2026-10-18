import Foundation

/// Reads Word (.docx) documents into a StructuredDocument.
enum DOCXReader {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let rNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let wpNS = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let vNS = "urn:schemas-microsoft-com:vml"
    static let mcNS = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    struct Style {
        var name = ""
        var basedOn: String?
        var outlineLevel: Int?
        var bold: Bool?
        var italic: Bool?
        var underline: Bool?
        var monospace = false
    }

    struct Relationship { let type: String; let target: String; let external: Bool }

    struct Context {
        var zip: ZipArchive
        var relationships: [String: Relationship] = [:]
        var styles: [String: Style] = [:]
        var numberingFormats: [String: [Int: (format: String, start: Int)]] = [:]
        var footnotes: [String: String] = [:]
        var endnotes: [String: String] = [:]
    }

    static func read(_ url: URL) throws -> StructuredDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 128 * 1024 * 1024 else { throw WheelError("The document is empty or exceeds the 128 MB import limit.") }
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch { throw WheelError("This file is not a readable DOCX document.") }
        guard let main = mainDocumentPath(zip) else { throw WheelError("This file is not a readable DOCX document.") }
        let folder = (main as NSString).deletingLastPathComponent
        var context = Context(zip: zip)
        context.relationships = relationships(zip, for: main)
        if let data = try? zip.read(folder + "/styles.xml") { context.styles = parseStyles(data) }
        if let data = try? zip.read(folder + "/numbering.xml") { context.numberingFormats = parseNumbering(data) }
        context.footnotes = parseNotes(zip, path: folder + "/footnotes.xml", element: "footnote", context: context)
        context.endnotes = parseNotes(zip, path: folder + "/endnotes.xml", element: "endnote", context: context)

        let documentData = try zip.read(main)
        try rejectDTD(documentData)
        let parser = DocumentParser(context: context, folder: folder)
        let xml = XMLParser(data: documentData)
        xml.shouldProcessNamespaces = true
        xml.shouldResolveExternalEntities = false
        xml.delegate = parser
        guard xml.parse() else { throw WheelError("The document contains malformed XML.") }
        var doc = StructuredDocument()
        doc.blocks = parser.finish()
        doc.page = parser.page
        if let core = try? zip.read("docProps/core.xml") {
            let meta = CoreProperties.parse(core)
            doc.title = meta.title
            doc.author = meta.creator
            doc.language = meta.language
        }
        return doc
    }

    static func rejectDTD(_ data: Data) throws {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        if head.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil || head.range(of: "<!ENTITY", options: .caseInsensitive) != nil {
            throw WheelError("Document XML entity declarations are not supported.")
        }
    }

    static func mainDocumentPath(_ zip: ZipArchive) -> String? {
        if let rels = try? zip.read("_rels/.rels") {
            let parsed = parseRelationships(rels)
            if let main = parsed.values.first(where: { $0.type.hasSuffix("/officeDocument") }) {
                return main.target.hasPrefix("/") ? String(main.target.dropFirst()) : main.target
            }
        }
        return zip.contains("word/document.xml") ? "word/document.xml" : nil
    }

    static func relationships(_ zip: ZipArchive, for part: String) -> [String: Relationship] {
        let folder = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        guard let data = try? zip.read("\(folder)/_rels/\(name).rels") else { return [:] }
        return parseRelationships(data).mapValues { rel in
            guard !rel.external else { return rel }
            let target = rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : normalize(folder + "/" + rel.target)
            return Relationship(type: rel.type, target: target, external: false)
        }
    }

    /// Resolves "." and ".." so relationship targets map onto archive paths.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    static func parseRelationships(_ data: Data) -> [String: Relationship] {
        final class Delegate: NSObject, XMLParserDelegate {
            var result: [String: Relationship] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
                result[id] = Relationship(type: attributes["Type"] ?? "", target: target.removingPercentEncoding ?? target,
                                          external: attributes["TargetMode"] == "External")
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    static func parseStyles(_ data: Data) -> [String: Style] {
        final class Delegate: NSObject, XMLParserDelegate {
            var styles: [String: Style] = [:]
            var current: (id: String, style: Style)?
            var inRunProps = false
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                let value = attributes["w:val"] ?? attributes["val"]
                switch name {
                case "style": current = (attributes["w:styleId"] ?? attributes["styleId"] ?? "", Style())
                case "name": current?.style.name = value ?? ""
                case "basedOn": current?.style.basedOn = value
                case "outlineLvl": current?.style.outlineLevel = value.flatMap(Int.init)
                case "rPr": inRunProps = true
                case "b" where inRunProps: current?.style.bold = DOCXReader.toggle(value)
                case "i" where inRunProps: current?.style.italic = DOCXReader.toggle(value)
                case "u" where inRunProps: current?.style.underline = value != "none"
                case "rFonts" where inRunProps:
                    let font = (attributes["w:ascii"] ?? attributes["ascii"] ?? "").lowercased()
                    if ["courier", "mono", "menlo", "consolas", "monaco"].contains(where: font.contains) { current?.style.monospace = true }
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "rPr" { inRunProps = false }
                if name == "style", let current { styles[current.id] = current.style; self.current = nil }
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.styles
    }

    static func toggle(_ value: String?) -> Bool {
        guard let value else { return true }
        return !["0", "false", "off", "none"].contains(value.lowercased())
    }

    static func parseNumbering(_ data: Data) -> [String: [Int: (format: String, start: Int)]] {
        final class Delegate: NSObject, XMLParserDelegate {
            var abstracts: [String: [Int: (String, Int)]] = [:]
            var nums: [String: String] = [:]
            var overrides: [String: [Int: Int]] = [:]
            var abstract: String?, level: Int?, num: String?, overrideLevel: Int?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                let value = attributes["w:val"] ?? attributes["val"]
                switch name {
                case "abstractNum": abstract = attributes["w:abstractNumId"] ?? attributes["abstractNumId"]
                case "lvl":
                    if let lvl = (attributes["w:ilvl"] ?? attributes["ilvl"]).flatMap(Int.init) {
                        if let abstract { level = lvl; abstracts[abstract, default: [:]][lvl] = ("decimal", 1) }
                        else if num != nil { overrideLevel = lvl }
                    }
                case "numFmt": if let abstract, let level { abstracts[abstract]?[level]?.0 = value ?? "decimal" }
                case "start": if let abstract, let level, let n = value.flatMap(Int.init) { abstracts[abstract]?[level]?.1 = n }
                case "num": num = attributes["w:numId"] ?? attributes["numId"]
                case "abstractNumId": if let num, let value { nums[num] = value }
                case "lvlOverride": overrideLevel = (attributes["w:ilvl"] ?? attributes["ilvl"]).flatMap(Int.init)
                case "startOverride": if let num, let overrideLevel, let n = value.flatMap(Int.init) { overrides[num, default: [:]][overrideLevel] = n }
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch name {
                case "abstractNum": abstract = nil
                case "lvl": level = nil
                case "num": num = nil
                case "lvlOverride": overrideLevel = nil
                default: break
                }
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        var result: [String: [Int: (format: String, start: Int)]] = [:]
        for (num, abstract) in delegate.nums {
            var levels: [Int: (format: String, start: Int)] = [:]
            for (level, value) in delegate.abstracts[abstract] ?? [:] {
                levels[level] = (value.0, delegate.overrides[num]?[level] ?? value.1)
            }
            result[num] = levels
        }
        return result
    }

    static func parseNotes(_ zip: ZipArchive, path: String, element: String, context: Context) -> [String: String] {
        guard let data = try? zip.read(path) else { return [:] }
        final class Delegate: NSObject, XMLParserDelegate {
            let element: String
            var notes: [String: String] = [:]
            var current: String?
            var text = ""
            var inText = false
            init(element: String) { self.element = element }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                if name == element, (attributes["w:type"] ?? attributes["type"]) == nil { current = attributes["w:id"] ?? attributes["id"]; text = "" }
                if name == "t" { inText = true }
                if name == "p", current != nil, !text.isEmpty { text += " " }
                if name == "tab", current != nil { text += " " }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { if inText, current != nil { text += string } }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "t" { inText = false }
                if name == element, let current { notes[current] = text.trimmingCharacters(in: .whitespacesAndNewlines); self.current = nil }
            }
        }
        let delegate = Delegate(element: element)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.notes
    }

    // MARK: Body

    final class DocumentParser: NSObject, XMLParserDelegate {
        let context: Context
        let folder: String
        var page: StructuredDocument.PageSetup?

        // Container stack: the body, then table cells (each holds its own blocks).
        private var containers: [[StructuredDocument.Block]] = [[]]
        private struct TableState {
            var rows: [[StructuredDocument.Cell]] = []
            var row: [StructuredDocument.Cell] = []
            var headerRows = 0
            var rowIsHeader = false
            var cellSpan = 1
            var cellMerge: String?   // "restart" or "continue"
            var gridColumn = 0
            var mergeStarts: [Int: (row: Int, column: Int)] = [:] // grid column -> cell index of the restart
            var rowGridColumns: [[Int]] = []
            var currentRowGrid: [Int] = []
        }
        private var tables: [TableState] = []

        // Paragraph state.
        private var inParagraph = false
        private var paragraphStyle: String?
        private var alignment: StructuredDocument.Alignment = .left
        private var rtl = false
        private var numId: String?
        private var level = 0
        private var runs: [StructuredDocument.Run] = []

        // Run state.
        private var inRunProps = false
        private var run = StructuredDocument.Run("")
        private var inText = false
        private var deleted = 0
        private var skipDepth = 0           // mc:Fallback and other ignored subtrees
        private var linkStack: [String?] = []
        private var fieldInstruction = ""
        private var fieldLink: String?
        private var inInstruction = false
        private var fieldDepth = 0
        private var lastListKey: String?

        init(context: Context, folder: String) {
            self.context = context
            self.folder = folder
        }

        func finish() -> [StructuredDocument.Block] { mergeCode(containers.first ?? []) }

        private func styleChain(_ id: String?) -> [Style] {
            var chain: [Style] = []
            var current = id
            var seen = Set<String>()
            while let key = current, let style = context.styles[key], seen.insert(key).inserted, chain.count < 20 {
                chain.append(style)
                current = style.basedOn
            }
            return chain
        }

        private func headingLevel(_ id: String?) -> Int? {
            for style in styleChain(id) {
                let name = style.name.lowercased()
                if name == "title" { return 1 }
                if name == "subtitle" { return 2 }
                if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)), (1...9).contains(n) { return min(n, 6) }
                if let outline = style.outlineLevel, outline < 9 { return min(outline + 1, 6) }
            }
            return nil
        }

        private func styleName(_ id: String?) -> String { styleChain(id).first?.name.lowercased() ?? "" }

        private func attribute(_ attributes: [String: String], _ name: String) -> String? {
            attributes["w:" + name] ?? attributes[name] ?? attributes.first { $0.key.hasSuffix(":" + name) }?.value
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if skipDepth > 0 { skipDepth += 1; return }
            if namespaceURI == mcNS && name == "Fallback" { skipDepth = 1; return }
            let value = attribute(attributes, "val")
            switch (namespaceURI, name) {
            case (w, "p"):
                inParagraph = true
                paragraphStyle = nil; alignment = .left; rtl = false; numId = nil; level = 0; runs = []
            case (w, "pStyle"): paragraphStyle = value
            case (w, "jc"):
                switch value {
                case "center": alignment = .center
                case "right", "end": alignment = .right
                case "both", "distribute": alignment = .justified
                default: alignment = .left
                }
            case (w, "bidi"): rtl = DOCXReader.toggle(value)
            case (w, "numId"): numId = value
            case (w, "ilvl"): level = value.flatMap(Int.init) ?? 0
            case (w, "r"):
                run = StructuredDocument.Run("")
                run.link = linkStack.last ?? nil ?? fieldLink
            case (w, "rPr") where inParagraph: inRunProps = true
            case (w, "rStyle") where inRunProps:
                for style in styleChain(value) {
                    let lower = style.name.lowercased()
                    if style.bold == true || lower.contains("strong") { run.bold = true }
                    if style.italic == true || lower.contains("emphasis") { run.italic = true }
                    if style.monospace || lower.contains("code") || lower.contains("verbatim") { run.code = true }
                }
            case (w, "b") where inRunProps: run.bold = DOCXReader.toggle(value)
            case (w, "i") where inRunProps: run.italic = DOCXReader.toggle(value)
            case (w, "u") where inRunProps: run.underline = value != "none"
            case (w, "strike") where inRunProps, (w, "dstrike") where inRunProps: run.strike = DOCXReader.toggle(value)
            case (w, "vertAlign") where inRunProps:
                run.superscript = value == "superscript"
                run.subscripted = value == "subscript"
            case (w, "color") where inRunProps:
                if let value, value.count == 6, value.lowercased() != "000000", value.allSatisfy(\.isHexDigit) { run.color = value.uppercased() }
            case (w, "rFonts") where inRunProps:
                let font = (attribute(attributes, "ascii") ?? "").lowercased()
                if ["courier", "mono", "menlo", "consolas", "monaco"].contains(where: font.contains) { run.code = true }
            case (w, "t"): inText = deleted == 0
            case (w, "delText"): inText = false
            case (w, "del"), (w, "moveFrom"): deleted += 1
            case (w, "pPr"): inParagraphProps = true
            case (w, "tab") where inParagraph && !inRunProps && !inParagraphProps: append("\t")
            case (w, "txbxContent"):
                // Text boxes nest whole paragraphs inside a run; park the outer paragraph meanwhile.
                saved.append(SavedParagraph(inParagraph: inParagraph, style: paragraphStyle, alignment: alignment, rtl: rtl,
                                            numId: numId, level: level, runs: runs, run: run))
                containers.append([])
            case (w, "br"), (w, "cr"):
                if attribute(attributes, "type") == "page" { breakParagraph(with: .pageBreak) } else { append("\n") }
            case (w, "noBreakHyphen"): append("-")
            case (w, "sym"):
                if let char = attribute(attributes, "char"), let code = UInt32(char, radix: 16), let scalar = Unicode.Scalar(code > 0xF000 ? code - 0xF000 : code) {
                    append(String(Character(scalar)))
                }
            case (w, "hyperlink"):
                if let id = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value, let rel = context.relationships[id], rel.external {
                    linkStack.append(rel.target)
                } else if let anchor = attribute(attributes, "anchor") {
                    linkStack.append("#" + anchor)
                } else {
                    linkStack.append(nil)
                }
            case (w, "fldChar"):
                switch attribute(attributes, "fldCharType") {
                case "begin": fieldDepth += 1; fieldInstruction = ""
                case "separate":
                    if let match = fieldInstruction.range(of: #"HYPERLINK\s+"([^"]+)""#, options: .regularExpression) {
                        let url = fieldInstruction[match].replacingOccurrences(of: #"HYPERLINK\s+""#, with: "", options: .regularExpression).dropLast()
                        fieldLink = String(url)
                    }
                case "end": fieldDepth = max(0, fieldDepth - 1); fieldLink = nil; fieldInstruction = ""
                default: break
                }
            case (w, "instrText"): inInstruction = true
            case (w, "fldSimple"):
                if let instr = attribute(attributes, "instr"), let match = instr.range(of: #"HYPERLINK\s+"([^"]+)""#, options: .regularExpression) {
                    fieldLink = String(instr[match].replacingOccurrences(of: #"HYPERLINK\s+""#, with: "", options: .regularExpression).dropLast())
                }
            case (w, "footnoteReference"), (w, "endnoteReference"):
                let id = attribute(attributes, "id") ?? ""
                let note = (name == "footnoteReference" ? context.footnotes[id] : context.endnotes[id]) ?? ""
                var mark = run
                mark.text = ""
                mark.note = note
                runs.append(mark)
            case (aNS, "blip"):
                if let id = attributes["r:embed"] ?? attributes.first(where: { $0.key.hasSuffix(":embed") })?.value { addImage(relationship: id) }
            case (vNS, "imagedata"):
                if let id = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value { addImage(relationship: id) }
            case (wpNS, "extent"):
                if let cx = attribute(attributes, "cx").flatMap(Double.init), let cy = attribute(attributes, "cy").flatMap(Double.init) {
                    pendingExtent = (cx / 12_700, cy / 12_700)
                }
            case (w, "tbl"):
                flushParagraphIfNeeded()
                tables.append(TableState())
            case (w, "tr"):
                tables[tables.count - 1].row = []
                tables[tables.count - 1].rowIsHeader = false
                tables[tables.count - 1].gridColumn = 0
                tables[tables.count - 1].currentRowGrid = []
            case (w, "tblHeader"): if !tables.isEmpty { tables[tables.count - 1].rowIsHeader = DOCXReader.toggle(value) }
            case (w, "tc"):
                if !tables.isEmpty { tables[tables.count - 1].cellSpan = 1; tables[tables.count - 1].cellMerge = nil }
                containers.append([])
            case (w, "gridSpan"): if !tables.isEmpty { tables[tables.count - 1].cellSpan = max(1, value.flatMap(Int.init) ?? 1) }
            case (w, "vMerge"): if !tables.isEmpty { tables[tables.count - 1].cellMerge = value == "restart" ? "restart" : "continue" }
            case (w, "pgSz") where page == nil:
                if let wTw = attribute(attributes, "w").flatMap(Double.init), let hTw = attribute(attributes, "h").flatMap(Double.init) {
                    page = .init(width: wTw / 20, height: hTw / 20)
                }
            case (w, "pgMar"):
                if var current = page, current.top == 72, current.left == 72 {
                    current.top = (attribute(attributes, "top").flatMap(Double.init) ?? 1440) / 20
                    current.right = (attribute(attributes, "right").flatMap(Double.init) ?? 1440) / 20
                    current.bottom = (attribute(attributes, "bottom").flatMap(Double.init) ?? 1440) / 20
                    current.left = (attribute(attributes, "left").flatMap(Double.init) ?? 1440) / 20
                    page = current
                }
            default:
                break
            }
        }

        private var pendingExtent: (Double, Double)?
        private var inParagraphProps = false
        private struct SavedParagraph {
            var inParagraph: Bool, style: String?, alignment: StructuredDocument.Alignment, rtl: Bool
            var numId: String?, level: Int, runs: [StructuredDocument.Run], run: StructuredDocument.Run
        }
        private var saved: [SavedParagraph] = []
        private var afterParagraph: [StructuredDocument.Block] = []

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            if inInstruction { fieldInstruction += string; return }
            if inText { append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if skipDepth > 0 { skipDepth -= 1; return }
            switch (namespaceURI, name) {
            case (w, "t"): inText = false
            case (w, "instrText"): inInstruction = false
            case (w, "rPr"): inRunProps = false
            case (w, "pPr"): inParagraphProps = false
            case (w, "txbxContent"):
                let boxed = containers.popLast() ?? []
                if let state = saved.popLast() {
                    inParagraph = state.inParagraph; paragraphStyle = state.style; alignment = state.alignment; rtl = state.rtl
                    numId = state.numId; level = state.level; runs = state.runs; run = state.run
                }
                afterParagraph += boxed
            case (w, "r"):
                if !run.text.isEmpty { runs.append(run) }
                run = StructuredDocument.Run("")
            case (w, "del"), (w, "moveFrom"): deleted = max(0, deleted - 1)
            case (w, "hyperlink"): _ = linkStack.popLast()
            case (w, "fldSimple"): fieldLink = nil
            case (w, "p"):
                flushParagraph()
                inParagraph = false
                containers[containers.count - 1] += afterParagraph
                afterParagraph = []
            case (w, "tc"):
                guard !tables.isEmpty else { break }
                let blocks = containers.popLast() ?? []
                var state = tables[tables.count - 1]
                let rowIndex = state.rows.count
                if state.cellMerge == "continue", let start = state.mergeStarts[state.gridColumn] {
                    if start.row < state.rows.count, start.column < state.rows[start.row].count {
                        state.rows[start.row][start.column].rowSpan += 1
                    } else if start.row == rowIndex {
                        // not possible: a continuation on the restart row
                    }
                } else {
                    let cell = StructuredDocument.Cell(blocks: blocks.isEmpty ? [.paragraph(.init(runs: []))] : blocks, rowSpan: 1, columnSpan: state.cellSpan)
                    if state.cellMerge == "restart" { state.mergeStarts[state.gridColumn] = (rowIndex, state.row.count) } else { state.mergeStarts[state.gridColumn] = nil }
                    state.row.append(cell)
                }
                state.gridColumn += state.cellSpan
                tables[tables.count - 1] = state
            case (w, "tr"):
                guard !tables.isEmpty else { break }
                var state = tables[tables.count - 1]
                if state.rowIsHeader && state.rows.count == state.headerRows { state.headerRows += 1 }
                state.rows.append(state.row)
                state.row = []
                tables[tables.count - 1] = state
            case (w, "tbl"):
                guard let state = tables.popLast() else { break }
                var headerRows = state.headerRows
                if headerRows == 0, let first = state.rows.first, !first.isEmpty,
                   first.allSatisfy({ cell in cell.blocks.allSatisfy { block in
                       if case .paragraph(let p) = block { return !p.runs.isEmpty && p.runs.allSatisfy(\.bold) }
                       return false
                   } }) {
                    headerRows = 1
                }
                containers[containers.count - 1].append(.table(.init(rows: state.rows, headerRows: headerRows)))
            default:
                break
            }
        }

        private func append(_ text: String) {
            run.text += text
        }

        private func addImage(relationship id: String) {
            guard let rel = context.relationships[id], !rel.external, let data = try? context.zip.read(rel.target), !data.isEmpty else { return }
            if !run.text.isEmpty { runs.append(run); let keep = run; run = StructuredDocument.Run(""); run.link = keep.link }
            flushParagraph(keepState: true)
            let size = pendingExtent
            pendingExtent = nil
            containers[containers.count - 1].append(.image(.init(data: data, width: size?.0, height: size?.1)))
        }

        private func breakParagraph(with block: StructuredDocument.Block) {
            if !run.text.isEmpty { runs.append(run); run.text = "" }
            flushParagraph(keepState: true)
            containers[containers.count - 1].append(block)
        }

        private func flushParagraphIfNeeded() {
            if inParagraph && !runs.isEmpty { flushParagraph(keepState: true) }
        }

        private func flushParagraph(keepState: Bool = false) {
            let merged = StructuredDocument.merge(runs)
            runs = []
            let text = merged.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || merged.contains(where: { $0.note != nil }) else { return }
            if let heading = headingLevel(paragraphStyle) {
                containers[containers.count - 1].append(.heading(level: heading, runs: merged))
                return
            }
            let name = styleName(paragraphStyle)
            if name.contains("code") || name.contains("preformatted") || name.contains("source") {
                containers[containers.count - 1].append(.code(text, language: nil))
                return
            }
            var paragraph = StructuredDocument.Paragraph(runs: merged, alignment: alignment)
            paragraph.rtl = rtl
            if let numId, numId != "0", let levels = context.numberingFormats[numId] {
                let info = levels[level] ?? ("decimal", 1)
                paragraph.list = ["bullet", "none"].contains(info.format) ? .unordered : .ordered
                paragraph.listLevel = level
                let key = "\(numId):\(level)"
                if lastListKey != key && paragraph.list == .ordered && level == 0 { paragraph.listStart = info.start }
                lastListKey = key
            } else {
                lastListKey = nil
            }
            if name.contains("quote") || name == "block text" {
                containers[containers.count - 1].append(.quote([.paragraph(paragraph)]))
            } else {
                containers[containers.count - 1].append(.paragraph(paragraph))
            }
        }

        /// Consecutive code paragraphs become one code block.
        private func mergeCode(_ blocks: [StructuredDocument.Block]) -> [StructuredDocument.Block] {
            var out: [StructuredDocument.Block] = []
            for block in blocks {
                if case .code(let text, let language) = block, case .code(let previous, _)? = out.last {
                    out[out.count - 1] = .code(previous + "\n" + text, language: language)
                } else if case .quote(let inner) = block, case .quote(let previous)? = out.last {
                    out[out.count - 1] = .quote(previous + inner)
                } else {
                    out.append(block)
                }
            }
            return out
        }
    }
}

/// docProps/core.xml metadata.
enum CoreProperties {
    static func parse(_ data: Data) -> (title: String?, creator: String?, language: String?) {
        final class Delegate: NSObject, XMLParserDelegate {
            var values: [String: String] = [:]
            var current: String?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                current = name
                values[name] = values[name] ?? ""
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { if let current { values[current, default: ""] += string } }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { current = nil }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        func clean(_ key: String) -> String? {
            let value = delegate.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        return (clean("title"), clean("creator"), clean("language"))
    }
}
