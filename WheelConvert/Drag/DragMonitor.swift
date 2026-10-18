import AppKit

/// Which wheel a shortcut opens.
enum WheelMode: String, CaseIterable, Codable, Identifiable {
    case convert, tools, actions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "File Tools"
        case .actions: "File Actions"
        }
    }
}

/// Watches system-wide file drags without any special permissions.
///
/// macOS doesn't announce drags to other apps, so this polls cheap global state: the left mouse
/// button, the shared drag pasteboard's change count, and the modifier keys. A drag has begun when
/// the drag pasteboard changes while the button is held. While a drag carries files, pressing a
/// configured modifier combination selects a wheel; the choice latches until the button is
/// released or Escape is pressed, so the keys can be let go after tapping them.
final class DragMonitor {
    /// Called on the main thread with the latched mode, the dragged files, and the pointer location.
    var onShowWheel: ((WheelMode, [URL]) -> Void)?
    /// Called when the wheel should go away (drag ended outside it, Escape, or mode cleared).
    var onDismissWheel: (() -> Void)?
    /// Asks whether the drag is currently over the wheel (then it is never dismissed).
    var isDragInsideWheel: (() -> Bool)?
    var isWheelVisible: (() -> Bool)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: DispatchSourceTimer?
    private var isPollingActively = false

    // Shortcut state.
    private var latchedMode: WheelMode?
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var wasButtonDown = false
    private var wasEscapeDown = false

    // Drag detection.
    private var lastChangeCount = 0
    private var changeCountAtMouseDown: Int?
    private var activeDragChangeCount: Int?
    private var lastValidTrigger: TimeInterval?
    private var shownMode: WheelMode?
    private var shownChangeCount: Int?
    private var cachedFiles: [URL] = []
    private var cachedFilesChangeCount: Int?

    /// After the shortcut stops applying, the wheel lingers this long so a drop can still land.
    private let dismissGrace: TimeInterval = 0.35

    static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    func start() {
        lastChangeCount = dragPasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        schedule(active: false, force: true)
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func schedule(active: Bool, force: Bool = false) {
        guard force || active != isPollingActively, let timer else { return }
        isPollingActively = active
        let interval: DispatchTimeInterval = active ? .microseconds(16_667) : .milliseconds(100)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: active ? .milliseconds(2) : .milliseconds(20))
    }

    private func tick() {
        let modifiers = Self.currentModifiers()
        let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left) || (NSEvent.pressedMouseButtons & 1) != 0
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 0x35)
        updateShortcut(modifiers: modifiers, buttonDown: buttonDown, escapeDown: escapeDown)

        let changeCount = dragPasteboard.changeCount
        if buttonDown {
            if !wasButtonDown {
                // The button just went down: any pasteboard change from here on is a new drag.
                changeCountAtMouseDown = lastChangeCount
                activeDragChangeCount = nil
            }
            if let before = changeCountAtMouseDown, changeCount != before {
                activeDragChangeCount = changeCount
            }
        }
        let dragActive = activeDragChangeCount != nil && activeDragChangeCount == changeCount
        if dragActive && cachedFilesChangeCount != changeCount {
            cachedFiles = Self.fileURLs(on: dragPasteboard)
            cachedFilesChangeCount = changeCount
        }
        let files = dragActive ? cachedFiles : []
        let now = ProcessInfo.processInfo.systemUptime

        if escapeDown && !wasEscapeDown {
            lastValidTrigger = nil
            dismiss()
        } else if let mode = latchedMode, buttonDown, !files.isEmpty {
            lastValidTrigger = now
            if shownMode != mode || shownChangeCount != changeCount || isWheelVisible?() != true {
                shownMode = mode
                shownChangeCount = changeCount
                onShowWheel?(mode, files)
            }
        } else if isWheelVisible?() == true, isDragInsideWheel?() != true {
            let expired = lastValidTrigger.map { now - $0 >= dismissGrace } ?? true
            if expired { dismiss() }
        }

        if !buttonDown {
            changeCountAtMouseDown = nil
            activeDragChangeCount = nil
        }
        wasEscapeDown = escapeDown
        wasButtonDown = buttonDown
        lastChangeCount = changeCount
        schedule(active: buttonDown || isWheelVisible?() == true)
    }

    private func dismiss() {
        shownMode = nil
        shownChangeCount = nil
        onDismissWheel?()
    }

    /// Latches a wheel when a configured combination is newly pressed with the button held.
    private func updateShortcut(modifiers: NSEvent.ModifierFlags, buttonDown: Bool, escapeDown: Bool) {
        defer { wasShortcutButtonDown = buttonDown }
        guard buttonDown, !escapeDown else {
            latchedMode = nil
            lastModifiers = modifiers
            return
        }
        let newlyPressed = !modifiers.subtracting(lastModifiers).isEmpty
        if !wasShortcutButtonDown || newlyPressed {
            if let mode = AppSettings.shared.mode(for: modifiers) { latchedMode = mode }
        }
        lastModifiers = modifiers
    }
    private var wasShortcutButtonDown = false

    static func currentModifiers() -> NSEvent.ModifierFlags {
        let raw = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue) | NSEvent.modifierFlags.rawValue
        return NSEvent.ModifierFlags(rawValue: raw).intersection(relevantModifiers)
    }

    /// Local file and folder URLs on a pasteboard, in order, without duplicates.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        guard pasteboard.availableType(from: [.fileURL]) != nil,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
}
