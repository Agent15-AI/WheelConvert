import AppKit
import Combine

enum WheelTheme: String, CaseIterable, Codable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var title: String { self == .glass ? "Glass" : "Solid" }
}

enum FloatBehavior: String, CaseIterable, Codable, Identifiable {
    case createNew, addToExisting
    var id: String { rawValue }
    var title: String { self == .createNew ? "Create a New Float" : "Add Files to an Existing Float" }
}

/// App-wide preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        conversionModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.object(forKey: Keys.convert) as? Int ?? Int(NSEvent.ModifierFlags.shift.rawValue)))
        toolsModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.object(forKey: Keys.tools) as? Int ?? Int(NSEvent.ModifierFlags.command.rawValue)))
        actionsModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.object(forKey: Keys.actions) as? Int ?? Int(NSEvent.ModifierFlags.control.rawValue)))
        wheelTheme = WheelTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .glass
        soundsAndHaptics = defaults.object(forKey: Keys.sounds) as? Bool ?? true
        floatBehavior = FloatBehavior(rawValue: defaults.string(forKey: Keys.float) ?? "") ?? .createNew
        terminalApp = defaults.string(forKey: Keys.terminal) ?? "com.apple.Terminal"
        revealResults = defaults.object(forKey: Keys.reveal) as? Bool ?? true
        hasCompletedWelcome = defaults.bool(forKey: Keys.welcome)
        if let data = defaults.data(forKey: Keys.conversion),
           let stored = try? JSONDecoder().decode([String: ConversionOptions].self, from: data) {
            conversionDefaults = stored.reduce(into: [:]) { result, pair in
                if let format = FileFormat(rawValue: pair.key) { result[format] = pair.value }
            }
        }
        if let data = defaults.data(forKey: Keys.imageCompression), let value = try? JSONDecoder().decode(ImageCompressionDefaults.self, from: data) {
            imageCompression = value
        }
        if let data = defaults.data(forKey: Keys.videoCompression), let value = try? JSONDecoder().decode(CompressionStrength.self, from: data) {
            videoCompression = value
        }
    }

    private enum Keys {
        static let convert = "conversionWheelModifiers"
        static let tools = "toolsWheelModifiers"
        static let actions = "actionsWheelModifiers"
        static let theme = "wheelTheme"
        static let sounds = "soundsAndHapticsEnabled"
        static let float = "floatWheelBehavior"
        static let terminal = "fileActionsTerminalApplication"
        static let reveal = "revealResultsInFinder"
        static let welcome = "hasCompletedWelcome"
        static let conversion = "conversionDefaults"
        static let imageCompression = "imageCompressionDefaults"
        static let videoCompression = "videoCompressionDefaults"
    }

    @Published var conversionModifiers: NSEvent.ModifierFlags { didSet { defaults.set(Int(conversionModifiers.rawValue), forKey: Keys.convert) } }
    @Published var toolsModifiers: NSEvent.ModifierFlags { didSet { defaults.set(Int(toolsModifiers.rawValue), forKey: Keys.tools) } }
    @Published var actionsModifiers: NSEvent.ModifierFlags { didSet { defaults.set(Int(actionsModifiers.rawValue), forKey: Keys.actions) } }
    @Published var wheelTheme: WheelTheme { didSet { defaults.set(wheelTheme.rawValue, forKey: Keys.theme) } }
    @Published var soundsAndHaptics: Bool { didSet { defaults.set(soundsAndHaptics, forKey: Keys.sounds) } }
    @Published var floatBehavior: FloatBehavior { didSet { defaults.set(floatBehavior.rawValue, forKey: Keys.float) } }
    @Published var terminalApp: String { didSet { defaults.set(terminalApp, forKey: Keys.terminal) } }
    @Published var revealResults: Bool { didSet { defaults.set(revealResults, forKey: Keys.reveal) } }
    @Published var hasCompletedWelcome: Bool { didSet { defaults.set(hasCompletedWelcome, forKey: Keys.welcome) } }
    @Published private(set) var conversionDefaults: [FileFormat: ConversionOptions] = [:]
    @Published var imageCompression = ImageCompressionDefaults() {
        didSet { defaults.set(try? JSONEncoder().encode(imageCompression), forKey: Keys.imageCompression) }
    }
    @Published var videoCompression: CompressionStrength = .balanced {
        didSet { defaults.set(try? JSONEncoder().encode(videoCompression), forKey: Keys.videoCompression) }
    }

    func modifiers(for mode: WheelMode) -> NSEvent.ModifierFlags {
        switch mode {
        case .convert: conversionModifiers
        case .tools: toolsModifiers
        case .actions: actionsModifiers
        }
    }

    func setModifiers(_ flags: NSEvent.ModifierFlags, for mode: WheelMode) {
        let clean = flags.intersection(DragMonitor.relevantModifiers)
        switch mode {
        case .convert: conversionModifiers = clean
        case .tools: toolsModifiers = clean
        case .actions: actionsModifiers = clean
        }
    }

    /// The wheel whose shortcut exactly matches the held modifiers.
    func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        let held = flags.intersection(DragMonitor.relevantModifiers)
        guard !held.isEmpty else { return nil }
        return WheelMode.allCases.first { modifiers(for: $0) == held && !modifiers(for: $0).isEmpty }
    }

    func options(for format: FileFormat) -> ConversionOptions {
        conversionDefaults[format] ?? ConversionOptions.defaults(for: format)
    }

    func setOptions(_ options: ConversionOptions?, for format: FileFormat) {
        conversionDefaults[format] = options
        let stored = Dictionary(uniqueKeysWithValues: conversionDefaults.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Keys.conversion)
    }

    func restoreConversionDefaults() {
        conversionDefaults = [:]
        defaults.removeObject(forKey: Keys.conversion)
    }
}

/// How strongly compression trades quality for size.
enum CompressionStrength: String, Codable, CaseIterable, Identifiable {
    case light, balanced, strong
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .light: "Better visual quality with moderate file-size savings."
        case .balanced: "Smaller files with little visible quality loss."
        case .strong: "Much smaller files with more visible quality loss."
        }
    }
}

struct ImageCompressionDefaults: Codable, Equatable {
    var strength: CompressionStrength = .balanced
    /// Longest edge in pixels; 0 keeps the original dimensions.
    var maxDimension = 0
}

extension NSEvent.ModifierFlags {
    /// "⌃⌥⇧⌘" in Apple's canonical order.
    var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    var names: String {
        var parts: [String] = []
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts.joined(separator: " + ")
    }
}
