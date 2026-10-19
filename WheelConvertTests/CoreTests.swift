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

    func testModeMatchingIsExact() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(settings.mode(for: [.shift]), .convert)
        XCTAssertEqual(settings.mode(for: [.command]), .tools)
        XCTAssertNil(settings.mode(for: [.shift, .command]))
        XCTAssertNil(settings.mode(for: []))
    }
}
