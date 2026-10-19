import AppKit
import QuickLookUI

/// Manages the floating shelves ("Floats") that hold files for dragging elsewhere.
@MainActor
final class FloatController {
    static let shared = FloatController()
    private var floats: [FloatWindow] = []

    var hasFloats: Bool { !floats.isEmpty }

    func add(_ urls: [URL]) {
        if AppSettings.shared.floatBehavior == .addToExisting, let last = floats.last {
            last.add(urls)
            last.show()
            return
        }
        let float = FloatWindow(urls: urls) { [weak self] closed in self?.floats.removeAll { $0 === closed } }
        floats.append(float)
        float.show(near: NSEvent.mouseLocation)
    }

    func showAll() { floats.forEach { $0.show() } }
}

/// One shelf.
@MainActor
final class FloatWindow: NSObject, NSWindowDelegate {
    private let panel: FloatPanel
    private let itemsView: FloatItemsView
    private let header = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let modeButton = NSButton()
    private let collapsedView = NSStackView()
    private let collapsedIcon = NSImageView()
    private let collapsedCount = NSTextField(labelWithString: "")
    private let onClose: (FloatWindow) -> Void
    private var collapsed = false
    private var expandedFrame: NSRect?

    init(urls: [URL], onClose: @escaping (FloatWindow) -> Void) {
        self.onClose = onClose
        panel = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260), styleMask: [.borderless, .resizable, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        itemsView = FloatItemsView()
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 200, height: 150)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityLabel("Float")
        build()
        add(urls)
    }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        modeButton.bezelStyle = .accessoryBarAction
        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.setAccessibilityLabel("Switch between icons and list")
        let collapse = symbolButton("arrow.down.right.and.arrow.up.left", "Collapse Float", #selector(toggleCollapsed))
        let close = symbolButton("xmark.circle.fill", "Close Float without deleting files", #selector(closeFloat))
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        header.addArrangedSubview(countLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(modeButton)
        header.addArrangedSubview(collapse)
        header.addArrangedSubview(close)
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = itemsView
        itemsView.onChange = { [weak self] in self?.refresh() }
        itemsView.onEmpty = { [weak self] in self?.closeFloat() }

        collapsedView.orientation = .vertical
        collapsedView.alignment = .centerX
        collapsedView.spacing = 2
        collapsedIcon.imageScaling = .scaleProportionallyUpOrDown
        collapsedCount.font = .systemFont(ofSize: 11, weight: .bold)
        collapsedView.addArrangedSubview(collapsedIcon)
        collapsedView.addArrangedSubview(collapsedCount)
        collapsedView.isHidden = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleCollapsed))
        collapsedView.addGestureRecognizer(click)
        collapsedView.setAccessibilityLabel("Collapsed Float. Click to expand.")

        for view in [header, scroll, collapsedView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            collapsedView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            collapsedView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            collapsedIcon.widthAnchor.constraint(equalToConstant: 34),
            collapsedIcon.heightAnchor.constraint(equalToConstant: 34),
        ])
        panel.contentView = background
        panel.keyHandler = { [weak self] event in self?.itemsView.handleKey(event) ?? false }
    }

    private func symbolButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    func add(_ urls: [URL]) {
        itemsView.add(urls)
        refresh()
    }

    private func refresh() {
        let count = itemsView.urls.count
        countLabel.stringValue = count == 1 ? "1 item" : "\(count) items"
        modeButton.image = NSImage(systemSymbolName: itemsView.listMode ? "square.grid.2x2" : "list.bullet", accessibilityDescription: nil)
        collapsedCount.stringValue = "\(count)"
        if let first = itemsView.urls.first { collapsedIcon.image = NSWorkspace.shared.icon(forFile: first.path) }
    }

    func show(near point: NSPoint? = nil) {
        if let point, let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            var frame = panel.frame
            frame.origin = NSPoint(x: point.x + 24, y: point.y - frame.height / 2)
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
    }

    @objc private func toggleMode() {
        itemsView.listMode.toggle()
        refresh()
    }

    @objc func toggleCollapsed() {
        collapsed.toggle()
        header.isHidden = collapsed
        itemsView.enclosingScrollView?.isHidden = collapsed
        collapsedView.isHidden = !collapsed
        if collapsed {
            expandedFrame = panel.frame
            var frame = panel.frame
            frame.origin.y += frame.height - 72
            frame.size = NSSize(width: 64, height: 72)
            if let screen = panel.screen, abs(frame.maxX - screen.visibleFrame.maxX) < 40 { frame.origin.x = screen.visibleFrame.maxX - frame.width }
            panel.minSize = frame.size
            panel.setFrame(frame, display: true, animate: true)
        } else {
            panel.minSize = NSSize(width: 200, height: 150)
            var frame = expandedFrame ?? NSRect(x: panel.frame.minX, y: panel.frame.minY, width: 300, height: 260)
            if let screen = panel.screen {
                frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
            }
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    @objc func closeFloat() {
        panel.orderOut(nil)
        onClose(self)
    }

    /// Dragging the Float against a screen edge tucks it away once the mouse is released.
    func windowDidMove(_ notification: Notification) {
        guard !collapsed, isAtEdge, snapTimer == nil else { return }
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                self.snapTimer = nil
                if !self.collapsed && self.isAtEdge { self.toggleCollapsed() }
            }
        }
    }

    private var snapTimer: Timer?

    private var isAtEdge: Bool {
        guard let screen = panel.screen else { return false }
        let visible = screen.visibleFrame
        return panel.frame.minX <= visible.minX + 2 || panel.frame.maxX >= visible.maxX - 2
    }
}

final class FloatPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

/// Grid or list of files with selection, dragging, Quick Look and a context menu.
final class FloatItemsView: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var urls: [URL] = []
    private var selection: Set<Int> = []
    private var anchor: Int?
    var listMode = false { didSet { layoutItems() } }
    var onChange: (() -> Void)?
    var onEmpty: (() -> Void)?
    private var mouseDown: NSPoint?
    private var band: NSRect?
    private var typeBuffer = ""
    private var lastType = Date.distantPast

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Float files")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func add(_ new: [URL]) {
        for url in new where !urls.contains(url) { urls.append(url) }
        layoutItems()
    }

    // MARK: Layout

    private var cellSize: NSSize { listMode ? NSSize(width: max(180, bounds.width), height: 30) : NSSize(width: 92, height: 92) }

    private func frames() -> [NSRect] {
        let width = max(enclosingScrollView?.contentSize.width ?? 280, 120)
        let cell = listMode ? NSSize(width: width, height: 30) : NSSize(width: 92, height: 92)
        let columns = listMode ? 1 : max(1, Int(width / cell.width))
        let spacing = listMode ? 0 : (width - CGFloat(columns) * cell.width) / CGFloat(columns + 1)
        return urls.indices.map { i in
            let r = i / columns, c = i % columns
            return NSRect(x: spacing + CGFloat(c) * (cell.width + spacing), y: CGFloat(r) * (cell.height + (listMode ? 0 : 6)) + 4, width: cell.width, height: cell.height)
        }
    }

    func layoutItems() {
        urls.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        selection = selection.filter { $0 < urls.count }
        let width = enclosingScrollView?.contentSize.width ?? 280
        let height = (frames().last?.maxY ?? 0) + 8
        setFrameSize(NSSize(width: width, height: max(height, enclosingScrollView?.contentSize.height ?? 0)))
        needsDisplay = true
        onChange?()
        if urls.isEmpty { onEmpty?() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsDisplay = true
    }

    override func viewDidEndLiveResize() { layoutItems() }

    override func draw(_ dirtyRect: NSRect) {
        let rects = frames()
        for (i, url) in urls.enumerated() {
            let rect = rects[i]
            guard rect.intersects(dirtyRect) else { continue }
            if selection.contains(i) {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let name = url.lastPathComponent as NSString
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            if listMode {
                icon.draw(in: NSRect(x: rect.minX + 8, y: rect.minY + 4, width: 22, height: 22))
                style.alignment = .left
                name.draw(in: NSRect(x: rect.minX + 36, y: rect.minY + 7, width: rect.width - 44, height: 16),
                          withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            } else {
                icon.draw(in: NSRect(x: rect.midX - 26, y: rect.minY + 6, width: 52, height: 52))
                style.alignment = .center
                name.draw(in: NSRect(x: rect.minX + 2, y: rect.minY + 62, width: rect.width - 4, height: 28),
                          withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            }
        }
        if let band {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).setFill()
            NSColor.selectedContentBackgroundColor.setStroke()
            let path = NSBezierPath(rect: band)
            path.fill()
            path.stroke()
        }
    }

    private func index(at point: NSPoint) -> Int? { frames().firstIndex { $0.contains(point) } }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDown = point
        if let i = index(at: point) {
            if event.modifierFlags.contains(.command) {
                if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
                anchor = i
            } else if event.modifierFlags.contains(.shift), let anchor {
                selection = Set(min(anchor, i)...max(anchor, i))
            } else if !selection.contains(i) {
                selection = [i]
                anchor = i
            }
            if event.clickCount == 2 { openSelection() }
        } else if !event.modifierFlags.contains(.command) {
            selection = []
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDown else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let i = index(at: start), selection.contains(i), hypot(point.x - start.x, point.y - start.y) > 3 {
            beginDrag(event)
            mouseDown = nil
            return
        }
        if index(at: start) == nil {
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            band = rect
            selection = Set(frames().enumerated().filter { $0.element.intersects(rect) }.map(\.offset))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = mouseDown, let i = index(at: start), !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), event.clickCount == 1 {
            selection = [i]
            anchor = i
        }
        mouseDown = nil
        band = nil
        needsDisplay = true
    }

    private var selectedURLs: [URL] { selection.sorted().compactMap { urls.indices.contains($0) ? urls[$0] : nil } }

    private func beginDrag(_ event: NSEvent) {
        let rects = frames()
        let items: [NSDraggingItem] = selection.sorted().compactMap { i in
            guard urls.indices.contains(i) else { return nil }
            let item = NSDraggingItem(pasteboardWriter: urls[i] as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: urls[i].path)
            let frame = listMode ? NSRect(x: rects[i].minX + 8, y: rects[i].minY + 4, width: 22, height: 22) : NSRect(x: rects[i].midX - 26, y: rects[i].minY + 6, width: 52, height: 52)
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    // Copy (never move) so files dragged out of a Float stay where they are.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { self.layoutItems() }
    }

    // MARK: Dropping files in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? FloatItemsView) === self ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let incoming = DragMonitor.fileURLs(on: sender.draggingPasteboard)
        guard !incoming.isEmpty, (sender.draggingSource as? FloatItemsView) !== self else { return false }
        add(incoming)
        return true
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // space
            showQuickLook()
            return true
        case 51, 117: // delete
            removeSelection()
            return true
        case 36, 76: // return
            openSelection()
            return true
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
                selection = Set(urls.indices)
                needsDisplay = true
                return true
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copySelection(); return true }
            guard let chars = event.characters, !chars.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
            // Type-to-select by name.
            if Date().timeIntervalSince(lastType) > 1 { typeBuffer = "" }
            typeBuffer += chars.lowercased()
            lastType = Date()
            if let match = urls.firstIndex(where: { $0.lastPathComponent.lowercased().hasPrefix(typeBuffer) }) {
                selection = [match]
                anchor = match
                needsDisplay = true
            }
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    // MARK: Actions

    @objc private func openSelection() { selectedURLs.forEach { NSWorkspace.shared.open($0) } }
    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }

    @objc private func copySelection() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(selectedURLs as [NSURL])
    }

    @objc private func duplicateSelection() {
        var copies: [URL] = []
        for url in selectedURLs {
            let ext = url.pathExtension
            let target = OutputNaming.unique(in: url.deletingLastPathComponent(), base: "\(url.deletingPathExtension().lastPathComponent) copy", extension: ext.isEmpty ? nil : ext)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil { copies.append(target) }
        }
        add(copies)
    }

    @objc private func trashSelection() {
        NSWorkspace.shared.recycle(selectedURLs) { [weak self] _, _ in DispatchQueue.main.async { self?.layoutItems() } }
    }

    @objc private func removeSelection() {
        let remove = selection
        urls = urls.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
        selection = []
        layoutItems()
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let i = index(at: point), !selection.contains(i) { selection = [i]; anchor = i; needsDisplay = true }
        guard !selection.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection), keyEquivalent: "").target = self
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let apps = selectedURLs.first.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        if apps.isEmpty { submenu.addItem(withTitle: "No Applications Available", action: nil, keyEquivalent: "").isEnabled = false }
        for app in apps.prefix(15) {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(self.openWith(_:)), keyEquivalent: "")
            item.representedObject = app
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: app.path)
            item.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(item)
        }
        openWith.submenu = submenu
        menu.addItem(openWith)
        menu.addItem(withTitle: "Quick Look", action: #selector(showQuickLook), keyEquivalent: " ").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(copySelection), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashSelection), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Float", action: #selector(removeSelection), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Quick Look

    @objc private func showQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { max(1, selectedURLs.count) }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let list = selectedURLs.isEmpty ? urls : selectedURLs
        return list.indices.contains(index) ? list[index] as NSURL : nil
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        let rects = frames()
        return urls.enumerated().map { i, url in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(url.lastPathComponent + (selection.contains(i) ? ", selected" : ""))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rects[i])
            return element
        }
    }
}
