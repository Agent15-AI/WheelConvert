import AppKit
import XCTest
@testable import WheelConvert

final class SmartTests: XCTestCase {
    private func pasteboard(_ items: [NSPasteboard.PasteboardType: Data]) -> NSPasteboard {
        let board = NSPasteboard(name: .init("WheelConvertTests-\(UUID().uuidString)"))
        board.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in items { item.setData(data, forType: type) }
        board.writeObjects([item])
        return board
    }

    func testBrowserPictureWinsOverItsAddress() throws {
        // What Safari and Chrome put on the drag pasteboard for an image (see the decisions doc).
        let png = try Data(contentsOf: PracticeFile.url)
        let board = pasteboard([.png: png, .URL: Data("https://example.com/photos/cat.png?w=200".utf8), .string: Data("https://example.com/photos/cat.png".utf8)])
        XCTAssertEqual(DragContent.read(board), .image(type: .png, name: "cat.png"))
        let saved = try XCTUnwrap(try DragContent.read(board)?.materialized(from: board).files.first)
        defer { try? FileManager.default.removeItem(at: saved.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: saved), png)
        XCTAssertTrue(DragContent.isScratch(saved.deletingLastPathComponent()))
        // Results of a dropped picture never land in the private folder.
        XCTAssertEqual(Publisher.destinationDirectory(for: saved).lastPathComponent, "Downloads")
        XCTAssertEqual(Publisher.destinationDirectory(for: nil).lastPathComponent, "Downloads")
    }

    func testLinksTextAndFiles() {
        XCTAssertEqual(DragContent.read(pasteboard([.URL: Data("https://example.com/a?utm_source=x".utf8), .string: Data("Example".utf8)])),
                       .link(URL(string: "https://example.com/a?utm_source=x")!))
        XCTAssertEqual(DragContent.read(pasteboard([.string: Data("  https://example.com/b \n".utf8)])), .link(URL(string: "https://example.com/b")!))
        XCTAssertEqual(DragContent.read(pasteboard([.string: Data("see https://example.com".utf8)])), .text("see https://example.com", rich: nil))
        let rtf = Data(#"{\rtf1 Hello}"#.utf8)
        XCTAssertEqual(DragContent.read(pasteboard([.string: Data("Hello".utf8), .rtf: rtf])), .text("Hello", rich: .init(data: rtf, isHTML: false)))
        XCTAssertNil(DragContent.read(pasteboard([.string: Data(" \n\t".utf8)])))
        XCTAssertEqual(DragContent.read(pasteboard([.string: Data("javascript:alert(1)".utf8), .URL: Data("javascript:alert(1)".utf8)])), .text("javascript:alert(1)", rich: nil))
        XCTAssertNil(DragContent.webLink("file:///etc/passwd"))
        XCTAssertNil(DragContent.webLink("https://"))
        let file = URL(fileURLWithPath: "/tmp/a b.txt")
        let board = NSPasteboard(name: .init("WheelConvertTests-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([file as NSURL])
        XCTAssertEqual(DragContent.read(board), .files([file]))
    }

    func testCleanLinksExactly() {
        let cases = [
            ("https://example.com/page?utm_source=news&id=7&fbclid=XYZ", "https://example.com/page?id=7"),
            ("https://example.com/?UTM_Medium=a&gclid=1&q=a%20b#top", "https://example.com/?q=a%20b#top"),
            ("https://shop.example/p?utm_campaign=x", "https://shop.example/p"),
            ("https://example.com/p?ref=keep&msclkid=9&igshid=3&mc_eid=4", "https://example.com/p?ref=keep"),
            ("https://example.com/p", "https://example.com/p"),
            ("https://example.com/p?a=1&a=2&utm_term=z", "https://example.com/p?a=1&a=2"),
        ]
        for (input, expected) in cases { XCTAssertEqual(LinkCleaner.clean(URL(string: input)!).absoluteString, expected, input) }
    }

    func testTextTools() {
        XCTAssertEqual(TextTools.quoted("one\n\ntwo\n"), "> one\n>\n> two")
        XCTAssertEqual(TextTools.counts("Hello, world! 👋🏽"), .init(words: 2, characters: 15, lines: 1))
        XCTAssertEqual(TextTools.counts("東京は晴れです").words > 1, true) // no spaces, still several words
        XCTAssertEqual(TextTools.counts("مرحبا بالعالم").words, 2)
        XCTAssertEqual(TextTools.counts("").lines, 0)
        XCTAssertEqual(TextTools.fileName("  \n"), "Text")
        XCTAssertEqual(TextTools.fileName("a/b: c\nsecond"), "a-b- c")
        XCTAssertEqual(TextTools.fileName(String(repeating: "x", count: 100)), String(repeating: "x", count: 40) + "…")
        let html = DragContent.RichText(data: Data("<p>Some <b>bold</b> and <a href=\"https://example.com\">a link</a></p>".utf8), isHTML: true)
        XCTAssertEqual(TextTools.markdown(html), "Some **bold** and [a link](https://example.com)")
    }

    func testQRCodeCapacityAndRoundTrip() throws {
        XCTAssertFalse(QRCode.fits(""))
        XCTAssertTrue(QRCode.fits(String(repeating: "a", count: 2331)))
        XCTAssertFalse(QRCode.fits(String(repeating: "a", count: 2332)))
        XCTAssertFalse(QRCode.fits(String(repeating: "é", count: 1166))) // 2 bytes each
        XCTAssertThrowsError(try QRCode.png(String(repeating: "a", count: 3000)))
    }

    func testChecksums() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty"), abc = dir.appendingPathComponent("-abc \"q\"\nx.txt")
        try Data().write(to: empty)
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(try Checksum.hex(empty, .sha256), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try Checksum.hex(abc, .sha256), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Checksum.hex(abc, .md5), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try Checksum.hex(abc, .sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Checksum.expected(in: "SHA256 (x.dmg) = BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")?.algorithm, .sha256)
        XCTAssertEqual(Checksum.expected(in: "900150983cd24fb0d6963f7d28e17f72  abc.txt")?.hex, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Checksum.expected(in: "sha1:a9993e364706816aba3e25717850c26c9cd0d89d")?.algorithm, .sha1)
        XCTAssertNil(Checksum.expected(in: "not a checksum 12345"))
        XCTAssertNil(Checksum.expected(in: ""))
    }

    func testPetalsFitTheContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("notes.txt"), photo = dir.appendingPathComponent("photo.png")
        try Data("x".utf8).write(to: doc)
        try Data().write(to: photo)
        func ids(_ content: DragContent) -> [String] { WheelItem.items(for: .smart, content: content).items.map(\.id) }
        XCTAssertEqual(ids(.files([doc])), ["smart.sha256", "smart.md5", "smart.verifyChecksum", "smart.reveal", "action.copyPath", "smart.zip"])
        XCTAssertEqual(ids(.files([doc, photo])), ["smart.sha256", "smart.md5", "smart.reveal", "action.copyPath", "smart.zip"])
        XCTAssertEqual(ids(.files([dir])), ["smart.reveal", "action.copyPath", "smart.zip"])
        let pictures = ids(.files([photo]))
        XCTAssertEqual(pictures.count, SmartAction.petalLimit)
        XCTAssertTrue(pictures.contains("tool.extractText") && pictures.contains("tool.readQRCode") && pictures.contains("smart.palette"))
        XCTAssertEqual(pictures.contains("smart.removeBackground"), ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        XCTAssertFalse(ids(.image(type: .png, name: "a.png")).contains("smart.sha256"))
        let text = ids(.text("Hello", rich: nil))
        XCTAssertTrue(text.contains("smart.makeQRCode") && !text.contains("smart.copyMarkdown") && !text.contains("smart.summarize"))
        XCTAssertFalse(ids(.text(String(repeating: "word ", count: 3000), rich: nil)).contains("smart.makeQRCode"))
        XCTAssertTrue(ids(.text("Hi", rich: .init(data: Data(), isHTML: true))).contains("smart.copyMarkdown"))
        XCTAssertEqual(Array(ids(.link(URL(string: "https://example.com")!)).prefix(3)), ["smart.cleanLink", "smart.makeQRCode", "smart.saveLink"])
        // The other wheels still only open for files.
        XCTAssertTrue(WheelItem.items(for: .convert, content: .text("x", rich: nil)).items.isEmpty)
    }

    func testPrivateWindowArguments() {
        XCTAssertEqual(PrivateBrowsing.launchArguments(for: "com.google.Chrome"), "--incognito")
        XCTAssertEqual(PrivateBrowsing.launchArguments(for: "org.mozilla.firefox"), "-private-window")
        XCTAssertNil(PrivateBrowsing.launchArguments(for: "com.apple.Safari"))
        XCTAssertNil(PrivateBrowsing.launchArguments(for: nil))
    }

    func testSmartKeyDefaultsToOptionUnlessTaken() {
        let freshStore = UserDefaults(suiteName: UUID().uuidString)!
        let fresh = AppSettings(defaults: freshStore)
        XCTAssertEqual(fresh.modifiers(for: .smart), .option)
        XCTAssertNil(freshStore.object(forKey: "smartWheelModifiers")) // defaults stay defaults until changed
        XCTAssertEqual(fresh.mode(for: [.option]), .smart)
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        suite.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "toolsWheelModifiers")
        let upgraded = AppSettings(defaults: suite)
        XCTAssertEqual(upgraded.modifiers(for: .smart), [])
        XCTAssertEqual(upgraded.mode(for: [.option]), .tools)
    }
}
