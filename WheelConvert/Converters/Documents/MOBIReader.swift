import Foundation

/// Reads DRM-free Kindle books: classic MOBI and KF8 (AZW3, and the KF8 half of newer .mobi files).
/// The book's HTML goes through HTMLReader; pictures come from its image records.
enum MOBIReader {
    static func read(_ url: URL) throws -> StructuredDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 256 * 1024 * 1024 else { throw WheelError("The Kindle book is empty or too large to open safely.") }
        let bytes = [UInt8](try Data(contentsOf: url))
        // KFX books (Amazon's newest format) are containers of their own, not Palm databases.
        if bytes.starts(with: [0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E]) || bytes.starts(with: Array("CONT".utf8)) {
            throw WheelError("This is a KFX Kindle book, which WheelConvert can’t read. MOBI and AZW3 books work.")
        }
        let database = try PalmDatabase(bytes)
        var book = try Book(database, base: 0)
        // Combined files carry an older MOBI copy first and the KF8 book after the boundary record.
        if let boundary = book.kf8Boundary, let kf8 = try? Book(database, base: boundary), kf8.version >= 8 { book = kf8 }
        let text = try book.text()
        let flows = book.version >= 8 ? book.flows(text) : [text]
        var doc = StructuredDocument()
        doc.title = book.title
        doc.author = book.author
        doc.language = book.language
        for part in book.version >= 8 ? book.kf8Parts(flows[0]) : [book.mobiHTML(text)] {
            let reader = HTMLReader { src in book.image(src, flows: flows) }
            var blocks = reader.parse(Data(part.utf8))
            if !doc.blocks.isEmpty, !blocks.isEmpty, case .heading = blocks[0] {} else if !doc.blocks.isEmpty && !blocks.isEmpty { blocks.insert(.pageBreak, at: 0) }
            doc.blocks += blocks
        }
        guard !doc.blocks.isEmpty else { throw WheelError("The Kindle book has no readable text.") }
        // The cover lives outside the text; books that don't already open with it get it first.
        if case .image = doc.blocks[0] {} else if let cover = book.cover() {
            doc.blocks.insert(contentsOf: [.image(.init(data: cover, alt: "Cover")), .pageBreak], at: 0)
        }
        return doc
    }

    static let damaged = WheelError("The Kindle book is damaged or not a Kindle book WheelConvert can read.")

    // MARK: Bytes

    /// Big-endian integers that read 0 past the end, so damaged files fail checks instead of trapping.
    static func be16(_ b: [UInt8], _ o: Int) -> Int { o >= 0 && o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
    static func be32(_ b: [UInt8], _ o: Int) -> Int { o >= 0 && o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }
    static func starts(_ b: [UInt8], _ tag: String, at o: Int = 0) -> Bool { o >= 0 && o + tag.utf8.count <= b.count && Array(b[o..<(o + tag.utf8.count)]) == Array(tag.utf8) }

    // MARK: Palm database

    struct PalmDatabase {
        let bytes: [UInt8]
        let offsets: [Int]

        init(_ bytes: [UInt8]) throws {
            guard bytes.count >= 86, MOBIReader.starts(bytes, "BOOKMOBI", at: 60) else {
                throw WheelError("This file is not a Kindle book WheelConvert can read.")
            }
            let count = MOBIReader.be16(bytes, 76)
            guard count > 0, 78 + 8 * count <= bytes.count else { throw MOBIReader.damaged }
            offsets = (0..<count).map { MOBIReader.be32(bytes, 78 + 8 * $0) }
            guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }), offsets.last! <= bytes.count else { throw MOBIReader.damaged }
            self.bytes = bytes
        }

        func record(_ index: Int) -> [UInt8] {
            guard index >= 0, index < offsets.count else { return [] }
            let end = index + 1 < offsets.count ? offsets[index + 1] : bytes.count
            return Array(bytes[offsets[index]..<end])
        }
    }

    // MARK: Book

    struct Book {
        let database: PalmDatabase
        /// Record 0 of this book: 0, or the KF8 boundary in combined files.
        let base: Int
        var compression = 0, textLength = 0, textRecords = 0, version = 0, extraFlags = 0, encoding = 65001
        var firstImage: Int?, huffman: Int?, huffmanCount = 0, fdst: Int?, skeleton: Int?, fragment: Int?
        var title: String?, author: String?, language: String?, kf8Boundary: Int?, coverOffset: Int?

        init(_ database: PalmDatabase, base: Int) throws {
            self.database = database
            self.base = base
            let r = database.record(base)
            guard r.count >= 0x84, MOBIReader.starts(r, "MOBI", at: 16) else { throw MOBIReader.damaged }
            compression = MOBIReader.be16(r, 0)
            textLength = MOBIReader.be32(r, 4)
            textRecords = MOBIReader.be16(r, 8)
            guard MOBIReader.be16(r, 12) == 0 else {
                throw WheelError("This Kindle book is protected with DRM (copy protection). WheelConvert can only convert DRM-free books.")
            }
            let headerLength = MOBIReader.be32(r, 20)
            encoding = MOBIReader.be32(r, 28)
            version = MOBIReader.be32(r, 0x68)
            firstImage = record(MOBIReader.be32(r, 0x6C))
            huffman = record(MOBIReader.be32(r, 0x70))
            huffmanCount = MOBIReader.be32(r, 0x74)
            if headerLength >= 0xE4 { extraFlags = MOBIReader.be16(r, 0xF2) }
            if version >= 8, headerLength >= 0xF0 {
                fdst = record(MOBIReader.be32(r, 0xC0))
                fragment = record(MOBIReader.be32(r, 0xF8))
                skeleton = record(MOBIReader.be32(r, 0xFC))
            }
            let nameOffset = MOBIReader.be32(r, 0x54), nameLength = MOBIReader.be32(r, 0x58)
            if nameLength > 0, nameOffset + nameLength <= r.count { title = decode(Array(r[nameOffset..<(nameOffset + nameLength)])) }
            if MOBIReader.be32(r, 0x80) & 0x40 != 0 { readEXTH(r, at: 16 + headerLength) }
        }

        /// A record number from the header (0xFFFFFFFF means none), counted from this book's record 0.
        func record(_ value: Int) -> Int? { value == 0xFFFF_FFFF || value == 0 ? nil : base + value }

        mutating func readEXTH(_ r: [UInt8], at start: Int) {
            guard MOBIReader.starts(r, "EXTH", at: start) else { return }
            var offset = start + 12
            for _ in 0..<min(MOBIReader.be32(r, start + 8), 1024) {
                let type = MOBIReader.be32(r, offset), length = MOBIReader.be32(r, offset + 4)
                guard length >= 8, offset + length <= r.count else { return }
                let value = Array(r[(offset + 8)..<(offset + length)])
                switch type {
                case 100: author = decode(value)
                case 503: title = decode(value)
                case 524: language = decode(value)
                case 201: coverOffset = MOBIReader.be32(value, 0) == 0xFFFF_FFFF ? nil : MOBIReader.be32(value, 0)
                case 121 where base == 0: kf8Boundary = MOBIReader.be32(value, 0) == 0xFFFF_FFFF ? nil : MOBIReader.be32(value, 0)
                default: break
                }
                offset += length
            }
        }

        func decode(_ bytes: [UInt8]) -> String {
            let data = Data(bytes)
            return (encoding == 1252 ? String(data: data, encoding: .windowsCP1252) : nil) ?? String(decoding: data, as: UTF8.self)
        }

        /// The book's text, every text record decompressed without its trailing entries.
        func text() throws -> [UInt8] {
            var huff = compression == 17480 ? try HuffCDIC(database, first: huffman, count: huffmanCount) : nil
            guard [1, 2, 17480].contains(compression) else { throw WheelError("This Kindle book uses a compression WheelConvert can’t read.") }
            var out: [UInt8] = []
            out.reserveCapacity(min(textLength, 64 << 20))
            for index in (base + 1)..<(base + 1 + textRecords) {
                var record = database.record(index)
                record.removeLast(min(record.count, MOBIReader.trailingSize(record, flags: extraFlags)))
                switch compression {
                case 2: out += MOBIReader.palmDOC(record)
                case 17480: out += try huff!.unpack(record)
                default: out += record
                }
                guard out.count <= 64 << 20 else { throw MOBIReader.damaged }
            }
            return Array(out.prefix(textLength))
        }

        /// Classic MOBI markup made readable for HTMLReader: pictures referenced by record number become
        /// src attributes, and Mobipocket's own tags (page breaks) go.
        func mobiHTML(_ text: [UInt8]) -> String {
            decode(text)
                .replacingOccurrences(of: #"</?mbp:[^>]*>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\brecindex\s*=\s*["']?(\d+)["']?"#, with: #"src="recindex:$1""#, options: .regularExpression)
        }

        /// KF8 text is divided into flows: the HTML first, then style sheets and SVG.
        func flows(_ text: [UInt8]) -> [[UInt8]] {
            let table = database.record(fdst ?? -1)
            guard MOBIReader.starts(table, "FDST") else { return [text] }
            let flows = (0..<min(MOBIReader.be32(table, 8), 1024)).compactMap { i -> [UInt8]? in
                let start = MOBIReader.be32(table, 12 + 8 * i), end = MOBIReader.be32(table, 16 + 8 * i)
                return start <= end && end <= text.count ? Array(text[start..<end]) : nil
            }
            return flows.isEmpty ? [text] : flows
        }

        /// KF8 keeps each HTML file as a skeleton plus fragments inserted at recorded positions.
        func kf8Parts(_ flowBytes: [UInt8]) -> [String] {
            let skeletons = MOBIReader.index(database, first: skeleton), fragments = MOBIReader.index(database, first: fragment)
            guard !skeletons.isEmpty else { return [decode(flowBytes)] }
            var parts: [String] = []
            var next = 0
            for skeleton in skeletons {
                guard let span = skeleton.tags[6], span.count >= 2, span[0] >= 0, span[0] + span[1] <= flowBytes.count else { continue }
                var html = Array(flowBytes[span[0]..<(span[0] + span[1])])
                var cursor = span[0] + span[1]
                for _ in 0..<min(skeleton.tags[1]?.first ?? 0, fragments.count - next) {
                    let fragment = fragments[next]
                    next += 1
                    guard let length = fragment.tags[6]?.last, let position = Int(String(decoding: fragment.label, as: UTF8.self)),
                          cursor + length <= flowBytes.count else { continue }
                    let insert = min(max(0, position - span[0]), html.count)
                    html.insert(contentsOf: flowBytes[cursor..<(cursor + length)], at: insert)
                    cursor += length
                }
                parts.append(decode(html))
            }
            return parts
        }

        func cover() -> Data? {
            guard let coverOffset, let firstImage else { return nil }
            let data = Data(database.record(firstImage + coverOffset))
            return ImageSniffer.mime(data).hasPrefix("image/") ? data : nil
        }

        /// Picture bytes for an <img src>: "kindle:embed:000A" (KF8, base 32), "recindex:12" (classic
        /// MOBI) or "kindle:flow:0004" (an SVG flow; one that only frames a picture, like most covers,
        /// gives that picture).
        func image(_ src: String, flows: [[UInt8]]) -> Data? {
            if src.hasPrefix("kindle:flow:") {
                guard let number = Int(src.dropFirst(12).prefix { $0 != "?" }, radix: 32), number > 0, number < flows.count else { return nil }
                let svg = decode(flows[number])
                if let embed = svg.range(of: #"kindle:embed:[0-9A-Va-v]+"#, options: .regularExpression) { return image(String(svg[embed]), flows: flows) }
                return Data(flows[number])
            }
            let number: Int?
            if src.hasPrefix("kindle:embed:") {
                number = Int(src.dropFirst(13).prefix { $0 != "?" }, radix: 32)
            } else if src.hasPrefix("recindex:") {
                number = Int(src.dropFirst(9))
            } else {
                return nil
            }
            guard let number, number > 0, let firstImage else { return nil }
            let data = Data(database.record(firstImage + number - 1))
            return ImageSniffer.mime(data).hasPrefix("image/") ? data : nil
        }
    }

    // MARK: Text records

    /// Bytes at the end of a text record that aren't text: one entry per flag bit above the first,
    /// each ending in its own size, then (flag bit 1) the tail of a character split across records.
    static func trailingSize(_ record: [UInt8], flags: Int) -> Int {
        var size = 0
        var bits = flags >> 1
        while bits != 0 {
            if bits & 1 != 0 {
                // Sizes are stored backwards: 7 bits per byte, the last byte read has its top bit set.
                var value = 0, shift = 0, end = record.count - size
                while end > 0 {
                    let byte = Int(record[end - 1])
                    value |= (byte & 0x7F) << shift
                    shift += 7
                    end -= 1
                    if byte & 0x80 != 0 || shift >= 28 { break }
                }
                size += value
            }
            bits >>= 1
        }
        if flags & 1 != 0, record.count - size - 1 >= 0 { size += Int(record[record.count - size - 1] & 0x3) + 1 }
        return min(size, record.count)
    }

    /// PalmDOC's LZ77: literals, runs of literals, space-plus-character pairs and back references.
    static func palmDOC(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 2)
        var i = 0
        while i < input.count {
            let c = Int(input[i])
            i += 1
            switch c {
            case 1...8:
                out += input[i..<min(input.count, i + c)]
                i += c
            case 0, 9...0x7F:
                out.append(UInt8(c))
            case 0xC0...:
                out += [0x20, UInt8(c ^ 0x80)]
            default:
                guard i < input.count else { return out }
                let pair = c << 8 | Int(input[i])
                i += 1
                let distance = (pair >> 3) & 0x7FF, length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                for _ in 0..<length { out.append(out[out.count - distance]) }
            }
        }
        return out
    }

    /// Kindlegen's Huffman compression: codes look up phrases in the CDIC records, and a phrase may
    /// itself be compressed.
    struct HuffCDIC {
        var dict1: [(length: Int, terminal: Bool, maxCode: UInt64)] = []
        var minCodes: [UInt64] = [], maxCodes: [UInt64] = []
        var phrases: [(bytes: [UInt8], final: Bool)] = []

        init(_ database: PalmDatabase, first: Int?, count: Int) throws {
            guard let first, count >= 2 else { throw MOBIReader.damaged }
            let huff = database.record(first)
            guard MOBIReader.starts(huff, "HUFF"), MOBIReader.be32(huff, 4) == 0x18 else { throw MOBIReader.damaged }
            let table1 = MOBIReader.be32(huff, 8), table2 = MOBIReader.be32(huff, 12)
            guard table1 + 1024 <= huff.count, table2 + 256 <= huff.count else { throw MOBIReader.damaged }
            for i in 0..<256 {
                let v = MOBIReader.be32(huff, table1 + 4 * i)
                let length = v & 0x1F
                guard length > 0 else { throw MOBIReader.damaged }
                dict1.append((length, v & 0x80 != 0, (UInt64((v >> 8) + 1) << (32 - length)) - 1))
            }
            minCodes = [0]
            maxCodes = [0]
            for length in 1...32 {
                minCodes.append(UInt64(MOBIReader.be32(huff, table2 + 8 * (length - 1))) << (32 - length))
                maxCodes.append((UInt64(MOBIReader.be32(huff, table2 + 8 * (length - 1) + 4) + 1) << (32 - length)) - 1)
            }
            for index in (first + 1)..<(first + count) {
                let cdic = database.record(index)
                guard MOBIReader.starts(cdic, "CDIC"), MOBIReader.be32(cdic, 4) == 0x10 else { throw MOBIReader.damaged }
                let total = MOBIReader.be32(cdic, 8), bits = MOBIReader.be32(cdic, 12)
                guard bits <= 31 else { throw MOBIReader.damaged }
                for i in 0..<max(0, min(1 << bits, total - phrases.count)) {
                    let offset = 16 + MOBIReader.be16(cdic, 16 + 2 * i), header = MOBIReader.be16(cdic, offset)
                    let end = offset + 2 + (header & 0x7FFF)
                    guard end <= cdic.count else { throw MOBIReader.damaged }
                    phrases.append((Array(cdic[(offset + 2)..<end]), header & 0x8000 != 0))
                }
            }
        }

        mutating func unpack(_ data: [UInt8], depth: Int = 0) throws -> [UInt8] {
            guard depth < 32 else { throw MOBIReader.damaged }
            let padded = data + [UInt8](repeating: 0, count: 8)
            func word(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(padded[at + $1]) } }
            var bitsLeft = data.count * 8, position = 0, shift = 32
            var x = word(0)
            var out: [UInt8] = []
            while true {
                if shift <= 0 {
                    position += 4
                    x = word(position)
                    shift += 32
                }
                let code = (x >> UInt64(shift)) & 0xFFFF_FFFF
                var (length, terminal, maxCode) = dict1[Int(code >> 24)]
                if !terminal {
                    while length < 32, code < minCodes[length] { length += 1 }
                    maxCode = maxCodes[length]
                }
                shift -= length
                bitsLeft -= length
                if bitsLeft < 0 { break }
                let index = Int(clamping: (maxCode &- code) >> UInt64(32 - length))
                guard index < phrases.count else { throw MOBIReader.damaged }
                if !phrases[index].final {
                    phrases[index] = (try unpack(phrases[index].bytes, depth: depth + 1), true)
                }
                out += phrases[index].bytes
                guard out.count <= 1 << 20 else { throw MOBIReader.damaged }
            }
            return out
        }
    }

    // MARK: KF8 index tables

    /// Entries of a KF8 index (INDX records): each entry's label and its tag values.
    static func index(_ database: PalmDatabase, first: Int?) -> [(label: [UInt8], tags: [Int: [Int]])] {
        guard let first else { return [] }
        let header = database.record(first)
        guard starts(header, "INDX") else { return [] }
        let tagx = be32(header, 4)
        guard starts(header, "TAGX", at: tagx) else { return [] }
        let controlBytes = be32(header, tagx + 8)
        let table = stride(from: tagx + 12, to: min(header.count, tagx + be32(header, tagx + 4)) - 3, by: 4).map {
            (tag: Int(header[$0]), perEntry: Int(header[$0 + 1]), mask: Int(header[$0 + 2]), end: header[$0 + 3] & 1 != 0)
        }
        var entries: [(label: [UInt8], tags: [Int: [Int]])] = []
        for index in (first + 1)..<(first + 1 + min(be32(header, 24), 4096)) {
            let record = database.record(index)
            guard starts(record, "INDX") else { break }
            let idxt = be32(record, 20), count = min(be32(record, 24), 65_536)
            let positions = (0..<count).map { be16(record, idxt + 4 + 2 * $0) } + [idxt]
            for j in 0..<count where positions[j] < positions[j + 1] && positions[j + 1] <= record.count {
                let labelLength = Int(record[positions[j]])
                let tagStart = positions[j] + 1 + labelLength
                guard tagStart <= positions[j + 1] else { continue }
                entries.append((Array(record[(positions[j] + 1)..<tagStart]), tags(record, from: tagStart, to: positions[j + 1], table: table, controlBytes: controlBytes)))
            }
        }
        return entries
    }

    /// Decodes one entry's control bytes and the variable-width values they announce.
    static func tags(_ data: [UInt8], from start: Int, to end: Int, table: [(tag: Int, perEntry: Int, mask: Int, end: Bool)], controlBytes: Int) -> [Int: [Int]] {
        func value(_ at: inout Int) -> Int {
            var result = 0
            while at < end {
                let byte = Int(data[at])
                at += 1
                result = result << 7 | (byte & 0x7F)
                if byte & 0x80 != 0 { break }
            }
            return result
        }
        var announced: [(tag: Int, count: Int?, bytes: Int?, perEntry: Int)] = []
        var controlIndex = 0, at = start + controlBytes
        for entry in table {
            if entry.end { controlIndex += 1; continue }
            guard start + controlIndex < end, entry.mask != 0 else { continue }
            var mask = entry.mask, masked = Int(data[start + controlIndex]) & mask
            guard masked != 0 else { continue }
            if masked == mask && mask.nonzeroBitCount > 1 {
                announced.append((entry.tag, nil, value(&at), entry.perEntry))
            } else {
                while mask & 1 == 0 { mask >>= 1; masked >>= 1 }
                announced.append((entry.tag, masked, nil, entry.perEntry))
            }
        }
        var result: [Int: [Int]] = [:]
        for item in announced {
            var values: [Int] = []
            if let count = item.count {
                for _ in 0..<min(count * item.perEntry, 1024) where at < end { values.append(value(&at)) }
            } else if let bytes = item.bytes {
                let stop = min(end, at + bytes)
                while at < stop { values.append(value(&at)) }
            }
            result[item.tag] = values
        }
        return result
    }
}
