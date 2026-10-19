// End-to-end driver: shows a draggable file, then synthesizes a real drag with a modifier tap,
// moves onto a petal and drops — the same input a person produces.
// usage: swift DragDriver.swift <file> <modifier: shift|command|control> <petal index> <petal count> [screenshot path]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let file = URL(fileURLWithPath: args[1])
let modifier = args[2]
let petal = Int(args[3])!
let count = Int(args[4])!
let shot = args.count > 5 ? args[5] : nil

final class SourceView: NSView, NSDraggingSource {
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 60, dy: 60), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .generic] }
    override func draw(_ dirtyRect: NSRect) { NSColor.systemTeal.setFill(); bounds.fill() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!.frame
let panel = NSPanel(contentRect: NSRect(x: screen.midX - 400, y: screen.midY - 100, width: 200, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.contentView = SourceView()
panel.orderFrontRegardless()

let src = CGEventSource(stateID: .hidSystemState)
func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: screen.height - p.y) } // Cocoa → CG (top-left) coordinates
func post(_ type: CGEventType, _ p: NSPoint, flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: cg(p), mouseButton: .left)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.type = .flagsChanged
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    var p = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    post(.mouseMoved, p); pause(0.15)
    post(.leftMouseDown, p); pause(0.15)
    for _ in 0..<12 { p.x += 8; post(.leftMouseDragged, p); pause(0.03) }
    pause(0.3)
    let (code, flag): (CGKeyCode, CGEventFlags) = modifier == "command" ? (55, .maskCommand) : modifier == "control" ? (59, .maskControl) : (56, .maskShift)
    key(code, down: true, flags: flag); pause(0.15)
    for _ in 0..<3 { post(.leftMouseDragged, p, flags: flag); pause(0.03) }
    key(code, down: false, flags: []); pause(0.6)
    // The wheel is centered where it opened; walk onto the requested petal's middle.
    let center = p
    let midRadius: CGFloat = (56 + (count <= 8 ? 132 : min(176, 132 + CGFloat(count - 8) * 9))) / 2 + 4
    let angle = CGFloat.pi / 2 - CGFloat(petal) * 2 * .pi / CGFloat(count)
    let target = NSPoint(x: center.x + midRadius * cos(angle), y: center.y + midRadius * sin(angle))
    for step in 1...15 {
        let t = CGFloat(step) / 15
        post(.leftMouseDragged, NSPoint(x: center.x + (target.x - center.x) * t, y: center.y + (target.y - center.y) * t)); pause(0.03)
    }
    pause(0.4)
    if let shot { _ = try? Process.run(URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments: ["-x", shot]).waitUntilExit() }
    post(.leftMouseUp, target); pause(0.5)
    exit(0)
}
app.run()
