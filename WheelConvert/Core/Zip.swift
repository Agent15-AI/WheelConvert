import Foundation

/// Minimal ZIP reading and writing for document containers (DOCX, EPUB, Pages), using zlib.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
        let isEncrypted: Bool
    }

    let data: Data
    let entries: [Entry]
    private let index: [String: Int]

    /// Total uncompressed bytes allowed across one archive, to defuse zip bombs.
    static let expansionLimit = 1 << 30

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
        var index: [String: Int] = [:]
        for (i, entry) in entries.enumerated() where index[entry.name] == nil { index[entry.name] = i }
        self.index = index
    }

    func entry(_ name: String) -> Entry? {
        index[name].map { entries[$0] } ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func contains(_ name: String) -> Bool { entry(name) != nil }

    func read(_ name: String) throws -> Data {
        guard let entry = entry(name) else { throw WheelError("The document is missing \(name).") }
        return try read(entry)
    }

    func readString(_ name: String) throws -> String {
        let bytes = try read(name)
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    func read(_ entry: Entry) throws -> Data {
        guard !entry.isEncrypted else { throw WheelError("Encrypted archive entries cannot be opened.") }
        guard entry.size <= Self.expansionLimit else { throw WheelError("The archive expands beyond the safety limit.") }
        let base = entry.localHeaderOffset
        // Every bound is checked against the file size first, so crafted sizes can't overflow.
        guard base >= 0, base <= data.count - 30, data.u32(base) == 0x04034b50 else { throw WheelError("The archive is damaged.") }
        let start = base + 30 + Int(data.u16(base + 26)) + Int(data.u16(base + 28))
        guard entry.compressedSize >= 0, entry.compressedSize <= data.count, start <= data.count - entry.compressedSize else { throw WheelError("The archive is damaged.") }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0: output = raw
        case 8: output = try Self.inflateRaw(raw, expected: entry.size)
        default: throw WheelError("The archive uses an unsupported compression method.")
        }
        guard output.count == entry.size, Self.checksum(output) == entry.crc else { throw WheelError("The archive contains a damaged file: \(entry.name)") }
        return output
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw WheelError("The file is not a valid ZIP container.") }
        var eocd = -1
        let lowest = max(0, data.count - 65_557)
        var i = data.count - 22
        while i >= lowest {
            if data.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw WheelError("The file is not a valid ZIP container.") }
        var count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))
        // ZIP64: the locator sits just before the classic record.
        if (count == 0xFFFF || offset == 0xFFFF_FFFF), eocd >= 20, data.u32(eocd - 20) == 0x07064b50 {
            let record = Int(clamping: data.u64(eocd - 12))
            if record <= data.count - 56, data.u32(record) == 0x06064b50 {
                count = Int(clamping: data.u64(record + 32))
                offset = Int(clamping: data.u64(record + 48))
            }
        }
        guard count < 200_000 else { throw WheelError("The archive has too many entries.") }
        var entries: [Entry] = []
        var p = offset
        for _ in 0..<count {
            guard p >= 0, p <= data.count - 46, data.u32(p) == 0x02014b50 else { throw WheelError("The ZIP container is damaged or unsupported.") }
            let flags = data.u16(p + 8)
            let method = data.u16(p + 10)
            let crc = data.u32(p + 16)
            var compressed = Int(data.u32(p + 20))
            var size = Int(data.u32(p + 24))
            let nameLength = Int(data.u16(p + 28)), extraLength = Int(data.u16(p + 30)), commentLength = Int(data.u16(p + 32))
            var local = Int(data.u32(p + 42))
            guard p + 46 + nameLength + extraLength <= data.count else { throw WheelError("The ZIP container is damaged.") }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            // ZIP64 extra field carries 64-bit sizes and offset.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = data.u16(e), length = Int(data.u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF, q + 8 <= extraEnd { size = Int(clamping: data.u64(q)); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= extraEnd { compressed = Int(clamping: data.u64(q)); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= extraEnd { local = Int(clamping: data.u64(q)) }
                }
                e += 4 + length
            }
            entries.append(Entry(name: name, method: method, crc: crc, compressedSize: compressed, size: size,
                                 localHeaderOffset: local, isDirectory: name.hasSuffix("/"), isEncrypted: flags & 1 != 0))
            p += 46 + nameLength + extraLength + commentLength
        }
        var total = 0
        for entry in entries {
            guard entry.size <= expansionLimit - total else { throw WheelError("The archive expands beyond the safety limit.") }
            total += entry.size
        }
        return entries
    }

    static func inflateRaw(_ input: Data, expected: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WheelError("Could not decompress the archive.")
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(expected, 1))
        var status: Int32 = Z_OK
        input.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: inBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            output.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) in
                stream.next_out = outBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuffer.count)
                status = inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || (status == Z_BUF_ERROR && expected == 0) else { throw WheelError("Could not decompress the archive.") }
        output.count = Int(stream.total_out)
        return output
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }
}

/// Builds a ZIP file in memory.
struct ZipWriter {
    private var output = Data()
    private var central = Data()
    private var count = 0

    /// - Parameter compress: false stores the bytes (required for EPUB's `mimetype`).
    mutating func add(_ name: String, _ data: Data, compress: Bool = true, level: Int32 = 6, date: Date = Date()) throws {
        let nameData = Data(name.utf8)
        let crc = ZipArchive.checksum(data)
        let payload = compress ? try Self.deflateRaw(data, level: level) : data
        let stored = !compress || payload.count >= data.count
        let body = stored ? data : payload
        guard output.count < 0xFFFF_FFFF, body.count < 0xFFFF_FFFF else { throw WheelError("The document is too large to package.") }
        let (dosTime, dosDate) = Self.dosTimestamp(date)
        let offset = UInt32(output.count)
        var local = Data()
        local.append32(0x04034b50); local.append16(20); local.append16(0x0800)
        local.append16(stored ? 0 : 8); local.append16(dosTime); local.append16(dosDate)
        local.append32(crc); local.append32(UInt32(body.count)); local.append32(UInt32(data.count))
        local.append16(UInt16(nameData.count)); local.append16(0)
        output.append(local); output.append(nameData); output.append(body)

        central.append32(0x02014b50); central.append16(0x0314); central.append16(20); central.append16(0x0800)
        central.append16(stored ? 0 : 8); central.append16(dosTime); central.append16(dosDate)
        central.append32(crc); central.append32(UInt32(body.count)); central.append32(UInt32(data.count))
        central.append16(UInt16(nameData.count)); central.append16(0); central.append16(0)
        central.append16(0); central.append16(0); central.append32(0o100644 << 16)
        central.append32(offset); central.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var result = output
        let centralOffset = UInt32(output.count)
        result.append(central)
        result.append32(0x06054b50); result.append16(0); result.append16(0)
        result.append16(UInt16(min(count, 0xFFFF))); result.append16(UInt16(min(count, 0xFFFF)))
        result.append32(UInt32(central.count)); result.append32(centralOffset); result.append16(0)
        return result
    }

    static func deflateRaw(_ input: Data, level: Int32) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WheelError("Could not compress the document.")
        }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(input.count)))
        var output = Data(count: bound)
        var status: Int32 = Z_OK
        input.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: inBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            output.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) in
                stream.next_out = outBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuffer.count)
                status = deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw WheelError("Could not compress the document.") }
        output.count = Int(stream.total_out)
        return output
    }

    static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = hour << 11 | minute << 5 | second / 2
        let date: Int = year << 9 | month << 5 | day
        return (UInt16(time), UInt16(date))
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }

    mutating func append16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
