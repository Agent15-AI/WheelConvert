import AppKit
import Combine

enum WheelTheme: String, CaseIterable, Codable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var title: String { self == .glass ? String(localized: "Glass") : String(localized: "Solid") }
}

enum FloatBehavior: String, CaseIterable, Codable, Identifiable {
    case createNew, addToExisting
    var id: String { rawValue }
    var title: String { self == .createNew ? String(localized: "Create a New Float") : String(localized: "Add Files to an Existing Float") }
}

enum SaveDestination: String, CaseIterable, Codable, Identifiable {
    case besideOriginal, ask, folder
    var id: String { rawValue }
    var title: String { String(localized: titleKey) }
    private var titleKey: String.LocalizationValue {
        switch self {
        case .besideOriginal: "Next to the Original"
        case .ask: "Ask Each Time"
        case .folder: "In a Chosen Folder"
        }
    }
}

/// A folder whose new files run through a preset (Settings → Watch Folders).
struct WatchFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var presetID: UUID
    var enabled = true
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
        saveDestination = SaveDestination(rawValue: defaults.string(forKey: Keys.saveDestination) ?? "") ?? .besideOriginal
        saveFolder = defaults.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let data = defaults.data(forKey: Keys.conversion),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Each format decodes on its own, filling fields added in later versions from the defaults.
            for (key, value) in stored {
                guard let format = FileFormat(rawValue: key), let json = try? JSONSerialization.data(withJSONObject: value),
                      let options = try? JSONDecoder().decode(ConversionOptions.self, from: json, defaults: ConversionOptions.defaults(for: format)) else { continue }
                conversionDefaults[format] = options
            }
        }
        if let data = defaults.data(forKey: Keys.presets), let stored = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            // Each preset decodes on its own, filling fields added in later versions from a blank preset.
            presets = stored.compactMap { item in
                guard let json = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? JSONDecoder().decode(Preset.self, from: json, defaults: Preset(name: "", label: ""))
            }
        } else {
            presets = Preset.defaults
        }
        if let data = defaults.data(forKey: Keys.watchFolders), let stored = try? JSONDecoder().decode([WatchFolder].self, from: data) {
            watchFolders = stored
        }
        if let data = defaults.data(forKey: Keys.imageCompression), let value = try? JSONDecoder().decode(ImageCompressionDefaults.self, from: data, defaults: ImageCompressionDefaults()) {
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
        static let saveDestination = "saveResultsDestination"
        static let saveFolder = "saveResultsFolder"
        static let conversion = "conversionDefaults"
        static let imageCompression = "imageCompressionDefaults"
        static let videoCompression = "videoCompressionDefaults"
        static let presets = "presets"
        static let watchFolders = "watchFolders"
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
    @Published var saveDestination: SaveDestination { didSet { defaults.set(saveDestination.rawValue, forKey: Keys.saveDestination) } }
    @Published var saveFolder: URL? { didSet { defaults.set(saveFolder?.path, forKey: Keys.saveFolder) } }
    @Published private(set) var conversionDefaults: [FileFormat: ConversionOptions] = [:]
    @Published var imageCompression = ImageCompressionDefaults() {
        didSet { defaults.set(try? JSONEncoder().encode(imageCompression), forKey: Keys.imageCompression) }
    }
    @Published var videoCompression: CompressionStrength = .balanced {
        didSet { defaults.set(try? JSONEncoder().encode(videoCompression), forKey: Keys.videoCompression) }
    }
    @Published var presets: [Preset] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(presets), forKey: Keys.presets) }
    }
    @Published var watchFolders: [WatchFolder] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(watchFolders), forKey: Keys.watchFolders) }
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
    var title: String { self == .light ? String(localized: "strength.light", defaultValue: "Light", comment: "Mild compression") : self == .balanced ? String(localized: "Balanced") : String(localized: "Strong") }
    var detail: String { String(localized: detailKey) }
    private var detailKey: String.LocalizationValue {
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
        if contains(.control) { parts.append(String(localized: "Control", comment: "Modifier key name")) }
        if contains(.option) { parts.append(String(localized: "Option", comment: "Modifier key name")) }
        if contains(.shift) { parts.append(String(localized: "Shift", comment: "Modifier key name")) }
        if contains(.command) { parts.append(String(localized: "Command", comment: "Modifier key name")) }
        return parts.joined(separator: " + ")
    }
}
