import AppKit

// Temporary placeholders; replaced by the real windows.
@MainActor final class WelcomeWindowController { static let shared = WelcomeWindowController(); func show() {} }
@MainActor final class SettingsWindowController { static let shared = SettingsWindowController(); func show() {} }
@MainActor final class FloatController { static let shared = FloatController(); var hasFloats: Bool { false }; func add(_ urls: [URL]) {}; func showAll() {} }
