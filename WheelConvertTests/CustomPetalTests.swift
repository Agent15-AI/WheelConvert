import AppKit
import XCTest
@testable import WheelConvert

final class CustomPetalTests: XCTestCase {
    private func petal(_ change: (inout CustomPetal) -> Void) -> CustomPetal {
        var petal = CustomPetal(name: "Test", kind: .shell, script: "true")
        change(&petal)
        return petal
    }

    func testWhichContentAPetalTakes() {
        let pdf = URL(fileURLWithPath: "/tmp/a.PDF"), png = URL(fileURLWithPath: "/tmp/b.png")
        let files = petal { $0.acceptsFiles = true; $0.extensions = " .pdf, md " }
        XCTAssertEqual(files.extensionList, ["pdf", "md"])
        XCTAssertTrue(files.accepts(.files([pdf])))
        XCTAssertFalse(files.accepts(.files([pdf, png])))
        XCTAssertFalse(files.accepts(.text("x", rich: nil)))
        let pictures = petal { $0.acceptsFiles = false; $0.acceptsPictures = true }
        XCTAssertTrue(pictures.accepts(.files([png])) && pictures.accepts(.image(type: .png, name: "a.png")))
        XCTAssertFalse(pictures.accepts(.files([pdf])))
        let text = petal { $0.acceptsFiles = false; $0.acceptsText = true; $0.acceptsLinks = true }
        XCTAssertTrue(text.accepts(.text("x", rich: nil)) && text.accepts(.link(URL(string: "https://a.example")!)))
        XCTAssertFalse(petal { $0.showOnWheel = false }.accepts(.files([pdf])))
        XCTAssertFalse(petal { $0.script = "  \n" }.accepts(.files([pdf])), "an empty script never shows")
        XCTAssertFalse(petal { $0.name = "" }.accepts(.files([pdf])))
    }

    func testChangingTheActionNeedsApprovalAgain() {
        var p = petal { _ in }
        XCTAssertTrue(p.needsApproval)
        p.approved = p.actionDescription
        XCTAssertFalse(p.needsApproval)
        p.script = "rm -rf ~"
        XCTAssertTrue(p.needsApproval)
        p.approved = p.actionDescription
        p.timeoutSeconds = 5
        XCTAssertTrue(p.needsApproval, "the time limit is part of what was approved")
        p.approved = p.actionDescription
        p.kind = .urlScheme
        XCTAssertTrue(p.needsApproval)
    }

    func testURLTemplatesEncodeTheItem() {
        let url = CustomPetal.url(from: "things:///add?title={text}&when=today", path: "", text: "Buy milk & eggs#1 ?x=y", link: "")
        XCTAssertEqual(url?.absoluteString, "things:///add?title=Buy%20milk%20%26%20eggs%231%20%3Fx%3Dy&when=today")
        XCTAssertEqual(CustomPetal.url(from: "myapp://open?p={path}", path: "/a b/ü", text: "", link: "")?.absoluteString, "myapp://open?p=%2Fa%20b%2F%C3%BC")
        XCTAssertNil(CustomPetal.url(from: "file:///etc/{path}", path: "x", text: "", link: ""))
        XCTAssertNil(CustomPetal.url(from: "JavaScript:alert({text})", path: "", text: "x", link: ""))
        XCTAssertNil(CustomPetal.url(from: "{text}", path: "", text: "javascript:alert(1)", link: ""), "the item can't supply the scheme")
        XCTAssertNil(CustomPetal.scheme(of: "no scheme here"))
    }

    func testScriptsGetOnlyALoginEnvironment() {
        let environment = CustomRunner.environment(from: ["HOME": "/Users/x", "USER": "x", "API_TOKEN": "secret", "DYLD_INSERT_LIBRARIES": "/x.dylib", "LANG": "en_US.UTF-8"])
        XCTAssertEqual(environment["HOME"], "/Users/x")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["API_TOKEN"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    func testResultTypes() throws {
        XCTAssertEqual(CustomRunner.fileExtension(for: Data("hello\n".utf8)), "txt")
        XCTAssertEqual(CustomRunner.fileExtension(for: Data("%PDF-1.7".utf8)), "pdf")
        XCTAssertEqual(CustomRunner.fileExtension(for: try Data(contentsOf: PracticeFile.url)), "png")
        XCTAssertEqual(CustomRunner.fileExtension(for: Data([0xFF, 0xFE, 0x00, 0x81])), "data")
    }

    func testOlderSavedPetalsFillNewFields() throws {
        let saved = Data(#"{"id":"6C3F1D0E-1A51-4C6B-9C1B-0D2F5B6A00FF","name":"Old","kind":"shell","script":"echo"}"#.utf8)
        let petal = try JSONDecoder().decode(CustomPetal.self, from: saved, defaults: CustomPetal())
        XCTAssertEqual(petal.name, "Old")
        XCTAssertEqual(petal.timeoutSeconds, 120)
        XCTAssertTrue(petal.needsApproval)
        let label = CustomPetal(name: "Rocket launcher", icon: "🚀")
        XCTAssertEqual(label.wheelLabel, "🚀 ROCKET LAUNC")
        XCTAssertNil(label.symbol)
        XCTAssertEqual(CustomPetal(name: "x", icon: "star").symbol, "star")
    }
}
