import AppKit

/// Borderless panel that never activates the app, so the drag source keeps focus.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the wheel under the pointer during a drag and reports the chosen petal.
final class WheelController {
    var onChoose: ((WheelItem, [URL]) -> Void)?

    private let panel: WheelPanel
    private let wheel: WheelView
    private(set) var mode: WheelMode?
    private var urls: [URL] = []

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
        wheel.onDrop = { [weak self] item, urls in
            self?.dismiss()
            self?.onChoose?(item, urls)
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isDragInside: Bool { panel.isVisible && wheel.isDragInside }

    /// Opens (or switches) the wheel for these files, centered on the pointer.
    func show(mode: WheelMode, urls: [URL]) {
        let sameContent = panel.isVisible && self.mode == mode && self.urls == urls
        guard !sameContent else { return }
        let wasVisible = panel.isVisible
        self.mode = mode
        self.urls = urls
        let (items, idle) = WheelItem.items(for: mode, urls: urls)
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
        wheel.configure(items: items, idleText: idle)
        if !wasVisible { panel.alphaValue = 1 }
        panel.orderFrontRegardless()
        wheel.animateIn()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        mode = nil
        urls = []
    }
}
