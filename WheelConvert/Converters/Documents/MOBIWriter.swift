import Foundation
import ImageIO

/// Writes classic MOBI (Mobipocket, the format every Kindle reads from USB): the book's HTML in
/// PalmDOC-compressed text records, JPEG pictures in their own records, and an EXTH block with the
/// title, author, language and cover. Links inside the book become Kindle file positions.
enum MOBIWriter {
    static func write(_ doc: StructuredDocument) throws -> Data {
        var images: [Data] = []
        var imageIndex: [Data: Int] = [:]
        var writer = HTMLWriter(images: .referenced { image in
            if let index = imageIndex[image.data] { return String(format: "recindex:%05d", index) }
            guard let jpeg = kindleJPEG(image.data) else { return "" }
            images.append(jpeg)
            imageIndex[image.data] = images.count
            return String(format: "recindex:%05d", images.count)
        })
        let text = try html(doc, body: writer.fragment(doc.blocks))
        // A book that opens with a picture uses it as the cover.
        let hasCover: Bool = if case .image(let first)? = doc.blocks.first { imageIndex[first.data] == 1 } else { false }
        return palmDatabase(doc, text: text, images: images, hasCover: hasCover)
    }

    // MARK: HTML

    /// HTMLWriter's markup in the tags Mobipocket understands, with a contents page when the book
    /// has chapters, and every "#id" link turned into a file position.
    static func html(_ doc: StructuredDocument, body: String) throws -> [UInt8] {
        var body = body
        for (from, to) in [(#"<figure>"#, #"<div align="center">"#), (#"</figure>"#, "</div>"),
                           (#" style="text-align:center""#, #" align="center""#), (#" style="text-align:right""#, #" align="right""#),
                           (#" style="text-align:justify""#, #" align="justify""#), (#"<div class="pagebreak"></div>"#, "<mbp:pagebreak/>"),
                           (#"<section class="footnotes">"#, "<mbp:pagebreak/><div>"), ("</section>", "</div>"),
                           ("<s>", "<strike>"), ("</s>", "</strike>"), ("</span>", "</font>")] {
            body = body.replacingOccurrences(of: from, with: to)
        }
        body = body.replacingOccurrences(of: ##"<span style="color:#([0-9A-Fa-f]{6})">"##, with: ##"<font color="#$1">"##, options: .regularExpression)
            .replacingOccurrences(of: #"src="recindex:(\d+)""#, with: #"recindex="$1""#, options: .regularExpression)

        // Chapters (h1 and h2) get anchors and a contents page at the end, which Kindle's
        // "Go To → Table of Contents" opens.
        let heading = try NSRegularExpression(pattern: #"<h([12])>(.*?)</h\1>"#, options: [.dotMatchesLineSeparators])
        let matches = heading.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var contents = ""
        var guide = ""
        if matches.count >= 2 {
            var entries: [String] = []
            for (i, match) in matches.enumerated().reversed() {
                let level = (body as NSString).substring(with: match.range(at: 1))
                let inner = (body as NSString).substring(with: match.range(at: 2))
                let label = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                entries.insert("<p>\(level == "2" ? "&#160;&#160;&#160;" : "")<a href=\"#wc-ch\(i)\">\(label)</a></p>", at: 0)
                body = (body as NSString).replacingCharacters(in: match.range, with: "<h\(level) id=\"wc-ch\(i)\">\(inner)</h\(level)>")
            }
            let title = HTMLWriter.escape(String(localized: "Contents"))
            contents = "<mbp:pagebreak/><h2 id=\"wc-toc\">\(title)</h2>" + entries.joined()
            guide = "<reference type=\"toc\" title=\"\(title)\" href=\"#wc-toc\"/>"
        }
        let page = "<html><head><guide>\(guide)<reference type=\"text\" title=\"Start\" href=\"#wc-start\"/></guide></head>"
            + "<body><a id=\"wc-start\"></a>\(body)\(contents)</body></html>"
        return try filepositions(page)
    }

    /// Kindle links by byte offset ("filepos") instead of by id: each `href="#id"` becomes a ten-digit
    /// position, filled in once the text is final so the digits never move anything.
    static func filepositions(_ page: String) throws -> [UInt8] {
        let link = try NSRegularExpression(pattern: ##"href="#([^"]+)""##)
        var bytes: [UInt8] = []
        var pending: [(at: Int, id: String)] = []
        var cursor = page.startIndex
        for match in link.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
            guard let whole = Range(match.range, in: page), let id = Range(match.range(at: 1), in: page) else { continue }
            bytes += Array(page[cursor..<whole.lowerBound].utf8)
            bytes += Array("filepos=".utf8)
            pending.append((bytes.count, String(page[id])))
            bytes += Array("0000000000".utf8)
            cursor = whole.upperBound
        }
        bytes += Array(page[cursor...].utf8)
        var targets: [String: Int] = [:]
        let anchor = try NSRegularExpression(pattern: #" id="([^"]+)""#)
        let text = String(decoding: bytes, as: UTF8.self)
        for match in anchor.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let attribute = Range(match.range, in: text), let id = Range(match.range(at: 1), in: text),
                  let tag = text[..<attribute.lowerBound].lastIndex(of: "<") else { continue }
            targets[String(text[id])] = text.utf8.distance(from: text.startIndex, to: tag)
        }
        for (at, id) in pending {
            if let target = targets[id] {
                bytes.replaceSubrange(at..<(at + 10), with: Array(String(format: "%010d", target).utf8))
            } else {
                // A link to an anchor the book doesn't have stays as text: spaces keep every position.
                bytes.replaceSubrange((at - 8)..<(at + 10), with: [UInt8](repeating: 0x20, count: 18))
            }
        }
        return bytes
    }

    // MARK: Pictures

    /// Kindles show JPEG most reliably and refuse pictures above 127 KB in MOBI books: transparency
    /// goes onto white, and quality, then size, step down until the picture fits.
    static func kindleJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(ImageSniffer.portable(data) as CFData, nil) else { return nil }
        var side = 1600.0
        for _ in 0..<6 {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            guard let flat = context.makeImage() else { return nil }
            for quality in [0.85, 0.7, 0.55] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= 127 * 1024 { return output as Data }
            }
            side = (min(side, Double(max(image.width, image.height))) * 0.75).rounded()
        }
        return nil
    }

    // MARK: Palm database

    static let recordSize = 4096

    static func palmDatabase(_ doc: StructuredDocument, text: [UInt8], images: [Data], hasCover: Bool) -> Data {
        let textRecords = textRecords(text)
        let firstImage = 1 + textRecords.count
        let flis = firstImage + images.count, fcis = flis + 1
        var records = [header(doc, textLength: text.count, textRecords: textRecords.count, firstImage: images.isEmpty ? nil : firstImage,
                              lastContent: flis - 1, flis: flis, fcis: fcis, hasCover: hasCover)]
        records += textRecords
        records += images.map { [UInt8]($0) }
        records.append(Array("FLIS".utf8) + [0, 0, 0, 8, 0, 0x41, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF])
        records.append(Array("FCIS".utf8) + [0, 0, 0, 0x14, 0, 0, 0, 0x10, 0, 0, 0, 1, 0, 0, 0, 0] + be32(text.count)
                       + [0, 0, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 8, 0, 1, 0, 1, 0, 0, 0, 0])
        records.append([0xE9, 0x8E, 0x0D, 0x0A])

        // The database name is ASCII, at most 31 characters.
        let name = (doc.inferredTitle ?? "Book").unicodeScalars.map { $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) ? Character($0) : "_" }
        var out = Array(String(name.prefix(31)).utf8)
        out += [UInt8](repeating: 0, count: 32 - out.count)
        let now = UInt32(Date().timeIntervalSince1970)
        out += [0, 0, 0, 0] + be32(Int(now)) + be32(Int(now)) + [UInt8](repeating: 0, count: 16)
        out += Array("BOOKMOBI".utf8) + be32(2 * records.count - 1) + be32(0) + be16(records.count)
        var offset = out.count + 8 * records.count + 2
        for (i, record) in records.enumerated() {
            out += be32(offset) + [0] + Array(be32(2 * i).suffix(3))
            offset += record.count
        }
        out += [0, 0]
        for record in records { out += record }
        return Data(out)
    }

    /// 4096 bytes of text per record. A character split between records is repeated after the
    /// compressed data and counted in a final byte (Mobipocket's "multibyte" trailing entry).
    static func textRecords(_ text: [UInt8]) -> [[UInt8]] {
        var records: [[UInt8]] = []
        var start = 0
        while start < text.count {
            let end = min(start + recordSize, text.count)
            var overlap = end
            // Continuation bytes (10xxxxxx) after the cut belong to the character it split.
            while overlap < text.count, overlap - end < 3, text[overlap] & 0xC0 == 0x80 { overlap += 1 }
            records.append(palmDOC(Array(text[start..<end])) + text[end..<overlap] + [UInt8(overlap - end)])
            start = end
        }
        return records
    }

    static func header(_ doc: StructuredDocument, textLength: Int, textRecords: Int, firstImage: Int?, lastContent: Int,
                       flis: Int, fcis: Int, hasCover: Bool) -> [UInt8] {
        let none = 0xFFFF_FFFF
        var exth: [(Int, [UInt8])] = [(503, Array((doc.inferredTitle ?? "Book").utf8))]
        if let author = doc.author, !author.isEmpty { exth.append((100, Array(author.utf8))) }
        if let language = doc.language, !language.isEmpty { exth.append((524, Array(language.utf8))) }
        if hasCover { exth += [(201, be32(0)), (203, be32(0))] }
        var exthBytes = exth.flatMap { be32($0.0) + be32($0.1.count + 8) + $0.1 }
        exthBytes = Array("EXTH".utf8) + be32(12 + exthBytes.count) + be32(exth.count) + exthBytes
        exthBytes += [UInt8](repeating: 0, count: (4 - exthBytes.count % 4) % 4)

        // PalmDOC header, then the MOBI header (232 bytes), EXTH and the full title.
        var r = be16(2) + be16(0) + be32(textLength) + be16(textRecords) + be16(recordSize) + be16(0) + be16(0)
        r += [UInt8](repeating: 0, count: 232)
        func put(_ offset: Int, _ value: Int) { r.replaceSubrange(offset..<(offset + 4), with: be32(value)) }
        r.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        put(20, 232); put(24, 2); put(28, 65001); put(32, Int(UInt32.random(in: 1...UInt32.max))); put(36, 6)
        for offset in stride(from: 40, through: 76, by: 4) { put(offset, none) }
        put(80, firstImage ?? flis)
        let title = Array((doc.inferredTitle ?? "Book").utf8)
        put(84, 16 + 232 + exthBytes.count); put(88, title.count)
        put(92, locale(doc.language)); put(104, 6); put(108, firstImage ?? none)
        put(128, 0x50)
        put(164, none); put(168, none); put(172, none)
        r.replaceSubrange(192..<196, with: be16(1) + be16(lastContent))
        put(196, 1); put(200, fcis); put(204, 1); put(208, flis); put(212, 1)
        put(224, none); put(232, none); put(236, none)
        put(240, 1) // trailing entries: multibyte overlap only
        put(244, none)
        r += exthBytes + title + [0, 0]
        r += [UInt8](repeating: 0, count: (4 - r.count % 4) % 4)
        return r
    }

    /// Mobipocket's language field (a Windows language id); the EXTH language string says the rest.
    static func locale(_ language: String?) -> Int {
        let ids = ["en": 9, "de": 7, "fr": 12, "es": 10, "it": 16, "nl": 19, "pt": 22, "ja": 17, "zh": 4, "ko": 18,
                   "ru": 25, "sv": 29, "da": 6, "fi": 11, "nb": 20, "no": 20, "pl": 21, "tr": 31]
        return ids[String((language ?? "").lowercased().prefix(2))] ?? 0
    }

    // MARK: PalmDOC compression

    /// PalmDOC's LZ77: back references of 3–10 bytes up to 2047 bytes back, a space folded into the
    /// next character, and bytes that would read as codes sent in counted runs.
    static func palmDOC(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var recent: [Int: [Int]] = [:]
        func key(_ i: Int) -> Int { Int(data[i]) << 16 | Int(data[i + 1]) << 8 | Int(data[i + 2]) }
        var i = 0
        while i < data.count {
            if i + 3 <= data.count {
                var best = 0, distance = 0
                for start in (recent[key(i)] ?? []).reversed().prefix(64) {
                    guard i - start <= 2047 else { break }
                    var length = 0
                    while length < 10, i + length < data.count, start + length < i, data[start + length] == data[i + length] { length += 1 }
                    if length > best { best = length; distance = i - start }
                    if best == 10 { break }
                }
                if best >= 3 {
                    let code = 0x8000 | distance << 3 | (best - 3)
                    out += [UInt8(code >> 8), UInt8(code & 0xFF)]
                    for j in i..<(i + best) where j + 3 <= data.count { recent[key(j), default: []].append(j) }
                    i += best
                    continue
                }
                recent[key(i), default: []].append(i)
            }
            let c = data[i]
            if c == 0x20, i + 1 < data.count, (0x40..<0x80).contains(data[i + 1]) {
                out.append(data[i + 1] ^ 0x80)
                if i + 4 <= data.count { recent[key(i + 1), default: []].append(i + 1) }
                i += 2
            } else if c == 0 || (0x09..<0x80).contains(c) {
                out.append(c)
                i += 1
            } else {
                var run = [c]
                var j = i + 1
                while j < data.count, run.count < 8, !(data[j] == 0 || (0x09..<0x80).contains(data[j])) {
                    run.append(data[j])
                    j += 1
                }
                out += [UInt8(run.count)] + run
                for k in (i + 1)..<j where k + 3 <= data.count { recent[key(k), default: []].append(k) }
                i = j
            }
        }
        return out
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
