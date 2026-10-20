import Foundation

/// Renders SVG files with WebKit. The SVG is shown through an <img> element, where it can
/// neither run scripts nor load external resources.
enum SVGRenderer {
    @MainActor
    static func rasterize(_ url: URL) async throws -> LoadedImage { try await rasterize(read(url)) }

    @MainActor
    static func rasterize(_ data: Data) async throws -> LoadedImage {
        let (html, size) = try prepare(data)
        let longest = max(size.width, size.height)
        let scale = min(8192, max(1024, longest * 2)) / longest
        let view = try await OfflineWebView.make(width: size.width, height: size.height)
        defer { view.close() }
        try await view.loadHTML(html)
        try await view.evaluate("await document.getElementById('art').decode(); return true;")
        let image = try await view.snapshot(of: CGRect(origin: .zero, size: size), pixelWidth: size.width * scale)
        return LoadedImage(cgImage: image, metadata: nil, dpi: 72 * scale)
    }

    @MainActor
    static func pdf(_ url: URL, to destination: URL) async throws {
        let (html, size) = try prepare(read(url))
        let view = try await OfflineWebView.make(width: size.width, height: size.height)
        defer { view.close() }
        try await view.loadHTML(html)
        try await view.evaluate("await document.getElementById('art').decode(); return true;")
        try await view.pdf(of: CGRect(origin: .zero, size: size)).write(to: destination)
    }

    static func read(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? Int, bytes > 0, bytes <= 32 * 1024 * 1024 else {
            throw WheelError("The SVG file is empty or larger than 32 MB.")
        }
        return try Data(contentsOf: url)
    }

    /// Builds the host page and works out the drawing's intrinsic size in CSS pixels.
    static func prepare(_ data: Data) throws -> (String, CGSize) {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw WheelError("The SVG file is empty or larger than 32 MB.") }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.range(of: #"<!\s*(DOCTYPE|ENTITY)[^>]*\["#, options: [.regularExpression, .caseInsensitive]) != nil
            || head.range(of: #"<!ENTITY"#, options: .caseInsensitive) != nil {
            throw WheelError("Vector artwork is too large or contains entity declarations.")
        }
        var size = intrinsicSize(data) ?? CGSize(width: 300, height: 150)
        // Keep the page within WebKit's comfortable layout range.
        let longest = max(size.width, size.height)
        if longest > 8192 { size = CGSize(width: size.width * 8192 / longest, height: size.height * 8192 / longest) }
        size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent}\
        img{display:block;width:\(Int(size.width))px;height:\(Int(size.height))px}</style></head>\
        <body><img id="art" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
        return (html, size)
    }

    /// The document with its SVG images drawn as PNG, for formats whose readers only show bitmaps
    /// (Word, Pages). Each keeps the size the SVG asks for; drawings that can't be drawn stay as they were.
    @MainActor
    static func rasterizingImages(in blocks: [StructuredDocument.Block]) async -> [StructuredDocument.Block] {
        var result: [StructuredDocument.Block] = []
        for block in blocks {
            switch block {
            case .image(var image) where ImageSniffer.mime(image.data) == "image/svg+xml":
                if let drawn = try? await rasterize(image.data), let png = ImageSniffer.png(drawn.cgImage) {
                    if image.width == nil || image.height == nil, let size = intrinsicSize(image.data) {
                        // CSS pixels to points; an explicit width keeps the drawing's proportions.
                        let width = image.width ?? size.width * 0.75
                        (image.width, image.height) = (width, width * size.height / size.width)
                    }
                    image.data = png
                }
                result.append(.image(image))
            case .quote(let inner):
                result.append(.quote(await rasterizingImages(in: inner)))
            case .table(var table):
                for r in table.rows.indices {
                    for c in table.rows[r].indices { table.rows[r][c].blocks = await rasterizingImages(in: table.rows[r][c].blocks) }
                }
                result.append(.table(table))
            default:
                result.append(block)
            }
        }
        return result
    }

    /// Reads width/height (any CSS unit) or the viewBox from the root <svg> element.
    static func intrinsicSize(_ data: Data) -> CGSize? {
        let parser = XMLParser(data: data)
        let delegate = RootReader()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        guard let attributes = delegate.attributes else { return nil }
        var viewBox: CGSize?
        if let box = attributes["viewBox"] {
            let numbers = box.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 { viewBox = CGSize(width: numbers[2], height: numbers[3]) }
        }
        let width = attributes["width"].flatMap(length), height = attributes["height"].flatMap(length)
        switch (width, height, viewBox) {
        case let (w?, h?, _): return CGSize(width: w, height: h)
        case let (w?, nil, box?): return CGSize(width: w, height: w * box.height / box.width)
        case let (nil, h?, box?): return CGSize(width: h * box.width / box.height, height: h)
        case let (_, _, box?): return box
        default: return nil
        }
    }

    static func length(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4), ("em", 16), ("ex", 8)]
        if trimmed.hasSuffix("%") { return nil }
        for (unit, factor) in units where trimmed.hasSuffix(unit) {
            return Double(trimmed.dropLast(unit.count)).flatMap { $0 > 0 ? $0 * factor : nil }
        }
        return Double(trimmed).flatMap { $0 > 0 ? $0 : nil }
    }

    private final class RootReader: NSObject, XMLParserDelegate {
        var attributes: [String: String]?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            // The first element is the document root.
            self.attributes = attributes
            parser.abortParsing()
        }
    }
}
