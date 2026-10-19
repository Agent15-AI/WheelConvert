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

/// The drag/shortcut state machine, separated from the polling so it can be tested.
///
/// A drag has begun when the shared drag pasteboard changes while the button is held. While a drag
/// carries files, pressing a configured modifier combination selects a wheel; the choice latches
/// until the button is released or Escape is pressed, so the keys can be let go after tapping them.
struct DragTracker {
    struct Input {
        var buttonDown: Bool
        var modifiers: NSEvent.ModifierFlags
        var escapeDown: Bool
        var changeCount: Int
    }

    enum Effect: Equatable {
        case show(WheelMode, [URL])
        case dismiss
    }

    /// After the shortcut stops applying, the wheel lingers this long so a drop can still land.
    var dismissGrace: TimeInterval = 0.35

    private(set) var latchedMode: WheelMode?
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var wasButtonDown = false
    private var wasEscapeDown = false
    private var lastChangeCount: Int?
    private var changeCountAtMouseDown: Int?
    private var activeDragChangeCount: Int?
    private var lastValidTrigger: TimeInterval?
    private var shownMode: WheelMode?
    private var shownChangeCount: Int?
    private var cachedFiles: [URL] = []
    private var cachedFilesChangeCount: Int?

    /// - Parameters:
    ///   - files: Reads the dragged files; called once per pasteboard change.
    ///   - mode: The wheel a modifier combination opens.
    mutating func update(_ input: Input, now: TimeInterval, wheelVisible: Bool, dragInsideWheel: Bool,
                         files readFiles: () -> [URL], mode: (NSEvent.ModifierFlags) -> WheelMode?) -> Effect? {
        // Shortcut latch.
        if input.buttonDown && !input.escapeDown {
            let newlyPressed = !input.modifiers.subtracting(lastModifiers).isEmpty
            if !wasButtonDown || newlyPressed, let chosen = mode(input.modifiers) { latchedMode = chosen }
        } else {
            latchedMode = nil
        }
        lastModifiers = input.modifiers

        // Drag detection.
        if input.buttonDown {
            if !wasButtonDown {
                changeCountAtMouseDown = lastChangeCount ?? input.changeCount
                activeDragChangeCount = nil
            }
            if let before = changeCountAtMouseDown, input.changeCount != before { activeDragChangeCount = input.changeCount }
        }
        let dragActive = activeDragChangeCount != nil && activeDragChangeCount == input.changeCount
        if dragActive && cachedFilesChangeCount != input.changeCount {
            cachedFiles = readFiles()
            cachedFilesChangeCount = input.changeCount
        }
        let files = dragActive ? cachedFiles : []

        var effect: Effect?
        if input.escapeDown && !wasEscapeDown {
            lastValidTrigger = nil
            if wheelVisible || shownMode != nil { effect = .dismiss }
            shownMode = nil
            shownChangeCount = nil
        } else if let latched = latchedMode, input.buttonDown, !files.isEmpty {
            lastValidTrigger = now
            if shownMode != latched || shownChangeCount != input.changeCount || !wheelVisible {
                shownMode = latched
                shownChangeCount = input.changeCount
                effect = .show(latched, files)
            }
        } else if wheelVisible, !dragInsideWheel {
            if lastValidTrigger.map({ now - $0 >= dismissGrace }) ?? true {
                shownMode = nil
                shownChangeCount = nil
                effect = .dismiss
            }
        }

        if !input.buttonDown {
            changeCountAtMouseDown = nil
            activeDragChangeCount = nil
        }
        wasEscapeDown = input.escapeDown
        wasButtonDown = input.buttonDown
        lastChangeCount = input.changeCount
        return effect
    }
}

/// Watches system-wide file drags without any special permissions by polling cheap global state:
/// the left mouse button, the drag pasteboard's change count, and the modifier keys.
final class DragMonitor {
    var onShowWheel: ((WheelMode, [URL]) -> Void)?
    var onDismissWheel: (() -> Void)?
    var isDragInsideWheel: (() -> Bool)?
    var isWheelVisible: (() -> Bool)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: DispatchSourceTimer?
    private var isPollingActively = false
    private var tracker = DragTracker()

    static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    func start() {
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

    /// 60 Hz while a button is held or the wheel is up; 10 Hz otherwise.
    private func schedule(active: Bool, force: Bool = false) {
        guard force || active != isPollingActively, let timer else { return }
        isPollingActively = active
        let interval: DispatchTimeInterval = active ? .microseconds(16_667) : .milliseconds(100)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: active ? .milliseconds(2) : .milliseconds(20))
    }

    private func tick() {
        let input = DragTracker.Input(
            buttonDown: CGEventSource.buttonState(.combinedSessionState, button: .left) || (NSEvent.pressedMouseButtons & 1) != 0,
            modifiers: Self.currentModifiers(),
            escapeDown: CGEventSource.keyState(.combinedSessionState, key: 0x35),
            changeCount: dragPasteboard.changeCount)
        let visible = isWheelVisible?() == true
        let effect = tracker.update(input, now: ProcessInfo.processInfo.systemUptime, wheelVisible: visible, dragInsideWheel: isDragInsideWheel?() == true,
                                    files: { Self.fileURLs(on: dragPasteboard) }, mode: { AppSettings.shared.mode(for: $0) })
        switch effect {
        case .show(let mode, let files): onShowWheel?(mode, files)
        case .dismiss: onDismissWheel?()
        case nil: break
        }
        schedule(active: input.buttonDown || isWheelVisible?() == true)
    }

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
