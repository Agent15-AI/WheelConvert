import AppKit
import SwiftUI

/// `WheelConvert --snapshot <what> <out.png> [files…]` renders UI offscreen for visual checks.
/// what: wheel-convert | wheel-tools | wheel-actions | settings[:conversion|compression|formats|about] | welcome | tool:<ToolKind> | progress
@MainActor
enum SnapshotMode {
    static func run(_ args: [String]) async throws {
        guard args.count >= 2 else { throw WheelError("usage: --snapshot <what> <out.png> [files…]") }
        let what = args[0], out = URL(fileURLWithPath: args[1])
        let files = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
        let view: NSView
        var size = NSSize(width: 900, height: 660)
        if what.hasPrefix("wheel-") {
            let mode = WheelMode(rawValue: String(what.dropFirst(6))) ?? .convert
            let (items, idle) = WheelItem.items(for: mode, urls: files)
            let d = WheelView.diameter(for: items.count)
            size = NSSize(width: d, height: d)
            let wheel = WheelView(frame: NSRect(origin: .zero, size: size))
            wheel.configure(items: items, idleText: idle)
            view = wheel
        } else if what == "settings" {
            size = NSSize(width: 720, height: 520)
            view = NSHostingView(rootView: SettingsView())
        } else if what.hasPrefix("settings:") {
            size = NSSize(width: 720, height: 520)
            switch what.dropFirst(9) {
            case "conversion": view = NSHostingView(rootView: ConversionSettings())
            case "compression": view = NSHostingView(rootView: CompressionSettings())
            case "formats": view = NSHostingView(rootView: FormatCompatibility())
            default: view = NSHostingView(rootView: AboutSettings())
            }
        } else if what == "welcome" {
            size = NSSize(width: 640, height: 460)
            view = NSHostingView(rootView: WelcomeView { })
        } else if what == "progress" {
            let job = JobState(title: "Converting to PNG", total: 3)
            job.currentName = "holiday.heic"
            job.currentIndex = 1
            job.itemProgress = 0.4
            size = NSSize(width: 340, height: 92)
            view = NSHostingView(rootView: ProgressPanelView(job: job, close: {}))
        } else if what.hasPrefix("tool:"), let tool = ToolKind(rawValue: String(what.dropFirst(5))) {
            size = ToolWindowController.size(for: tool)
            view = NSHostingView(rootView: ToolRoot(tool: tool, urls: files, close: {}))
        } else {
            throw WheelError("Unknown snapshot \(what)")
        }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["DARK"] == "1" ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        window.orderFrontRegardless()
        view.frame = NSRect(origin: .zero, size: size)
        if let wheel = view as? WheelView {
            AppSettings.shared.wheelTheme = .solid
            wheel.layout()
            if let index = Int(ProcessInfo.processInfo.environment["HIGHLIGHT"] ?? "") { wheel.debugHighlight(index) }
        }
        // Let async loading (thumbnails, previews) settle.
        let wait: Double = Double(ProcessInfo.processInfo.environment["WAIT"] ?? "") ?? 2.5
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WheelError("Could not capture.") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw WheelError("Could not encode.") }
        try png.write(to: out)
    }
}
