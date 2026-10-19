import AppKit
import Combine
import ServiceManagement

/// The menu bar item: status, onboarding, settings, quit.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var observers: Set<AnyCancellable> = []

    override init() {
        super.init()
        item.button?.image = Self.icon(busy: false)
        item.button?.setAccessibilityLabel("WheelConvert")
        menu.delegate = self
        item.menu = menu
        MainActor.assumeIsolated {
            JobCenter.shared.objectWillChange.sink { [weak self] _ in
                // objectWillChange fires before the change lands; read the state on the next turn.
                DispatchQueue.main.async { self?.item.button?.image = Self.icon(busy: MainActor.assumeIsolated { JobCenter.shared.isBusy }) }
            }.store(in: &observers)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let busy = MainActor.assumeIsolated { JobCenter.shared.isBusy }
        let status = NSMenuItem(title: busy ? "WheelConvert is working…" : "WheelConvert is ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let hint = NSMenuItem(title: "Drag a file, then press \(AppSettings.shared.conversionModifiers.symbols)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let recent = RecentResults.urls
        if !recent.isEmpty {
            let header = NSMenuItem(title: "Recent Results", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in recent { menu.addItem(resultItem(url)) }
            add("Clear Recent Results", #selector(clearRecent))
            menu.addItem(.separator())
        }
        add("Getting Started…", #selector(openWelcome))
        if MainActor.assumeIsolated({ FloatController.shared.hasFloats }) { add("Show Floats", #selector(showFloats)) }
        add("Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add("About WheelConvert", #selector(showAbout))
        add("Quit WheelConvert", #selector(quit), key: "q")
    }

    private func add(_ title: String, _ action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    /// A saved result with its file icon and a submenu to reveal, open or trash it.
    private func resultItem(_ url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
        item.toolTip = url.path
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        let submenu = NSMenu()
        for (title, action) in [("Reveal in Finder", #selector(revealResult(_:))), ("Open", #selector(openResult(_:))), ("Move to Trash", #selector(trashResult(_:)))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func revealResult(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openResult(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func trashResult(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            if error == nil { RecentResults.remove(url) }
        }
    }

    @objc private func clearRecent() { RecentResults.clear() }

    @objc private func openWelcome() { MainActor.assumeIsolated { WelcomeWindowController.shared.show() } }
    @objc private func openSettings() { MainActor.assumeIsolated { SettingsWindowController.shared.show() } }
    @objc private func showFloats() { MainActor.assumeIsolated { FloatController.shared.showAll() } }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Free, offline file conversion for your Mac.\nConversions run locally; nothing is uploaded.\nThird-party licenses are in WheelConvert.app/Contents/Resources/Licenses.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// A six-petal wheel drawn as a template image (or circling arrows while busy).
    static func icon(busy: Bool) -> NSImage {
        if busy, let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Working") {
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            let petals = 6
            for i in 0..<petals {
                let angle = CGFloat(i) * 2 * .pi / CGFloat(petals) + .pi / 2
                let start = angle - 0.42, end = angle + 0.42
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: 8.2, startAngle: start * 180 / .pi, endAngle: end * 180 / .pi)
                path.appendArc(withCenter: center, radius: 4.1, startAngle: end * 180 / .pi, endAngle: start * 180 / .pi, clockwise: true)
                path.close()
                path.fill()
            }
            NSBezierPath(ovalIn: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WheelConvert"
        return image
    }
}

/// Launch at login through SMAppService.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
