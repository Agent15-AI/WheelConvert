import AppKit

/// The third wheel: actions that work on any files and folders.
@MainActor
enum FileActions {
    static func perform(_ action: FileAction, urls: [URL]) {
        let local = urls.filter(\.isFileURL)
        guard !local.isEmpty else { return alert("Only local files and folders can be used.") }
        switch action {
        case .airDrop: airDrop(local)
        case .float: FloatController.shared.add(local)
        case .copy: copy(local)
        case .move: move(local)
        case .copyPath: copyPaths(local)
        case .terminal: openTerminal(local)
        }
    }

    // MARK: AirDrop

    private static var sharing: AirDropDelegate?

    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            return alert("AirDrop isn’t available for these files on this Mac.")
        }
        let delegate = AirDropDelegate()
        sharing = delegate
        service.delegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    private final class AirDropDelegate: NSObject, NSSharingServiceDelegate {
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { FileActions.sharing = nil }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            FileActions.sharing = nil
            if (error as NSError).code != NSUserCancelledError { FileActions.alert("Couldn’t AirDrop files: \(error.localizedDescription)") }
        }
    }

    // MARK: Clipboard

    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else { return alert("The files couldn’t be placed on the clipboard.") }
        Feedback.confirm("Copied \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")")
    }

    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) else {
            return alert("The paths couldn’t be placed on the clipboard.")
        }
        Feedback.confirm(urls.count == 1 ? "Copied path" : "Copied \(urls.count) paths")
    }

    // MARK: Move

    static func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a destination folder for \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items")."
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url?.standardizedFileURL else { return }
        var failures: [String] = []
        var moved: [URL] = []
        for url in urls {
            let source = url.standardizedFileURL
            if destination.path == source.path || destination.path.hasPrefix(source.path + "/") {
                failures.append("Choose a destination outside “\(source.lastPathComponent)”.")
                continue
            }
            if source.deletingLastPathComponent().path == destination.path { moved.append(source); continue }
            let ext = source.pathExtension
            let target = OutputNaming.unique(in: destination, base: ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent,
                                             extension: ext.isEmpty ? nil : ext)
            do {
                try FileManager.default.moveItem(at: source, to: target)
                moved.append(target)
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
        if !failures.isEmpty { alert(failures.joined(separator: "\n"), title: moved.isEmpty ? "No items were moved." : "Some items weren’t moved.") }
    }

    // MARK: Terminal

    static let terminals: [(id: String, name: String)] = [("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm"), ("com.mitchellh.ghostty", "Ghostty"), ("dev.warp.Warp-Stable", "Warp")]

    static func openTerminal(_ urls: [URL]) {
        let id = AppSettings.shared.terminalApp
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            let name = terminals.first { $0.id == id }?.name ?? "The terminal app"
            return alert("\(name) isn’t installed. Choose another terminal app in Settings → General.")
        }
        var folders: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
            let folder = isDirectory ? url : url.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(folders, withApplicationAt: app, configuration: configuration) { _, error in
            if let error { DispatchQueue.main.async { alert("Couldn’t open terminal: \(error.localizedDescription)") } }
        }
    }

    static func alert(_ message: String, title: String = "WheelConvert") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Brief confirmation bubble near the pointer, for actions with no window of their own.
@MainActor
enum Feedback {
    private static var panel: NSPanel?

    static func confirm(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        let width = label.intrinsicContentSize.width + 28
        let pointer = NSEvent.mouseLocation
        let bubble = NSPanel(contentRect: NSRect(x: pointer.x - width / 2, y: pointer.y + 24, width: width, height: 30),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.level = .popUpMenu
        bubble.ignoresMouseEvents = true
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        bubble.contentView = effect
        bubble.orderFrontRegardless()
        panel = bubble
        NSAccessibility.post(element: bubble, notification: .announcementRequested, userInfo: [.announcement: text])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; bubble.animator().alphaValue = 0 }) { bubble.orderOut(nil) }
        }
    }
}
