import AppKit
import PDFKit

/// Lays documents out with WebKit and prints them to PDF.
@MainActor
enum DocumentPrinter {
    /// Prints standalone HTML onto pages of the given size and margins.
    static func printHTML(_ html: String, page: StructuredDocument.PageSetup, to destination: URL, baseURL: URL? = nil) async throws {
        let view = try await OfflineWebView.make(width: (page.width - page.left - page.right) / 0.75, height: page.height / 0.75, allowedDirectory: baseURL)
        defer { view.close() }
        try await view.loadHTML(html, baseURL: baseURL, timeout: 120)
        // WebKit takes page size and margins from @page; print-info margins alone are ignored.
        let pageCSS = "@page{size:\(page.width)pt \(page.height)pt;margin:\(page.top)pt \(page.right)pt \(page.bottom)pt \(page.left)pt}"
        try await view.evaluate("""
        const style = document.createElement('style');
        style.textContent = css;
        document.head.appendChild(style);
        return true;
        """, arguments: ["css": pageCSS])
        try await view.evaluate("""
        await Promise.allSettled(Array.from(document.images).map(i => i.decode()));
        await document.fonts.ready;
        return true;
        """)
        try await view.print(to: destination, paper: CGSize(width: page.width, height: page.height),
                              margins: NSEdgeInsets(top: page.top, left: page.left, bottom: page.bottom, right: page.right))
    }

    /// DOCX → PDF with docx-preview, one PDF page per laid-out Word page.
    static func printDOCX(_ source: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 128 * 1024 * 1024 else { throw WheelError("The document is empty or exceeds the 128 MB rendering limit.") }
        let data = try Data(contentsOf: source)
        if let zip = try? ZipArchive(data: data), let xml = try? zip.readString("word/document.xml"),
           xml.range(of: #"<(?:\w+:)?altChunk\b"#, options: .regularExpression) != nil {
            throw WheelError("This DOCX contains an embedded object that cannot be rendered locally. Export it as PDF in its document app to preserve that object.")
        }
        let script = try String(contentsOf: Bundled.docxRenderer, encoding: .utf8)
        let host = """
        <!doctype html><html><head><meta charset="utf-8"><style id="docx-styles"></style>
        <style>\(officeFontAliases)html,body{margin:0;padding:0;background:white}
        section.docx{box-shadow:none!important;margin:0!important}.docx-wrapper{padding:0!important;background:white!important}</style>
        <script>\(script.replacingOccurrences(of: "</script", with: "<\\/script"))</script></head><body><div id="root"></div></body></html>
        """
        let view = try await OfflineWebView.make(width: 1100, height: 1400)
        defer { view.close() }
        try await view.loadHTML(host, timeout: 60)
        progress(0.15)
        guard let sections = try await view.evaluate("return await wcRenderDocx(data);", arguments: ["data": data.base64EncodedString()]) as? [[String: Any]],
              !sections.isEmpty else {
            throw WheelError("The document has no pages.")
        }
        progress(0.4)
        let scratch = try ScratchDirectory()
        var parts: [URL] = []
        for (index, section) in sections.enumerated() {
            let width = section["width"] as? Double ?? 612, height = section["height"] as? Double ?? 792
            guard width > 36, height > 36, width <= 22 * 72, height <= 22 * 72 else {
                throw WheelError("A page has invalid dimensions or exceeds Word's 22-inch page limit.")
            }
            let contentHeight = section["contentHeight"] as? Double ?? height
            let part = scratch.file("section-\(index).pdf")
            view.resize(to: CGSize(width: max(1100, width / 0.75 + 40), height: 1400))
            guard let rect = try await view.evaluate("return wcShowSection(\(index));") as? [String: Double] else {
                throw WheelError("A rendered page is missing.")
            }
            if contentHeight <= height * 1.02 {
                // One Word page: capture its full page box and scale CSS pixels to points.
                let box = CGRect(x: rect["x"] ?? 0, y: rect["y"] ?? 0, width: width / 0.75, height: height / 0.75)
                let pdf = try await view.pdf(of: box)
                try PDFScaler.scale(pdf, to: CGSize(width: width, height: height), destination: part)
            } else {
                // Longer than one page (no Word page markers): let WebKit paginate it.
                let top = section["top"] as? Double ?? 72, bottom = section["bottom"] as? Double ?? 72
                let left = section["left"] as? Double ?? 72, right = section["right"] as? Double ?? 72
                _ = try await view.evaluate("return wcPreparePrint(\(index));")
                view.resize(to: CGSize(width: (width - left - right) / 0.75, height: height / 0.75))
                try await view.print(to: part, paper: CGSize(width: width, height: height),
                                     margins: NSEdgeInsets(top: top, left: left, bottom: bottom, right: right))
            }
            parts.append(part)
            progress(0.4 + 0.55 * Double(index + 1) / Double(sections.count))
        }
        try PDFMerge.combine(parts, to: destination)
    }
}

/// Office fonts that macOS lacks, mapped to close system equivalents so documents keep their look.
let officeFontAliases: String = {
    let aliases: [(String, [String])] = [
        ("Calibri", ["HelveticaNeue", "Helvetica Neue", "Helvetica"]), ("Calibri Light", ["HelveticaNeue-Light", "Helvetica Neue Light"]),
        ("Aptos", ["HelveticaNeue", "Helvetica Neue"]), ("Aptos Display", ["HelveticaNeue", "Helvetica Neue"]),
        ("Segoe UI", ["HelveticaNeue", "Helvetica Neue"]), ("Cambria", ["Georgia", "Times New Roman"]),
        ("Consolas", ["Menlo-Regular", "Menlo"]), ("Century Gothic", ["Avenir-Book", "Avenir Book"]),
        ("Franklin Gothic Book", ["HelveticaNeue", "Helvetica Neue"]), ("Book Antiqua", ["Palatino-Roman", "Palatino"]),
    ]
    return aliases.map { name, locals in
        "@font-face{font-family:\"\(name)\";src:" + locals.map { "local(\"\($0)\")" }.joined(separator: ",") + "}"
    }.joined()
}()

/// Redraws PDF pages at a new size; vector content stays vector.
enum PDFScaler {
    static func scale(_ data: Data, to size: CGSize, destination: URL) throws {
        guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider), source.numberOfPages > 0,
              let consumer = CGDataConsumer(url: destination as CFURL) else { throw WheelError("A PDF page could not be rendered.") }
        var media = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextCreator: "WheelConvert"] as CFDictionary) else {
            throw WheelError("Could not create the PDF.")
        }
        for index in 1...source.numberOfPages {
            guard let page = source.page(at: index) else { continue }
            let box = page.getBoxRect(.mediaBox)
            context.beginPDFPage([kCGPDFContextMediaBox: NSValue(rect: media)] as CFDictionary)
            context.scaleBy(x: size.width / box.width, y: size.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
