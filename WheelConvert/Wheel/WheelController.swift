import AppKit
import OSLog

/// Borderless panel that never activates the app, so the drag source keeps focus. Opened from the
/// Finder menu it takes key status (still without activating) so Escape can close it.
final class WheelPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// Shows the wheel under the pointer during a drag and reports the chosen petal.
final class WheelController {
    /// Debug-level, so nothing is stored unless someone streams it (`log stream --level debug`).
    private static let log = Logger(subsystem: "app.wheelconvert", category: "wheel")
    var onChoose: ((WheelItem, DragContent) -> Void)?

    private let panel: WheelPanel
    private let wheel: WheelView
    private(set) var mode: WheelMode?
    private var content: DragContent?
    private var outsideClicks: Any?

    init() {
        let size = WheelView.diameter(for: 8)
        panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        wheel = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = wheel
        wheel.onDrop = { [weak self] item, content in
            self?.dismiss()
            self?.onChoose?(item, content)
        }
        wheel.onClick = { [weak self] item in
            guard let self, let content = self.content else { return }
            self.dismiss()
            if let item { self.onChoose?(item, content) }
        }
        // A click anywhere else takes key status away: treat it like Escape.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            if self?.wheel.clickMode == true { self?.dismiss() }
        }
    }

    var isVisible: Bool { panel.isVisible }
    /// Visible and following a drag (not opened from the Finder menu).
    var isOpenForDrag: Bool { panel.isVisible && !wheel.clickMode }
    var isDragInside: Bool { panel.isVisible && wheel.isDragInside }

    /// Opens (or switches) the wheel for what is dragged, centered on the pointer.
    /// - Parameter byClick: opened from the Services menu; petals are chosen by clicking instead of dropping.
    func show(mode: WheelMode, content: DragContent, byClick: Bool = false) {
        let sameContent = panel.isVisible && self.mode == mode && self.content == content && wheel.clickMode == byClick
        guard !sameContent else { return }
        let wasVisible = panel.isVisible
        self.mode = mode
        self.content = content
        let (items, idle) = WheelItem.items(for: mode, content: content)
        Self.log.debug("Wheel \(mode.rawValue, privacy: .public): \(items.map(\.id).joined(separator: " "), privacy: .public)")
        let size = WheelView.diameter(for: items.count)
        var frame = panel.frame
        if !wasVisible {
            let pointer = NSEvent.mouseLocation
            frame = NSRect(x: pointer.x - size / 2, y: pointer.y - size / 2, width: size, height: size)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main {
                let visible = screen.visibleFrame.insetBy(dx: -WheelView.margin, dy: -WheelView.margin)
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size)
            }
        } else {
            // Switching wheels keeps the same center.
            frame = NSRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
        }
        panel.setFrame(frame, display: false)
        wheel.frame = NSRect(origin: .zero, size: frame.size)
        wheel.configure(items: items, idleText: idle, content: content)
        wheel.clickMode = byClick
        panel.acceptsKey = byClick
        if byClick {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(wheel)
            // Clicks in other apps never reach this panel; they close the wheel like clicking away from a menu.
            if outsideClicks == nil {
                outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
            }
        } else {
            panel.orderFrontRegardless()
        }
        // Switching wheels swaps the petals in place; animating it would show both wheels at once.
        if !wasVisible { wheel.animateIn() }
    }

    func dismiss() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        guard panel.isVisible else { return }
        wheel.clickMode = false
        panel.orderOut(nil)
        mode = nil
        content = nil
    }
}
