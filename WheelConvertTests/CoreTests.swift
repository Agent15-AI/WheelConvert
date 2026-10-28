import ImageIO
import XCTest
@testable import WheelConvert

final class CoreTests: XCTestCase {
    func testMatrixHasNoSelfConversionsAndCoversEveryInput() {
        for (input, output) in ConversionMatrix.allPairs { XCTAssertNotEqual(input, output) }
        for format in FileFormat.allCases where !format.isOutputOnly {
            XCTAssertFalse(ConversionMatrix.outputs(for: format).isEmpty, "\(format) has no outputs")
        }
        XCTAssertGreaterThan(ConversionMatrix.allPairs.count, 240)
    }

    func testCommonOutputsForMixedSelection() {
        XCTAssertEqual(ConversionMatrix.outputs(for: [.jpg, .png]), [.webp, .heic, .tiff, .avif, .bmp, .pdf])
        XCTAssertTrue(ConversionMatrix.outputs(for: [.jpg, .mp3]).isEmpty)
    }

    func testDetectionByExtension() {
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/a.JPEG")), .jpg)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/a.tar.gz")), .gzip)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/a.tgz")), .gzip)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/a.markdown")), .md)
        XCTAssertNil(FileFormat.detect(URL(fileURLWithPath: "/x/a.unknownext")))
        for name in ["a.DNG", "a.cr3", "a.NEF", "a.arw", "a.raf", "a.orf", "a.rw2"] { XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/" + name)), .raw) }
        XCTAssertTrue(FileFormat.raw.isInputOnly)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/a.7z")), .sevenZip)
        XCTAssertEqual(FileFormat.sevenZip.fileExtension, "7z")
        XCTAssertTrue(ConversionMatrix.outputs(for: .zip).contains(.sevenZip))
        XCTAssertTrue(ConversionMatrix.outputs(for: .sevenZip).contains(.zip))
        XCTAssertTrue(ConversionMatrix.outputs(for: .raw).contains(.jpg))
    }

    func testUniqueNamingNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = OutputNaming.unique(in: dir, base: "photo", extension: "png")
        XCTAssertEqual(first.lastPathComponent, "photo.png")
        try Data().write(to: first)
        XCTAssertEqual(OutputNaming.unique(in: dir, base: "photo", extension: "png").lastPathComponent, "photo 2.png")
        XCTAssertEqual(OutputNaming.sanitize("a/b:c"), "a-b-c")
        XCTAssertEqual(OutputNaming.baseName(of: URL(fileURLWithPath: "/x/archive.tar.gz")), "archive")
    }

    func testPlacingInParallelNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A broken symlink holds the plain name; fileExists can't see it, the exclusive move can.
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("photo.png").path, withDestinationPath: "/nonexistent/x")
        let sources = try (0..<16).map { i -> URL in
            let url = dir.appendingPathComponent(".wheelconvert-\(i)")
            try Data("\(i)".utf8).write(to: url)
            return url
        }
        var placed = [URL?](repeating: nil, count: sources.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            let url = try? OutputNaming.place(sources[i], in: dir, base: "photo", extension: "png")
            lock.withLock { placed[i] = url }
        }
        XCTAssertEqual(Set(placed.compactMap { $0?.lastPathComponent }).count, 16)
        XCTAssertFalse(placed.contains { $0?.lastPathComponent == "photo.png" })
        for (i, url) in placed.enumerated() {
            XCTAssertEqual(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }, "\(i)")
        }
    }

    func testJobStatusCountsParallelItems() {
        MainActor.assumeIsolated { checkJobStatus() }
    }

    @MainActor
    private func checkJobStatus() {
        let job = JobState(title: "Converting", total: 4)
        job.completed = 1
        job.active = [2: ("c.mov", 0.25), 1: ("b.mov", 0.5)]
        XCTAssertEqual(job.statusText, "1 of 4 done — b.mov, c.mov")
        XCTAssertEqual(job.overallProgress, 1.75 / 4, accuracy: 0.0001)
        job.report(1, 0.2)
        XCTAssertEqual(job.active[1]?.progress ?? 0, 0.5, accuracy: 0.0001)
        job.report(3, 0.9)
        XCTAssertNil(job.active[3]?.progress)
        XCTAssertEqual(JobCenter.parallelLimit(hardwareVideo: true), 1)
        XCTAssertTrue((2...4).contains(JobCenter.parallelLimit(hardwareVideo: false)))
    }

    func testSubtitleRoundTrip() {
        let cues = SubtitleConverter.parseSRT("1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n01:02:03,004 --> 01:02:04,000\nBye\n")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].start, 3723.004, accuracy: 0.0001)
        let vtt = SubtitleConverter.vtt(cues)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertEqual(SubtitleConverter.parseVTT(vtt), cues)
    }

    func testPDFRangeParsing() throws {
        XCTAssertEqual(try PDFTools.parseRanges("1-2, 4, 5-", pageCount: 6), [0...1, 3...3, 4...5])
        XCTAssertThrowsError(try PDFTools.parseRanges("3-2", pageCount: 6))
        XCTAssertThrowsError(try PDFTools.parseRanges("7", pageCount: 6))
    }

    func testMarkdownStructure() {
        var reader = MarkdownReader(baseURL: nil)
        let doc = reader.parse("# Title\n\nText with **bold** and *it*.\n\n- a\n- b\n\n1. one\n\n| A | B |\n|---|---|\n| 1 | 2 |\n")
        guard doc.blocks.count >= 6 else { return XCTFail("blocks: \(doc.blocks)") }
        if case .heading(let level, _) = doc.blocks[0] { XCTAssertEqual(level, 1) } else { XCTFail() }
        if case .paragraph(let p) = doc.blocks[1] { XCTAssertTrue(p.runs.contains { $0.bold && $0.text == "bold" }) } else { XCTFail() }
        XCTAssertTrue(doc.blocks.contains { if case .table(let t) = $0 { return t.rows.count == 2 } else { return false } })
    }

    func testZipRoundTrip() throws {
        var writer = ZipWriter()
        try writer.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        try writer.add("a/b.txt", Data(String(repeating: "hello ", count: 1000).utf8))
        let archive = try ZipArchive(data: writer.finish())
        XCTAssertEqual(archive.entries.first?.name, "mimetype")
        XCTAssertEqual(archive.entries.first?.method, 0)
        XCTAssertEqual(try archive.readString("a/b.txt").count, 6000)
    }

    func testCraftedZipSizesThrowInsteadOfCrashing() throws {
        var writer = ZipWriter()
        try writer.add("a.txt", Data("hello".utf8))
        var data = writer.finish()
        // Mark the central entry's sizes and offset as ZIP64 and supply absurd 64-bit values.
        let central = data.count - 22 - (46 + 5)
        for field in [20, 24, 42] { data.replaceSubrange((central + field)..<(central + field + 4), with: [0xFF, 0xFF, 0xFF, 0xFF]) }
        data.replaceSubrange((central + 30)..<(central + 32), with: [28, 0])
        var extra = Data([0x01, 0x00, 24, 0])
        for _ in 0..<3 { extra.append(contentsOf: [UInt8](repeating: 0xFF, count: 8)) }
        data.insert(contentsOf: extra, at: central + 46 + 5)
        data.replaceSubrange((data.count - 10)..<(data.count - 6), with: [UInt8(46 + 5 + 28), 0, 0, 0])
        do {
            let archive = try ZipArchive(data: data)
            _ = try? archive.read("a.txt")
        } catch {}
        XCTAssertTrue(true, "reached without trapping")
    }

    func testLenientOptionDecoding() throws {
        let options = try JSONDecoder().decode(ToolOptions.Compress.self, from: Data(#"{"mode":"fileSize"}"#.utf8), defaults: .init())
        XCTAssertEqual(options.mode, .fileSize)
        XCTAssertEqual(options.strength, .balanced)
    }

    func testPDFImageResolutionOption() throws {
        XCTAssertEqual(ConversionOptions().pdfImageDPI, 150)
        // Settings saved before the option existed still decode, at the default.
        let stored = try JSONDecoder().decode(ConversionOptions.self, from: Data(#"{"quality":"high"}"#.utf8), defaults: ConversionOptions())
        XCTAssertEqual(stored.pdfImageDPI, 150)
        XCTAssertTrue(ConversionSetting.applicable(to: .jpg).contains(.pdfImageDPI))
        XCTAssertTrue(ConversionSetting.applicable(to: .png).contains(.pdfImageDPI))
        XCTAssertFalse(ConversionSetting.applicable(to: .webp).contains(.pdfImageDPI))
    }

    func testRecentResultsKeepNewestTenThatExist() throws {
        RecentResults.store = UserDefaults(suiteName: UUID().uuidString)!
        defer { RecentResults.store = .standard }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try (0..<12).map { i -> URL in
            let url = dir.appendingPathComponent("\(i).txt")
            try Data().write(to: url)
            return url
        }
        RecentResults.add(Array(files[0..<6]))
        RecentResults.add(Array(files[6..<12]))
        XCTAssertEqual(RecentResults.urls.map(\.lastPathComponent), (2..<12).reversed().map { "\($0).txt" })
        RecentResults.add([files[5]])
        XCTAssertEqual(RecentResults.urls.first, files[5])
        XCTAssertEqual(RecentResults.urls.count, 10)
        try FileManager.default.removeItem(at: files[11])
        XCTAssertFalse(RecentResults.urls.contains(files[11]))
        RecentResults.clear()
        XCTAssertTrue(RecentResults.urls.isEmpty)
    }

    func testSaveFolderFallsBackToOriginalThenDownloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chosen = dir.appendingPathComponent("Chosen"), originals = dir.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = originals.appendingPathComponent("a.png")
        XCTAssertEqual(Publisher.destinationDirectory(for: source).path, originals.path)
        XCTAssertEqual(Publisher.$folder.withValue(chosen) { Publisher.destinationDirectory(for: source) }.path, chosen.path)
        let missing = dir.appendingPathComponent("Gone")
        XCTAssertEqual(Publisher.$folder.withValue(missing) { Publisher.destinationDirectory(for: source) }.path, originals.path)
        let readOnly = URL(fileURLWithPath: "/System/Library/a.png")
        XCTAssertEqual(Publisher.destinationDirectory(for: readOnly).lastPathComponent, "Downloads")
    }

    func testToolMemoryRemembersPerToolAndVariant() {
        ToolMemory.store = UserDefaults(suiteName: UUID().uuidString)!
        defer { ToolMemory.store = .standard }
        XCTAssertFalse(ToolMemory.isStored(.compress, variant: "images"))
        ToolMemory.save(ToolOptions.Compress(mode: .percentage, reduction: 70), for: .compress, variant: "images")
        XCTAssertEqual(ToolMemory.load(.compress, variant: "images", default: ToolOptions.Compress()).reduction, 70)
        XCTAssertEqual(ToolMemory.load(.compress, variant: "video", default: ToolOptions.Compress()).reduction, 50)
        // Plain values and fields added after saving.
        ToolMemory.save(true, for: .removeMetadata)
        XCTAssertTrue(ToolMemory.load(.removeMetadata, default: false))
        ToolMemory.store.set(Data(#"{"factor":3}"#.utf8), forKey: "toolSettings.changeVideoSpeed")
        let speed = ToolMemory.load(.changeVideoSpeed, default: ToolOptions.Speed())
        XCTAssertEqual(speed.factor, 3)
        XCTAssertTrue(speed.preservePitch)
        ToolMemory.forget(.compress, variant: "images")
        XCTAssertEqual(ToolMemory.load(.compress, variant: "images", default: ToolOptions.Compress()).reduction, 50)
    }

    func testPresetsMatchTheirFiles() throws {
        let instagram = try XCTUnwrapPreset("Instagram 1080 px JPG"), email = try XCTUnwrapPreset("Email-size MP4 (under 25 MB)")
        let photo = URL(fileURLWithPath: "/x/a.jpg"), heic = URL(fileURLWithPath: "/x/b.heic"), movie = URL(fileURLWithPath: "/x/c.mov")
        XCTAssertTrue(instagram.applies(to: [photo, heic]))
        XCTAssertFalse(instagram.applies(to: [movie]))
        XCTAssertTrue(email.applies(to: [movie]))
        XCTAssertFalse(email.applies(to: [photo]))
        XCTAssertTrue(Preset.reencodes(.jpg, to: .jpg))
        XCTAssertFalse(Preset.reencodes(.docx, to: .docx))
        XCTAssertEqual(instagram.conversionOptions.imageMaxWidth, 1080)
        XCTAssertEqual(email.decoded(ToolOptions.Compress()).videoFormat, .mp4)
        // A preset saved before a field existed still decodes.
        let old = try JSONDecoder().decode(Preset.self, from: Data(#"{"name":"Old","label":"OLD","target":"png","options":"{}"}"#.utf8), defaults: Preset(name: "", label: ""))
        XCTAssertTrue(old.showOnWheel)
        XCTAssertEqual(old.conversionOptions.pdfImageDPI, 150)
        XCTAssertEqual(Preset.defaults.map(\.id).count, Set(Preset.defaults.map(\.id)).count)
    }

    private func XCTUnwrapPreset(_ name: String) throws -> Preset {
        guard let preset = Preset.named(name, in: []) else { throw WheelError("missing preset \(name)") }
        return preset
    }

    func testWatchFoldersSkipHiddenPartialAndOwnFiles() {
        XCTAssertTrue(FolderWatcher.isCandidate(URL(fileURLWithPath: "/x/photo.jpg")))
        XCTAssertFalse(FolderWatcher.isCandidate(URL(fileURLWithPath: "/x/.photo.jpg")))
        XCTAssertFalse(FolderWatcher.isCandidate(URL(fileURLWithPath: "/x/.wheelconvert-1234-photo.jpg")))
        XCTAssertFalse(FolderWatcher.isCandidate(URL(fileURLWithPath: "/x/movie.mp4.crdownload")))
        XCTAssertFalse(FolderWatcher.isCandidate(URL(fileURLWithPath: "/x/movie.mp4.part")))
        let result = URL(fileURLWithPath: "/x/photo 2.jpg")
        XCTAssertTrue(FolderWatcher.isCandidate(result))
        OutputLedger.record(result)
        XCTAssertFalse(FolderWatcher.isCandidate(result))
    }

    func testDitheringRemovesGradientBanding() throws {
        let width = 600, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.6, alpha: 1), CGColor(srgbRed: 0.95, green: 0.55, blue: 0.3, alpha: 1)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!,
                                   start: .zero, end: CGPoint(x: width, y: height / 3), options: [])
        let image = context.makeImage()!
        let original = try PNGQuantizer.pixels(image)
        // Banding shows as the 8×8-block average drifting from the original.
        func blockError(_ data: Data) throws -> Double {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let pixels = try PNGQuantizer.pixels(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
            var total = 0.0, count = 0.0
            for by in stride(from: 0, to: height - 8, by: 8) { for bx in stride(from: 0, to: width - 8, by: 8) { for c in 0..<3 {
                var a = 0, b = 0
                for y in by..<(by + 8) { for x in bx..<(bx + 8) { a += Int(original[(y * width + x) * 4 + c]); b += Int(pixels[(y * width + x) * 4 + c]) } }
                total += abs(Double(a - b)) / 64; count += 1
            } } }
            return total / count
        }
        let plain = try PNGQuantizer.encode(image, colors: 64, dither: false), dithered = try PNGQuantizer.encode(image, colors: 64)
        XCTAssertTrue(try blockError(dithered) < blockError(plain) * 0.6, "dithering should flatten the bands")
        // Worst case: a noise-free synthetic gradient at 64 colors. Photos grow 0–20%.
        XCTAssertTrue(dithered.count < plain.count * 3, "dithered \(dithered.count) vs plain \(plain.count)")
    }

    func testMarkdownLinksImagesInAFolder() {
        var doc = StructuredDocument()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        doc.blocks = [.paragraph(.init(runs: [.init("Hi")])), .image(.init(data: png, alt: "A (chart)")), .image(.init(data: Data([0xFF, 0xD8, 0xFF, 0xE0])))]
        var writer = MarkdownWriter(imageFolder: "Report (final) images")
        let text = writer.write(doc)
        XCTAssertTrue(text.contains("![A (chart)](Report%20%28final%29%20images/image-001.png)"), text)
        XCTAssertTrue(text.contains("](Report%20%28final%29%20images/image-002.jpg)"), text)
        XCTAssertFalse(text.contains("data:"))
        XCTAssertEqual(writer.images.map(\.name), ["image-001.png", "image-002.jpg"])
    }

    func testPalmDOCAndTrailingEntries() {
        // "ab", a space+"c" pair, then a back reference 4 bytes back, 4 long (0b10, distance 4, length 4 − 3).
        XCTAssertEqual(MOBIReader.palmDOC([0x02, 0x61, 0x62, 0xE3, 0x80, 0x21]), Array("ab cab c".utf8))
        // A 3-byte entry (its size byte 0x83 is last), then the split-character byte (low bits 0: just itself).
        XCTAssertEqual(MOBIReader.trailingSize(Array("text".utf8) + [0xA8, 0x00, 0x09, 0x83], flags: 0b11), 4)
    }

    /// A Palm database holding the given records, as Kindle books are stored.
    private func palmDatabase(_ records: [[UInt8]], type: String = "BOOKMOBI") -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 78)
        bytes.replaceSubrange(60..<68, with: Array(type.utf8))
        bytes[76] = UInt8(records.count >> 8); bytes[77] = UInt8(records.count & 0xFF)
        var offset = 78 + 8 * records.count
        for record in records {
            bytes += withUnsafeBytes(of: UInt32(offset).bigEndian, Array.init) + [0, 0, 0, 0]
            offset += record.count
        }
        return bytes + records.flatMap { $0 }
    }

    func testHuffCDICDecodesPhrasesAndNestedPhrases() throws {
        func be32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).bigEndian, Array.init) }
        // Every 8-bit code is a terminal code whose phrase is the byte itself (phrase 255 - byte)…
        var huff = Array("HUFF".utf8) + be32(0x18) + be32(24) + be32(24 + 1024) + [UInt8](repeating: 0, count: 8)
        for _ in 0..<256 { huff += be32(255 << 8 | 0x80 | 8) }
        huff += [UInt8](repeating: 0, count: 256)
        var cdic = Array("CDIC".utf8) + be32(0x10) + be32(256) + be32(8)
        var entries: [UInt8] = []
        for k in 0..<256 {
            cdic += [UInt8((512 + entries.count) >> 8), UInt8((512 + entries.count) & 0xFF)]
            // …except "A", whose phrase is itself compressed and expands to "BC".
            entries += k == 255 - 0x41 ? [0x00, 0x02, 0x42, 0x43] : [0x80, 0x01, UInt8(255 - k)]
        }
        cdic += entries
        let database = try MOBIReader.PalmDatabase(palmDatabase([[0], huff, cdic]))
        var decoder = try MOBIReader.HuffCDIC(database, first: 1, count: 2)
        XCTAssertEqual(try decoder.unpack(Array("Hi A!".utf8)), Array("Hi BC!".utf8))
    }

    func testPalmDOCCompressionRoundTrips() {
        var random = SystemRandomNumberGenerator()
        let samples: [[UInt8]] = [
            [], Array("a".utf8), Array("  a b c".utf8),
            Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 90).utf8.prefix(4096)),
            Array(String(repeating: "Grüße 日本語 😀 Ελληνικά ", count: 120).utf8.prefix(4096)),
            (0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) },
            [UInt8](repeating: 0x01, count: 40) + [UInt8](repeating: 0x80, count: 17) + [0x20, 0x41, 0x20, 0x20, 0x7F, 0x20, 0x00],
        ]
        for sample in samples {
            let packed = MOBIWriter.palmDOC(sample)
            XCTAssertEqual(MOBIReader.palmDOC(packed), sample, "\(sample.count) bytes")
        }
        XCTAssertTrue(MOBIWriter.palmDOC(samples[3]).count < samples[3].count / 3, "repetitive text should compress")
    }

    func testMOBIBooksReadBack() throws {
        let width = 40, height = 30
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var doc = StructuredDocument(title: "Über Bücher", author: "Ada Example", language: "de")
        let long = String(repeating: "Grüße aus Köln, 日本語, emoji 😀. ", count: 300)
        var noted = StructuredDocument.Run("Noted")
        noted.note = "A footnote"
        doc.blocks = [.image(.init(data: ImageSniffer.png(context.makeImage()!)!, alt: "Cover")),
                      .heading(level: 1, runs: [.init("Erstes Kapitel")]), .paragraph(.init(runs: [.init(long)])),
                      .heading(level: 2, runs: [.init("Zweites Kapitel")]), .paragraph(.init(runs: [noted, .init(" and "), .init("a link", link: "#missing")]))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobi")
        try MOBIWriter.write(doc).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try MOBIReader.read(url)
        XCTAssertEqual(read.title, "Über Bücher")
        XCTAssertEqual(read.author, "Ada Example")
        XCTAssertEqual(read.language, "de")
        let text = read.blocks.map(\.plainText).joined(separator: "\n")
        XCTAssertTrue(text.contains(long.trimmingCharacters(in: .whitespaces)), "multibyte text across records")
        XCTAssertTrue(text.contains("Zweites Kapitel") && text.contains("A footnote") && text.contains("a link"))
        guard case .image(let cover) = read.blocks.first else { return XCTFail("cover first") }
        XCTAssertEqual(ImageSniffer.mime(cover.data), "image/jpeg")
        // Every text record holds at most 4096 bytes once its trailing entries are removed.
        let database = try MOBIReader.PalmDatabase([UInt8](try Data(contentsOf: url)))
        let book = try MOBIReader.Book(database, base: 0)
        for index in 1...book.textRecords {
            var record = database.record(index)
            record.removeLast(MOBIReader.trailingSize(record, flags: book.extraFlags))
            XCTAssertTrue(MOBIReader.palmDOC(record).count <= 4096)
        }
        XCTAssertTrue(book.cover() != nil)
        XCTAssertTrue(ConversionMatrix.outputs(for: .docx).contains(.mobi))
        XCTAssertTrue(ConversionMatrix.outputs(for: .pdf).contains(.mobi))
        XCTAssertFalse(FileFormat.mobi.isInputOnly)
    }

    func testHTMLWithoutCharsetKeepsItsText() {
        let blocks = HTMLReader { _ in nil }.parse(Data("<html><body><p>Grüße 日本 😀<br></p></body></html>".utf8))
        XCTAssertEqual(blocks.map(\.plainText).joined().trimmingCharacters(in: .whitespacesAndNewlines), "Grüße 日本 😀")
    }

    func testKindleBooksWithDRMAreRefusedPlainly() throws {
        var record0 = [UInt8](repeating: 0, count: 0x110)
        record0[0] = 0; record0[1] = 2        // PalmDOC compression
        record0[13] = 2                       // Mobipocket encryption
        record0.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".azw")
        try Data(palmDatabase([record0, Array("text".utf8)])).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try MOBIReader.read(url))
        do { _ = try MOBIReader.read(url) } catch { XCTAssertTrue(error.localizedDescription.contains("DRM")) }
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/book.azw3")), .mobi)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/x/book.epub")), .epub)
        XCTAssertTrue(ConversionMatrix.outputs(for: .mobi).contains(.kindle))
    }

    func testModeMatchingIsExact() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(settings.mode(for: [.shift]), .convert)
        XCTAssertEqual(settings.mode(for: [.command]), .tools)
        XCTAssertNil(settings.mode(for: [.shift, .command]))
        XCTAssertNil(settings.mode(for: []))
    }
}
