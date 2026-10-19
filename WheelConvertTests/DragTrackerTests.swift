import AppKit
import XCTest
@testable import WheelConvert

final class DragTrackerTests: XCTestCase {
    private var tracker = DragTracker()
    private var now: TimeInterval = 0
    private var visible = false
    private var inside = false
    private let file = [URL(fileURLWithPath: "/tmp/photo.png")]

    private func mode(_ flags: NSEvent.ModifierFlags) -> WheelMode? {
        switch flags {
        case [.shift]: .convert
        case [.command]: .tools
        case [.control]: .actions
        case [.option, .shift]: .tools
        default: nil
        }
    }

    @discardableResult
    private func step(button: Bool, mods: NSEvent.ModifierFlags = [], escape: Bool = false, count: Int, files: [URL]? = nil) -> DragTracker.Effect? {
        now += 1.0 / 60
        let effect = tracker.update(.init(buttonDown: button, modifiers: mods, escapeDown: escape, changeCount: count), now: now,
                                    wheelVisible: visible, dragInsideWheel: inside, files: { files ?? file }, mode: mode)
        if case .show = effect { visible = true }
        if effect == .dismiss { visible = false }
        return effect
    }

    func testTapOpensAndLatchesUntilMouseUp() {
        step(button: false, count: 10)
        step(button: true, count: 10)           // mouse down, no drag yet
        XCTAssertNil(step(button: true, count: 11 - 1))
        step(button: true, count: 11)           // drag starts
        XCTAssertEqual(step(button: true, mods: [.shift], count: 11), .show(.convert, file))
        XCTAssertNil(step(button: true, count: 11)) // key released: stays open
        for _ in 0..<60 { XCTAssertNil(step(button: true, count: 11)) }
        inside = true
        step(button: false, count: 11)          // dropped inside: wheel handles it
        inside = false
        now += 1
        XCTAssertEqual(step(button: false, count: 11), .dismiss)
    }

    func testComboPressedBeforeDragOpensWhenDragStarts() {
        // Matches the original: a combination pressed with the button down latches before the drag begins.
        step(button: false, count: 10)
        step(button: true, count: 10)
        XCTAssertNil(step(button: true, mods: [.shift], count: 10))
        XCTAssertNil(step(button: true, count: 10))
        XCTAssertEqual(step(button: true, count: 11), .show(.convert, file))
    }

    func testHeldModifierAtMouseDownOpensWhenDragStarts() {
        step(button: false, mods: [.shift], count: 3)
        step(button: true, mods: [.shift], count: 3)
        XCTAssertEqual(step(button: true, mods: [.shift], count: 4), .show(.convert, file))
    }

    func testSwitchingCombinationSwitchesWheel() {
        step(button: false, count: 1)
        step(button: true, count: 1)
        step(button: true, count: 2)
        XCTAssertEqual(step(button: true, mods: [.shift], count: 2), .show(.convert, file))
        XCTAssertEqual(step(button: true, mods: [.shift, .option], count: 2), .show(.tools, file))
        XCTAssertEqual(step(button: true, mods: [.control], count: 2), .show(.actions, file))
    }

    func testEscapeDismissesAndClearsLatch() {
        step(button: false, count: 5)
        step(button: true, count: 5)
        step(button: true, count: 6)
        step(button: true, mods: [.command], count: 6)
        XCTAssertEqual(step(button: true, escape: true, count: 6), .dismiss)
        XCTAssertNil(step(button: true, count: 6))  // stays closed while Escape is held
        XCTAssertNil(step(button: true, count: 6))
    }

    func testDraggingTextNeverOpens() {
        step(button: false, count: 7)
        step(button: true, count: 7)
        XCTAssertNil(step(button: true, count: 8, files: []))
        XCTAssertNil(step(button: true, mods: [.shift], count: 8, files: []))
    }

    func testStaleDragPasteboardIsIgnored() {
        // The pasteboard changed long before this click; no drag is in progress.
        step(button: false, count: 20)
        step(button: true, count: 20)
        XCTAssertNil(step(button: true, mods: [.shift], count: 20))
    }

    func testReleasingOutsideDismissesAfterGrace() {
        step(button: false, count: 1)
        step(button: true, count: 1)
        step(button: true, count: 2)
        step(button: true, mods: [.shift], count: 2)
        XCTAssertNil(step(button: false, count: 2)) // grace period
        now += 0.4
        XCTAssertEqual(step(button: false, count: 2), .dismiss)
    }
}
