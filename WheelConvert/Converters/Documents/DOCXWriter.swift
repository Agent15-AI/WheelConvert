import Foundation

/// Writes Word (.docx) files from a StructuredDocument.
struct DOCXWriter {
    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private var media: [(name: String, data: Data)] = []
    private var footnotes: [String] = []
    private var numbering: [(numId: Int, abstract: Int, start: Int)] = []
    private var drawingID = 0
    private var contentWidth: Double = 468
    private let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func defaultPage() -> StructuredDocument.PageSetup {
        let region = Locale.current.region?.identifier ?? "US"
        let letter = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR"].contains(region)
        return letter ? .init(width: 612, height: 792) : .init(width: 595.28, height: 841.89)
    }

    mutating func write(_ doc: StructuredDocument) throws -> Data {
        let page = doc.page ?? Self.defaultPage()
        contentWidth = max(72, page.width - page.left - page.right)
        var body = blocks(doc.blocks)
        body += sectionProperties(page)
        return try package(body: body, title: doc.inferredTitle, author: doc.author, language: doc.language)
    }

    /// One page image per section, each sized like its source page with no margins.
    mutating func writePageImages(_ pages: [(data: Data, width: Double, height: Double)], title: String?) throws -> Data {
        var body = ""
        for (index, page) in pages.enumerated() {
            let id = addImage(page.data)
            let inline = drawing(relationship: id, width: page.width, height: page.height, name: "Page \(index + 1)")
            let section = StructuredDocument.PageSetup(width: page.width, height: page.height, top: 0, right: 0, bottom: 0, left: 0)
            let last = index == pages.count - 1
            body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>"
            if !last { body += sectionProperties(section, inParagraph: true) }
            body += "</w:pPr><w:r>\(inline)</w:r></w:p>"
            if last { body += sectionProperties(section) }
        }
        return try package(body: body, title: title, author: nil, language: nil)
    }

    // MARK: Body

    private mutating func blocks(_ blocks: [StructuredDocument.Block]) -> String {
        var xml = ""
        var listNum: [StructuredDocument.ListKind: Int] = [:]
        var previousList: StructuredDocument.ListKind?
        for block in blocks {
            if case .paragraph(let p) = block, let kind = p.list {
                // A new run of list items starts its own numbering.
                if previousList != kind || listNum[kind] == nil || (kind == .ordered && p.listLevel == 0 && p.listStart != nil && previousList == nil) {
                    listNum[kind] = newNumbering(kind, start: p.listStart ?? 1)
                }
                previousList = kind
                xml += paragraph(p, numId: listNum[kind])
                continue
            }
            previousList = nil
            listNum = [:]
            xml += self.block(block)
        }
        return xml
    }

    private mutating func block(_ block: StructuredDocument.Block) -> String {
        switch block {
        case .heading(let level, let runs):
            let n = min(max(level, 1), 6)
            return "<w:p><w:pPr><w:pStyle w:val=\"Heading\(n)\"/></w:pPr>\(self.runs(runs))</w:p>"
        case .paragraph(let p):
            return paragraph(p, numId: nil)
        case .quote(let inner):
            return inner.map { b -> String in
                if case .paragraph(let p) = b {
                    return "<w:p><w:pPr><w:pStyle w:val=\"Quote\"/>\(alignment(p.alignment))</w:pPr>\(runs(p.runs))</w:p>"
                }
                return self.block(b)
            }.joined()
        case .code(let text, _):
            return text.components(separatedBy: "\n").map {
                "<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(escape($0))</w:t></w:r></w:p>"
            }.joined()
        case .table(let table):
            return self.table(table)
        case .image(let image):
            // An image Word can't display would make it reject the whole file; keep its description instead.
            guard let data = ImageSniffer.raster(image.data) else {
                return image.alt.map { paragraph(.init(runs: [.init("[\($0)]")], alignment: .center), numId: nil) } ?? ""
            }
            let id = addImage(data)
            var (w, h) = displaySize(image, data: data)
            if w > contentWidth { h *= contentWidth / w; w = contentWidth }
            return "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r>\(drawing(relationship: id, width: w, height: h, name: image.alt ?? "Image"))</w:r></w:p>"
        case .rule:
            return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr></w:pPr></w:p>"
        case .pageBreak:
            return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
        }
    }

    private mutating func paragraph(_ p: StructuredDocument.Paragraph, numId: Int?) -> String {
        var props = ""
        if let numId {
            props += "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(p.listLevel, 8))\"/><w:numId w:val=\"\(numId)\"/></w:numPr>"
        }
        if p.rtl { props += "<w:bidi/>" }
        props += alignment(p.alignment)
        return "<w:p>\(props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>")\(runs(p.runs))</w:p>"
    }

    private func alignment(_ a: StructuredDocument.Alignment) -> String {
        switch a {
        case .left: ""
        case .center: "<w:jc w:val=\"center\"/>"
        case .right: "<w:jc w:val=\"right\"/>"
        case .justified: "<w:jc w:val=\"both\"/>"
        }
    }

    private mutating func runs(_ runs: [StructuredDocument.Run]) -> String {
        var xml = ""
        for run in runs {
            var props = ""
            if run.link != nil { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if run.code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>" }
            if run.bold { props += "<w:b/><w:bCs/>" }
            if run.italic { props += "<w:i/><w:iCs/>" }
            if run.strike { props += "<w:strike/>" }
            if let color = run.color, color.count == 6, color.allSatisfy(\.isHexDigit) { props += "<w:color w:val=\"\(color.uppercased())\"/>" }
            if run.underline { props += "<w:u w:val=\"single\"/>" }
            if run.superscript { props += "<w:vertAlign w:val=\"superscript\"/>" } else if run.subscripted { props += "<w:vertAlign w:val=\"subscript\"/>" }
            var content = ""
            let lines = run.text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if i > 0 { content += "<w:br/>" }
                let pieces = line.components(separatedBy: "\t")
                for (j, piece) in pieces.enumerated() {
                    if j > 0 { content += "<w:tab/>" }
                    if !piece.isEmpty { content += "<w:t xml:space=\"preserve\">\(escape(piece))</w:t>" }
                }
            }
            var element = content.isEmpty ? "" : "<w:r>\(props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")\(content)</w:r>"
            if let link = run.link, let safe = HTMLWriter.safeLink(link), !safe.hasPrefix("#"), !element.isEmpty {
                let id = addRelationship(type: "hyperlink", target: safe, external: true)
                element = "<w:hyperlink r:id=\"\(id)\">\(element)</w:hyperlink>"
            }
            xml += element
            if let note = run.note {
                footnotes.append(note)
                xml += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(footnotes.count)\"/></w:r>"
            }
        }
        return xml
    }

    enum Slot {
        case cell(StructuredDocument.Cell)
        case continuation(StructuredDocument.Cell)
        case covered   // inside a column span
        case empty
    }

    /// Lays cells onto a grid so row spans become vertical merges and every grid column is filled.
    static func layout(_ table: StructuredDocument.Table) -> [[Slot]] {
        var grid: [[Slot]] = []
        var carry: [Int: (remaining: Int, cell: StructuredDocument.Cell)] = [:]
        for row in table.rows {
            var line: [Slot] = []
            var cells = row[...]
            var col = 0
            while !cells.isEmpty || carry.keys.contains(where: { $0 >= col }) {
                if let pending = carry[col] {
                    let span = max(1, pending.cell.columnSpan)
                    line.append(.continuation(pending.cell))
                    line += Array(repeating: .covered, count: span - 1)
                    carry[col] = pending.remaining > 1 ? (pending.remaining - 1, pending.cell) : nil
                    col += span
                } else if let cell = cells.popFirst() {
                    let span = max(1, cell.columnSpan)
                    line.append(.cell(cell))
                    line += Array(repeating: .covered, count: span - 1)
                    if cell.rowSpan > 1 { carry[col] = (cell.rowSpan - 1, cell) }
                    col += span
                } else {
                    line.append(.empty)
                    col += 1
                }
            }
            grid.append(line)
        }
        let columns = grid.map(\.count).max() ?? 0
        return grid.map { $0 + Array(repeating: .empty, count: columns - $0.count) }
    }

    private mutating func table(_ table: StructuredDocument.Table) -> String {
        let grid = Self.layout(table)
        let columns = grid.first?.count ?? 0
        guard columns > 0 else { return "" }
        let width = Int(contentWidth * 20)
        let colWidth = width / columns
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(width)\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/>"
        xml += "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"AAAAAA\"/>" }.joined() + "</w:tblBorders>"
        xml += "<w:tblCellMar><w:top w:w=\"60\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"60\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"
        xml += "<w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(colWidth)\"/>", count: columns) + "</w:tblGrid>"
        let saved = contentWidth
        for (r, line) in grid.enumerated() {
            let header = r < table.headerRows
            xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for slot in line {
                let cell: StructuredDocument.Cell?
                let merge: String
                switch slot {
                case .covered: continue
                case .empty: cell = nil; merge = ""
                case .cell(let c): cell = c; merge = c.rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : ""
                case .continuation: cell = nil; merge = "<w:vMerge/>"
                }
                let span: Int
                if case .continuation(let c) = slot { span = max(1, c.columnSpan) } else { span = max(1, cell?.columnSpan ?? 1) }
                var tcPr = "<w:tcW w:w=\"\(colWidth * span)\" w:type=\"dxa\"/>"
                if span > 1 { tcPr += "<w:gridSpan w:val=\"\(span)\"/>" }
                tcPr += merge
                if header { tcPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EDEDED\"/>" }
                contentWidth = max(36, Double(colWidth * span) / 20 - 10)
                var content = cell.map { blocks(header ? $0.blocks.map(Self.bolded) : $0.blocks) } ?? ""
                if !content.contains("<w:p>") && !content.contains("<w:p ") { content += "<w:p/>" }
                xml += "<w:tc><w:tcPr>\(tcPr)</w:tcPr>\(content)</w:tc>"
            }
            xml += "</w:tr>"
        }
        contentWidth = saved
        return xml + "</w:tbl><w:p/>"
    }

    private static func bolded(_ block: StructuredDocument.Block) -> StructuredDocument.Block {
        guard case .paragraph(var p) = block else { return block }
        p.runs = p.runs.map { var run = $0; run.bold = true; return run }
        return .paragraph(p)
    }

    // MARK: Images

    private mutating func addImage(_ data: Data) -> String {
        let name = "image\(media.count + 1).\(ImageSniffer.fileExtension(data))"
        media.append((name, data))
        return addRelationship(type: "image", target: "media/\(name)", external: false)
    }

    private func displaySize(_ image: StructuredDocument.Image, data: Data) -> (Double, Double) {
        if let w = image.width, let h = image.height, w > 0, h > 0 { return (w, h) }
        if let px = ImageSniffer.pixelSize(data) {
            let w = Double(px.width) * 0.75, h = Double(px.height) * 0.75
            if let w0 = image.width, w0 > 0 { return (w0, w0 * h / w) }
            return (w, h)
        }
        return (200, 150)
    }

    private mutating func drawing(relationship: String, width: Double, height: Double, name: String) -> String {
        drawingID += 1
        let cx = Int(width * 12_700), cy = Int(height * 12_700)
        let title = escape(name)
        return """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(drawingID)" name="Image \(drawingID)" descr="\(title)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="Image \(drawingID)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
    }

    // MARK: Package

    private mutating func addRelationship(type: String, target: String, external: Bool) -> String {
        let id = "rId\(relationships.count + 10)"
        relationships.append((id, type, target, external))
        return id
    }

    private mutating func newNumbering(_ kind: StructuredDocument.ListKind, start: Int) -> Int {
        let numId = numbering.count + 1
        numbering.append((numId, kind == .ordered ? 1 : 0, start))
        return numId
    }

    private func sectionProperties(_ page: StructuredDocument.PageSetup, inParagraph: Bool = false) -> String {
        let w = Int((page.width * 20).rounded()), h = Int((page.height * 20).rounded())
        let orient = page.width > page.height ? " w:orient=\"landscape\"" : ""
        return "<w:sectPr>\(inParagraph ? "<w:type w:val=\"nextPage\"/>" : "")<w:pgSz w:w=\"\(w)\" w:h=\"\(h)\"\(orient)/>"
            + "<w:pgMar w:top=\"\(Int(page.top * 20))\" w:right=\"\(Int(page.right * 20))\" w:bottom=\"\(Int(page.bottom * 20))\" w:left=\"\(Int(page.left * 20))\" w:header=\"\(Int(min(page.top, 36) * 20))\" w:footer=\"\(Int(min(page.bottom, 36) * 20))\" w:gutter=\"0\"/></w:sectPr>"
    }

    private func package(body: String, title: String?, author: String?, language: String?) throws -> Data {
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"\(r)\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let document = header + "<w:document \(ns)><w:body>\(body)</w:body></w:document>"

        var rels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        rels += "<Relationship Id=\"rId1\" Type=\"\(r)/styles\" Target=\"styles.xml\"/>"
        rels += "<Relationship Id=\"rId2\" Type=\"\(r)/settings\" Target=\"settings.xml\"/>"
        rels += "<Relationship Id=\"rId3\" Type=\"\(r)/numbering\" Target=\"numbering.xml\"/>"
        if !footnotes.isEmpty { rels += "<Relationship Id=\"rId4\" Type=\"\(r)/footnotes\" Target=\"footnotes.xml\"/>" }
        for rel in relationships {
            rels += "<Relationship Id=\"\(rel.id)\" Type=\"\(r)/\(rel.type)\" Target=\"\(escape(rel.target))\"\(rel.external ? " TargetMode=\"External\"" : "")/>"
        }
        rels += "</Relationships>"

        var types = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        types += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for (ext, mime) in [("png", "image/png"), ("jpg", "image/jpeg"), ("gif", "image/gif")] { types += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>" }
        let wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        types += "<Override PartName=\"/word/document.xml\" ContentType=\"\(wml).document.main+xml\"/>"
        types += "<Override PartName=\"/word/styles.xml\" ContentType=\"\(wml).styles+xml\"/>"
        types += "<Override PartName=\"/word/settings.xml\" ContentType=\"\(wml).settings+xml\"/>"
        types += "<Override PartName=\"/word/numbering.xml\" ContentType=\"\(wml).numbering+xml\"/>"
        if !footnotes.isEmpty { types += "<Override PartName=\"/word/footnotes.xml\" ContentType=\"\(wml).footnotes+xml\"/>" }
        types += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"

        let rootRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(r)/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>"
        let core = header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + (title.map { "<dc:title>\(escape($0))</dc:title>" } ?? "") + (author.map { "<dc:creator>\(escape($0))</dc:creator>" } ?? "")
            + (language.map { "<dc:language>\(escape($0))</dc:language>" } ?? "")
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(ISO8601DateFormatter().string(from: Date()))</dcterms:created></cp:coreProperties>"

        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", Data(types.utf8))
        try zip.add("_rels/.rels", Data(rootRels.utf8))
        try zip.add("docProps/core.xml", Data(core.utf8))
        try zip.add("word/document.xml", Data(document.utf8))
        try zip.add("word/_rels/document.xml.rels", Data(rels.utf8))
        try zip.add("word/styles.xml", Data(styles(header: header, language: language).utf8))
        try zip.add("word/settings.xml", Data((header + "<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" + (footnotes.isEmpty ? "" : "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>") + "<w:defaultTabStop w:val=\"720\"/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>").utf8))
        try zip.add("word/numbering.xml", Data(numberingXML(header: header).utf8))
        if !footnotes.isEmpty { try zip.add("word/footnotes.xml", Data(footnotesXML(header: header).utf8)) }
        for item in media { try zip.add("word/media/\(item.name)", item.data, compress: false) }
        return zip.finish()
    }

    private func styles(header: String, language: String?) -> String {
        let lang = escape(language ?? Locale.current.identifier(.bcp47))
        var xml = header + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        xml += "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"\(lang)\"/></w:rPr></w:rPrDefault>"
        xml += "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
        xml += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        let sizes = [40, 32, 28, 24, 22, 22]
        for level in 1...6 {
            xml += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
            xml += "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(level <= 2 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
            xml += "<w:rPr><w:b/><w:bCs/>\(level >= 5 ? "<w:i/>" : "")<w:sz w:val=\"\(sizes[level - 1])\"/><w:szCs w:val=\"\(sizes[level - 1])\"/></w:rPr></w:style>"
        }
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"240\"/></w:pPr><w:rPr><w:sz w:val=\"56\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:ind w:left=\"720\" w:right=\"720\"/></w:pPr><w:rPr><w:i/><w:color w:val=\"404040\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F3F5\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/><w:sz w:val=\"19\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"60\"/><w:contextualSpacing/></w:pPr></w:style>"
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"FootnoteText\"><w:name w:val=\"footnote text\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:sz w:val=\"20\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"character\" w:styleId=\"FootnoteReference\"><w:name w:val=\"footnote reference\"/><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:tblPr><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/></w:tblBorders></w:tblPr></w:style>"
        return xml + "</w:styles>"
    }

    private func numberingXML(header: String) -> String {
        var xml = header + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        let bullets = ["•", "◦", "▪"]
        xml += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        for level in 0..<9 {
            xml += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullets[level % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + level * 360)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        xml += "</w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        for level in 0..<9 {
            xml += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(formats[level % 3])\"/><w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + level * 360)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        xml += "</w:abstractNum>"
        for entry in numbering {
            xml += "<w:num w:numId=\"\(entry.numId)\"><w:abstractNumId w:val=\"\(entry.abstract)\"/>"
            if entry.abstract == 1 { xml += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"\(entry.start)\"/></w:lvlOverride>" }
            xml += "</w:num>"
        }
        return xml + "</w:numbering>"
    }

    private func footnotesXML(header: String) -> String {
        var xml = header + "<w:footnotes xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"\(r)\">"
        xml += "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote>"
        xml += "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
        for (i, note) in footnotes.enumerated() {
            xml += "<w:footnote w:id=\"\(i + 1)\"><w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space=\"preserve\"> \(escape(note))</w:t></w:r></w:p></w:footnote>"
        }
        return xml + "</w:footnotes>"
    }

    private func escape(_ text: String) -> String { HTMLWriter.escape(text) }
}
