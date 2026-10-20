import Foundation

/// Writes EPUB 3 books: reflowable chapters from a StructuredDocument, or a fixed-layout book of page images.
enum EPUBWriter {
    static let css = """
    body{line-height:1.5;margin:1em auto;max-width:42em;overflow-wrap:break-word;font-family:serif}
    h1,h2,h3,h4,h5,h6{line-height:1.2;break-after:avoid;font-family:sans-serif}
    p{margin:0 0 1em}figure{margin:1em 0;text-align:center;break-inside:avoid}
    figure img,img{max-width:100%;height:auto;object-fit:contain}
    table{border-collapse:collapse;max-width:100%;margin:1em 0}td,th{border:1px solid currentColor;padding:.35em;text-align:start}
    ul,ol{padding-inline-start:1.5em}blockquote{margin:0 0 1em;padding-left:1em;border-left:3px solid #999}
    pre{white-space:pre-wrap;font-family:monospace;font-size:.9em}code{font-family:monospace}
    .footnotes{font-size:.9em;border-top:1px solid #999;margin-top:2em}
    """

    /// - Parameter forKindle: tuned for Send to Kindle: pictures at most 1600 px as JPEG or PNG, a cover
    ///   when the book opens with a picture, and an NCX table of contents for older Kindle software.
    static func write(_ doc: StructuredDocument, forKindle: Bool = false) throws -> Data {
        let title = doc.inferredTitle ?? "Untitled"
        let language = doc.language ?? Locale.current.language.languageCode?.identifier ?? "en"
        var images: [(name: String, data: Data, mime: String)] = []
        var imageNames: [Data: String] = [:]
        let chapters = split(doc.blocks)
        var files: [(name: String, title: String, xhtml: String)] = []
        for (index, blocks) in chapters.enumerated() {
            var writer = HTMLWriter(images: .referenced({ image in
                let data = forKindle ? ImageSniffer.kindleReady(image.data) : ImageSniffer.portable(image.data)
                // Undecodable bytes would need a media type EPUB readers reject; point at nothing instead.
                guard ImageSniffer.mime(data).hasPrefix("image/") else { return "" }
                if let existing = imageNames[data] { return "images/\(existing)" }
                let name = "image-\(images.count + 1).\(ImageSniffer.fileExtension(data))"
                images.append((name, data, ImageSniffer.mime(data)))
                imageNames[data] = name
                return "images/\(name)"
            }), xhtml: true)
            let body = writer.fragment(blocks)
            let chapterTitle = blocks.lazy.compactMap { block -> String? in
                if case .heading(_, let runs) = block { return runs.map(\.text).joined() }
                return nil
            }.first ?? (chapters.count == 1 ? title : "Section \(index + 1)")
            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(esc(language))" xml:lang="\(esc(language))">
            <head><meta charset="utf-8"/><title>\(esc(chapterTitle))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
            \(body)
            </body></html>
            """
            files.append((String(format: "chapter-%04d.xhtml", index + 1), chapterTitle, xhtml))
        }

        var nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(esc(language))" xml:lang="\(esc(language))">
        <head><meta charset="utf-8"/><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
        """
        for file in files { nav += "<li><a href=\"\(file.name)\">\(esc(file.title))</a></li>" }
        nav += "</ol></nav></body></html>"

        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>"
        var spine = ""
        for (i, file) in files.enumerated() {
            manifest += "<item id=\"chapter-\(i + 1)\" href=\"\(file.name)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"chapter-\(i + 1)\"/>"
        }
        // A book that opens with a picture gets it as its cover.
        var opensWithPicture = false
        if case .image = doc.blocks.first(where: { if case .pageBreak = $0 { return false } else { return true } }) { opensWithPicture = !images.isEmpty }
        let cover = forKindle && opensWithPicture
        for (i, image) in images.enumerated() {
            manifest += "<item id=\"img-\(i + 1)\" href=\"images/\(image.name)\" media-type=\"\(image.mime)\"\(cover && i == 0 ? " properties=\"cover-image\"" : "")/>"
        }
        if forKindle { manifest += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>" }
        let opf = package(title: title, author: doc.author, language: language, manifest: manifest, spine: spine,
                          extraMeta: cover ? "<meta name=\"cover\" content=\"img-1\"/>" : "", spineAttributes: forKindle ? " toc=\"ncx\"" : "")

        var zip = ZipWriter()
        try zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        try zip.add("META-INF/container.xml", Data(container.utf8))
        try zip.add("EPUB/package.opf", Data(opf.utf8))
        try zip.add("EPUB/nav.xhtml", Data(nav.utf8))
        try zip.add("EPUB/style.css", Data(css.utf8))
        for file in files { try zip.add("EPUB/\(file.name)", Data(file.xhtml.utf8)) }
        for image in images { try zip.add("EPUB/images/\(image.name)", image.data, compress: false) }
        if forKindle {
            var points = ""
            for (i, file) in files.enumerated() {
                points += "<navPoint id=\"p\(i + 1)\" playOrder=\"\(i + 1)\"><navLabel><text>\(esc(file.title))</text></navLabel><content src=\"\(file.name)\"/></navPoint>"
            }
            let ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="\(esc(title))"/></head>\
            <docTitle><text>\(esc(title))</text></docTitle><navMap>\(points)</navMap></ncx>
            """
            try zip.add("EPUB/toc.ncx", Data(ncx.utf8))
        }
        return zip.finish()
    }

    /// Fixed-layout book: one page per JPEG, each the size of its source page.
    static func writePages(_ pages: [(data: Data, width: Int, height: Int)], title: String) throws -> Data {
        guard !pages.isEmpty else { throw WheelError("The PDF has no pages.") }
        var zip = ZipWriter()
        try zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        try zip.add("META-INF/container.xml", Data(container.utf8))
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        var spine = ""
        for (i, page) in pages.enumerated() {
            let n = i + 1
            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><meta charset="utf-8"/>\
            <meta name="viewport" content="width=\(page.width), height=\(page.height)"/><title>Page \(n)</title>\
            <style>html,body{margin:0;padding:0;width:\(page.width)px;height:\(page.height)px;overflow:hidden}img{display:block;width:100%;height:100%}</style></head>\
            <body><img src="images/page-\(n).jpg" alt="Page \(n)"/></body></html>
            """
            try zip.add("EPUB/page-\(n).xhtml", Data(xhtml.utf8))
            try zip.add("EPUB/images/page-\(n).jpg", page.data, compress: false)
            manifest += "<item id=\"page-\(n)\" href=\"page-\(n).xhtml\" media-type=\"application/xhtml+xml\"/>"
            manifest += "<item id=\"image-\(n)\" href=\"images/page-\(n).jpg\" media-type=\"image/jpeg\"\(n == 1 ? " properties=\"cover-image\"" : "")/>"
            spine += "<itemref idref=\"page-\(n)\"/>"
        }
        var nav = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><meta charset=\"utf-8\"/><title>Contents</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>"
        for n in 1...pages.count { nav += "<li><a href=\"page-\(n).xhtml\">Page \(n)</a></li>" }
        nav += "</ol></nav></body></html>"
        try zip.add("EPUB/nav.xhtml", Data(nav.utf8))
        let fixed = "<meta property=\"rendition:layout\">pre-paginated</meta><meta property=\"rendition:spread\">none</meta><meta name=\"cover\" content=\"image-1\"/>"
        try zip.add("EPUB/package.opf", Data(package(title: title, author: nil, language: "und", manifest: manifest, spine: spine, extraMeta: fixed).utf8))
        return zip.finish()
    }

    /// Chapters break at the top heading level used more than once; small books stay one file.
    static func split(_ blocks: [StructuredDocument.Block]) -> [[StructuredDocument.Block]] {
        var levels: [Int: Int] = [:]
        for block in blocks { if case .heading(let level, _) = block { levels[level, default: 0] += 1 } }
        guard let level = levels.keys.sorted().first(where: { levels[$0]! > 1 }), level <= 2 else { return [blocks] }
        var chapters: [[StructuredDocument.Block]] = [[]]
        for block in blocks {
            if case .heading(let l, _) = block, l <= level, !chapters[chapters.count - 1].isEmpty { chapters.append([]) }
            chapters[chapters.count - 1].append(block)
        }
        return chapters.filter { !$0.isEmpty }
    }

    private static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    private static func package(title: String, author: String?, language: String, manifest: String, spine: String, extraMeta: String, spineAttributes: String = "") -> String {
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(esc(title))</dc:title>
            <dc:language>\(esc(language))</dc:language>
            \(author.map { "<dc:creator>\(esc($0))</dc:creator>" } ?? "")
            <meta property="dcterms:modified">\(modified)</meta>
            \(extraMeta)
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine\(spineAttributes)>\(spine)</spine>
        </package>
        """
    }

    private static func esc(_ text: String) -> String { HTMLWriter.escape(text) }
}
