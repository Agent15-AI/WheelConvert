import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = DragMonitor()
    private var wheel: WheelController!
    private var menuBar: MenuBarController!
    private var settingsObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.removeStaleStaging()
        Self.clearHelperQuarantine()
        wheel = WheelController()
        menuBar = MenuBarController()
        wheel.onChoose = { item, content in
            Task { @MainActor in Self.perform(item, content: content) }
        }
        monitor.onShowWheel = { [weak self] mode, content in
            self?.wheel.show(mode: mode, content: content)
            if mode == .smart { Task { await OnDevice.refreshTranslationLanguages() } }
        }
        monitor.onDismissWheel = { [weak self] in self?.wheel.dismiss() }
        monitor.isDragInsideWheel = { [weak self] in self?.wheel.isDragInside ?? false }
        monitor.isWheelVisible = { [weak self] in self?.wheel.isOpenForDrag ?? false }
        monitor.start()
        NSApp.servicesProvider = self
        MainActor.assumeIsolated {
            Updater.shared.start()
            Task { await OnDevice.refreshTranslationLanguages() }
        }
        // @Published fires before the value changes, so the watcher reads Settings on the next turn.
        settingsObserver = AppSettings.shared.$watchFolders.combineLatest(AppSettings.shared.$presets)
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { FolderWatcher.shared.followSettings() } }
        if !AppSettings.shared.hasCompletedWelcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WelcomeWindowController.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder shows Settings, since there is no Dock icon.
        SettingsWindowController.shared.show()
        return false
    }

    /// Right-click Services (NSServices in Info.plist): open that wheel at the pointer for the selection.
    /// The smart wheel's service also takes selected text and links.
    @objc func showWheel(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let mode = WheelMode(rawValue: userData), let content = try? DragContent.read(pasteboard)?.materialized(from: pasteboard),
              mode == .smart || !content.files.isEmpty else { return }
        wheel.show(mode: mode, content: content, byClick: true)
    }

    @MainActor
    static func perform(_ item: WheelItem, content: DragContent) {
        switch item.action {
        case .smart(let action):
            SmartRunner.perform(action, content: content)
            return
        case .custom(let petal):
            CustomRunner.run(petal, content: content)
            return
        default:
            break
        }
        let urls = content.files
        guard !urls.isEmpty else { return }
        switch item.action {
        case .convert(let format):
            JobCenter.shared.convert(urls, to: format)
        case .tool(let tool):
            ToolLauncher.open(tool, urls: urls)
        case .fileAction(let action):
            FileActions.perform(action, urls: urls)
        case .preset(let preset):
            preset.run(on: urls)
        case .smart, .custom:
            break
        }
    }

    /// Downloaded builds aren't notarized, so every file in the bundle carries the download quarantine.
    /// Once the person has chosen to open the app, its bundled ffmpeg and Java must not trip Gatekeeper
    /// again each time they run.
    private static func clearHelperQuarantine() {
        guard let resources = Bundle.main.resourceURL else { return }
        DispatchQueue.global(qos: .utility).async {
            let walker = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL { removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) }
        }
    }

    /// Staging folders left behind by a crash are removed from recent results folders, and dropped
    /// pictures' private copies from earlier sessions are deleted.
    private static func removeStaleStaging() {
        try? FileManager.default.removeItem(at: DragContent.scratchRoot)
        let folders = [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                       FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
                       FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first].compactMap { $0 }
        DispatchQueue.global(qos: .utility).async {
            for folder in folders {
                guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for item in items where item.lastPathComponent.hasPrefix(".wheelconvert-") {
                    let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if Date().timeIntervalSince(modified) > 6 * 3600 { try? FileManager.default.removeItem(at: item) }
                }
            }
        }
    }
}
