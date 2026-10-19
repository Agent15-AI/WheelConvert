import AppKit
import PDFKit
import Vision

/// Rebuilds reflowable structure (headings, paragraphs, lists, illustrations) from a PDF's
/// positioned text. Scanned pages are read with on-device OCR.
enum PDFStructureReader {
    struct Line {
        var text: String
        var bounds: CGRect
        var fontSize: CGFloat
        var bold: Bool
        var italic: Bool
        var runs: [StructuredDocument.Run]
    }

    enum Element {
        case line(Line)
        case image(Data, CGRect)
        var top: CGFloat {
            switch self {
            case .line(let l): l.bounds.maxY
            case .image(_, let r): r.maxY
            }
        }
        var minX: CGFloat {
            switch self {
            case .line(let l): l.bounds.minX
            case .image(_, let r): r.minX
            }
        }
    }

    static func read(_ document: PDFDocument, progress: (Double) -> Void) throws -> StructuredDocument {
        guard document.pageCount > 0 else { throw WheelError("This PDF has no pages.") }
        guard document.allowsCopying else { throw WheelError("This PDF does not allow copying its content.") }
        var pages: [[Element]] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var elements = lines(on: page).map(Element.line)
            if elements.map({ if case .line(let l) = $0 { l.text } else { "" } }).joined().trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
                elements = (try? ocrLines(page).map(Element.line)) ?? elements
            }
            elements += images(on: page).map { Element.image($0.0, $0.1) }
            // A page of pure artwork (a photo, a drawing without text) is kept as one picture.
            if elements.isEmpty, let picture = pagePicture(page) { elements = [.image(picture, page.bounds(for: .cropBox))] }
            pages.append(order(elements, pageBounds: page.bounds(for: .cropBox)))
            progress(0.8 * Double(index + 1) / Double(document.pageCount))
        }
        removeRunningText(&pages, document: document)
        var doc = StructuredDocument()
        doc.blocks = assemble(pages)
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { doc.title = title }
        if let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { doc.author = author }
        if let first = document.page(at: 0) {
            let box = first.bounds(for: .cropBox)
            let rotated = first.rotation % 180 != 0
            doc.page = .init(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        }
        guard !doc.blocks.isEmpty else { throw WheelError("The PDF contains no text or page artwork that can be exported.") }
        progress(1)
        return doc
    }

    // MARK: Text lines

    static func lines(on page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        var result: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            guard let attributed = lineSelection.attributedString, attributed.length > 0 else { continue }
            let text = attributed.string.trimmingCharacters(in: .newlines)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let bounds = lineSelection.bounds(for: page)
            var runs: [StructuredDocument.Run] = []
            var sizes: [CGFloat: Int] = [:]
            var boldCount = 0, italicCount = 0, total = 0
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                let piece = (attributed.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: "")
                guard !piece.isEmpty else { return }
                var run = StructuredDocument.Run(piece)
                if let font = attributes[.font] as? NSFont {
                    let name = font.fontName.lowercased()
                    let traits = font.fontDescriptor.symbolicTraits
                    run.bold = traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")
                    run.italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
                    run.code = traits.contains(.monoSpace) || name.contains("mono") || name.contains("courier") || name.contains("menlo")
                    sizes[font.pointSize.rounded(), default: 0] += range.length
                }
                if let link = attributes[.link] { run.link = (link as? URL)?.absoluteString ?? link as? String }
                let letters = piece.filter { !$0.isWhitespace }.count
                total += letters
                if run.bold { boldCount += letters }
                if run.italic { italicCount += letters }
                runs.append(run)
            }
            let size = sizes.max { $0.value < $1.value }?.key ?? 11
            result.append(Line(text: text, bounds: bounds, fontSize: size, bold: total > 0 && boldCount * 10 >= total * 8,
                               italic: total > 0 && italicCount * 10 >= total * 8, runs: StructuredDocument.merge(runs)))
        }
        return result
    }

    static func ocrLines(_ page: PDFPage) throws -> [Line] {
        let box = page.bounds(for: .cropBox)
        let scale: CGFloat = 2.5
        guard let image = render(page, scale: scale) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw WheelError("Text recognition could not read a scanned PDF page: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            let rect = CGRect(x: box.minX + b.minX * box.width, y: box.minY + b.minY * box.height, width: b.width * box.width, height: b.height * box.height)
            return Line(text: candidate.string, bounds: rect, fontSize: max(6, (rect.height * 0.8).rounded()), bold: false, italic: false, runs: [.init(candidate.string)])
        }
    }

    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let width = Int(((rotated ? box.height : box.width) * scale).rounded()), height = Int(((rotated ? box.width : box.height) * scale).rounded())
        guard width > 0, height > 0, width < 30_000, height < 30_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Illustrations

    /// The whole page as a JPEG, at most 4000 pixels on its long side.
    static func pagePicture(_ page: PDFPage) -> Data? {
        let box = page.bounds(for: .cropBox)
        guard max(box.width, box.height) > 0, let image = render(page, scale: min(2, 4000 / max(box.width, box.height))) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Placed raster images (and form XObjects containing them), cropped from the rendered page.
    static func images(on page: PDFPage) -> [(Data, CGRect)] {
        guard let cgPage = page.pageRef else { return [] }
        let rects = ImagePlacementScanner.placements(on: cgPage)
        let box = page.bounds(for: .cropBox)
        // Explicit types keep older Swift compilers from timing out on these closures.
        func area(_ r: CGRect) -> CGFloat { r.width * r.height }
        let pageArea: CGFloat = area(box)
        let candidates: [CGRect] = rects.compactMap { (r: CGRect) -> CGRect? in
            let clipped = r.intersection(box)
            guard !clipped.isNull, clipped.width >= 36, clipped.height >= 36, area(clipped) < pageArea * 0.92 else { return nil }
            return clipped
        }
        guard !candidates.isEmpty, page.rotation % 360 == 0, let rendered = render(page, scale: 2) else { return [] }
        var seen: [CGRect] = []
        var output: [(Data, CGRect)] = []
        for rect in candidates.sorted(by: { (a: CGRect, b: CGRect) -> Bool in area(a) > area(b) }) {
            let overlapsSeen = seen.contains { (s: CGRect) -> Bool in s.contains(rect) || area(s.intersection(rect)) > area(rect) * 0.6 }
            if overlapsSeen { continue }
            seen.append(rect)
            let crop = CGRect(x: (rect.minX - box.minX) * 2, y: (box.maxY - rect.maxY) * 2, width: rect.width * 2, height: rect.height * 2).integral
            guard let piece = rendered.cropping(to: crop) else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, piece, nil)
            if CGImageDestinationFinalize(destination) { output.append((data as Data, rect)) }
        }
        return output
    }

    // MARK: Reading order

    /// Single or double column reading order, top to bottom.
    static func order(_ elements: [Element], pageBounds: CGRect) -> [Element] {
        let mid = pageBounds.midX
        let textLines = elements.compactMap { e -> Line? in if case .line(let l) = e { return l } else { return nil } }
        let narrow = textLines.filter { $0.bounds.width < pageBounds.width * 0.48 }
        let left = narrow.filter { $0.bounds.maxX < mid + 4 }.count, right = narrow.filter { $0.bounds.minX > mid - 4 }.count
        let twoColumns = textLines.count > 12 && left > textLines.count / 4 && right > textLines.count / 4
        func byTop(_ a: Element, _ b: Element) -> Bool {
            if abs(a.top - b.top) > 2 { return a.top > b.top }
            return a.minX < b.minX
        }
        guard twoColumns else { return elements.sorted(by: byTop) }
        // Full-width elements (titles, wide figures) split the page into bands read column by column.
        func isWide(_ e: Element) -> Bool {
            switch e {
            case .line(let l): l.bounds.minX < mid - 10 && l.bounds.maxX > mid + 10
            case .image(_, let r): r.minX < mid - 10 && r.maxX > mid + 10
            }
        }
        let sorted = elements.sorted(by: byTop)
        var output: [Element] = []
        var band: [Element] = []
        func flushBand() {
            output += band.filter { $0.minX < mid }.sorted(by: byTop) + band.filter { $0.minX >= mid }.sorted(by: byTop)
            band = []
        }
        for element in sorted {
            if isWide(element) { flushBand(); output.append(element) } else { band.append(element) }
        }
        flushBand()
        return output
    }

    /// Drops page numbers and headers/footers that repeat across pages.
    static func removeRunningText(_ pages: inout [[Element]], document: PDFDocument) {
        guard pages.count > 1 else {
            pages = pages.map { $0.filter { if case .line(let l) = $0 { return !isPageNumber(l.text) } else { return true } } }
            return
        }
        func key(_ text: String) -> String { text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var counts: [String: Int] = [:]
        for (index, elements) in pages.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            var seen = Set<String>()
            for case .line(let line) in elements where line.bounds.minY > box.maxY - box.height * 0.08 || line.bounds.maxY < box.minY + box.height * 0.08 {
                if seen.insert(key(line.text)).inserted { counts[key(line.text), default: 0] += 1 }
            }
        }
        let repeated = Set(counts.filter { $0.value >= max(2, pages.count / 2) }.keys)
        for index in pages.indices {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            pages[index] = pages[index].filter { element in
                guard case .line(let line) = element else { return true }
                let marginal = line.bounds.minY > box.maxY - box.height * 0.08 || line.bounds.maxY < box.minY + box.height * 0.08
                return !(marginal && (repeated.contains(key(line.text)) || isPageNumber(line.text)))
            }
        }
    }

    static func isPageNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[\s|–—-]*(page\s+)?([0-9]+|[ivxlcdm]+)(\s*(of|/)\s*[0-9]+)?[\s|–—-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Paragraphs

    static func assemble(_ pages: [[Element]]) -> [StructuredDocument.Block] {
        let lines = pages.flatMap { $0 }.compactMap { e -> Line? in if case .line(let l) = e { return l } else { return nil } }
        var sizes: [CGFloat: Int] = [:]
        for line in lines { sizes[line.fontSize, default: 0] += line.text.count }
        let body = sizes.max { $0.value < $1.value }?.key ?? 11
        let headingSizes = sizes.keys.filter { $0 >= body * 1.18 }.sorted(by: >)

        var blocks: [StructuredDocument.Block] = []
        var current: (lines: [Line], heading: Int?, list: StructuredDocument.ListKind?)?
        func flush() {
            guard let paragraph = current else { return }
            current = nil
            var runs: [StructuredDocument.Run] = []
            for (i, line) in paragraph.lines.enumerated() {
                var lineRuns = line.runs
                if i > 0, var last = runs.last {
                    if last.text.hasSuffix("-"), let next = line.text.first, next.isLowercase {
                        last.text.removeLast()
                        runs[runs.count - 1] = last
                    } else if !last.text.hasSuffix(" ") {
                        runs.append(.init(" "))
                    }
                }
                if i == 0, paragraph.list != nil, var first = lineRuns.first {
                    if let marker = first.text.range(of: #"^\s*([•●▪◦–\-*]|\(?\d{1,3}[.)]|[a-z][.)])\s+"#, options: .regularExpression) {
                        first.text.removeSubrange(marker)
                        lineRuns[0] = first
                    }
                }
                runs += lineRuns
            }
            let merged = StructuredDocument.merge(runs.map { var r = $0; r.text = r.text.replacingOccurrences(of: "\u{00AD}", with: ""); return r })
            if let level = paragraph.heading {
                blocks.append(.heading(level: level, runs: merged.map { var r = $0; r.bold = false; return r }))
            } else {
                var p = StructuredDocument.Paragraph(runs: merged)
                p.list = paragraph.list
                blocks.append(.paragraph(p))
            }
        }

        for (pageIndex, elements) in pages.enumerated() {
            for element in elements {
                switch element {
                case .image(let data, let rect):
                    flush()
                    blocks.append(.image(.init(data: data, width: rect.width, height: rect.height, alt: "PDF illustration")))
                case .line(let line):
                    let text = line.text.trimmingCharacters(in: .whitespaces)
                    var heading: Int?
                    if text.count < 140, !text.hasSuffix("."), !text.hasSuffix(",") {
                        if let rank = headingSizes.firstIndex(of: line.fontSize) { heading = min(rank + 1, 3) }
                        else if line.bold && text.count < 90 && line.fontSize >= body * 0.98 && !text.hasSuffix(":") { heading = min(headingSizes.count + 1, 4) }
                    }
                    let isList = text.range(of: #"^([•●▪◦–\-*]|\(?\d{1,3}[.)]|[a-z][.)])\s+\S"#, options: .regularExpression) != nil
                    let listKind: StructuredDocument.ListKind? = isList ? (text.first.map { $0.isNumber || $0 == "(" || $0.isLetter } == true ? .ordered : .unordered) : nil
                    if let open = current, let last = open.lines.last {
                        let gap = last.bounds.minY - line.bounds.maxY
                        let lineHeight = max(last.bounds.height, line.bounds.height, 1)
                        let sameKind = open.heading == heading
                        let aligned = abs(line.bounds.minX - last.bounds.minX) < max(24, lineHeight * 2) || (open.list != nil && line.bounds.minX > open.lines[0].bounds.minX)
                        let similarSize = abs(line.fontSize - last.fontSize) <= max(1, last.fontSize * 0.12)
                        let continues = gap > -lineHeight && gap < lineHeight * 0.9 && aligned && similarSize && sameKind && listKind == nil
                        // A sentence that runs onto the next page keeps going.
                        let acrossPage = gap < -lineHeight && pageIndex > 0 && heading == nil && listKind == nil && open.heading == nil
                            && !(last.text.hasSuffix(".") || last.text.hasSuffix(":") || last.text.hasSuffix("?") || last.text.hasSuffix("!"))
                            && (line.text.first?.isLowercase ?? false)
                        let widest: CGFloat = open.lines.map(\.bounds.width).max() ?? 0
                        let previousEndsShort = open.heading == nil && open.list == nil && open.lines.count > 1 && last.bounds.width < widest * 0.6
                        if (continues || acrossPage) && !previousEndsShort {
                            current?.lines.append(line)
                            continue
                        }
                    }
                    flush()
                    current = ([line], heading, listKind)
                }
            }
        }
        flush()
        return blocks
    }
}

/// Finds where raster images are painted on a page by following the content stream's CTM.
private final class ImagePlacementScanner {
    var stack: [CGAffineTransform] = []
    var ctm = CGAffineTransform.identity
    var rects: [CGRect] = []
    var resources: [CGPDFDictionaryRef] = []
    var depth = 0
    var streams: [CGPDFContentStreamRef] = []

    static func placements(on page: CGPDFPage) -> [CGRect] {
        let scanner = ImagePlacementScanner()
        guard let dictionary = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        if let resources { scanner.resources.append(resources) }
        let stream = CGPDFContentStreamCreateWithPage(page)
        scanner.scan(stream)
        return scanner.rects
    }

    func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 8, let table = CGPDFOperatorTableCreate() else { return }
        depth += 1
        streams.append(stream)
        defer { depth -= 1; streams.removeLast() }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let me = Unmanaged<ImagePlacementScanner>.fromOpaque(info!).takeUnretainedValue()
            me.stack.append(me.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let me = Unmanaged<ImagePlacementScanner>.fromOpaque(info!).takeUnretainedValue()
            if let last = me.stack.popLast() { me.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let me = Unmanaged<ImagePlacementScanner>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
            me.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(me.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            let me = Unmanaged<ImagePlacementScanner>.fromOpaque(info!).takeUnretainedValue()
            me.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(me.ctm))
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let me = Unmanaged<ImagePlacementScanner>.fromOpaque(info!).takeUnretainedValue()
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePointer), let namePointer, let resources = me.resources.last else { return }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            var object: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, namePointer, &object), let object, let dict = CGPDFStreamGetDictionary(object) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            if strcmp(subtype, "Image") == 0 {
                me.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(me.ctm))
            } else if strcmp(subtype, "Form") == 0 {
                var matrix: CGPDFArrayRef?
                var m = CGAffineTransform.identity
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &v[i]) }
                    m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var formResources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dict, "Resources", &formResources)
                let saved = me.ctm
                me.ctm = m.concatenating(me.ctm)
                me.resources.append(formResources ?? resources)
                // Form XObjects are scanned as their own content streams.
                guard let parent = me.streams.last else { return }
                let formStream = CGPDFContentStreamCreateWithStream(object, formResources ?? resources, parent)
                me.scan(formStream)
                me.resources.removeLast()
                me.ctm = saved
            }
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }
}
