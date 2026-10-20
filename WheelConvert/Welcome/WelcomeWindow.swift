import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in self?.finish() })
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        AppSettings.shared.hasCompletedWelcome = true
        window?.close()
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var page = 0
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    private let pages = 5

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: Brand.accentTop), Color(nsColor: Brand.accentBottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Group {
                    switch page {
                    case 0: intro
                    case 1: wheelPage(.convert, title: "Convert while you drag", text: "Start dragging a file in Finder, then press the key. Drop it on a format — the converted copy appears right next to the original.")
                    case 2: wheelPage(.tools, title: "File tools", text: "Compress, crop, trim, redact, merge and more. Press the tools key while dragging to see the tools for that kind of file.")
                    case 3: wheelPage(.actions, title: "File actions", text: "AirDrop, Float, Copy, Move, Copy Path and Terminal work with any file or folder.")
                    default: setup
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .frame(maxWidth: 520)
                Spacer(minLength: 16)
                HStack {
                    HStack(spacing: 6) {
                        ForEach(0..<pages, id: \.self) { i in
                            Circle().fill(Color.white.opacity(i == page ? 1 : 0.4)).frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityHidden(true)
                    Spacer()
                    if page > 0 { Button("Back") { withAnimation { page -= 1 } }.buttonStyle(WelcomeButton(secondary: true)) }
                    Button(page == pages - 1 ? "Start Using WheelConvert" : "Continue") {
                        if page == pages - 1 { done() } else { withAnimation { page += 1 } }
                    }
                    .buttonStyle(WelcomeButton())
                    .keyboardShortcut(.defaultAction)
                }
                .padding(24)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 640, height: 460)
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112).shadow(radius: 12)
            Text("Welcome to WheelConvert").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Convert and edit files right where you drag them. Everything runs on your Mac — nothing is uploaded, and it’s free.")
                .font(.title3).multilineTextAlignment(.center).opacity(0.9)
        }
    }

    private func wheelPage(_ mode: WheelMode, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(spacing: 18) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(text).font(.title3).multilineTextAlignment(.center).opacity(0.92)
            HStack(spacing: 22) {
                PracticeFile()
                Image(systemName: "plus").font(.title2).opacity(0.7)
                KeyCap(text: settings.modifiers(for: mode).symbols, name: settings.modifiers(for: mode).names)
            }
            Text("Try it: drag the practice file and press \(settings.modifiers(for: mode).names). You can change the keys in Settings.")
                .font(.callout).opacity(0.85).multilineTextAlignment(.center)
        }
    }

    private var setup: some View {
        VStack(spacing: 18) {
            Image(systemName: "menubar.arrow.up.rectangle").font(.system(size: 48))
            Text("You’re all set").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("WheelConvert lives in your menu bar near the clock. Open it there for Settings.").font(.title3).multilineTextAlignment(.center)
            Toggle("Launch WheelConvert at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { try? LoginItem.set($0) }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.15)))
        }
    }
}

struct KeyCap: View {
    let text: String
    let name: String
    var body: some View {
        VStack(spacing: 4) {
            Text(text.isEmpty ? "—" : text).font(.system(size: 26, weight: .medium, design: .rounded))
            Text(name.lowercased()).font(.caption)
        }
        .foregroundStyle(Color.black.opacity(0.75))
        .frame(minWidth: 90, minHeight: 74)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white).shadow(color: .black.opacity(0.25), radius: 0, y: 4))
        .accessibilityElement()
        .accessibilityLabel("Key \(name)")
    }
}

/// A real file the person can drag to try the wheel.
struct PracticeFile: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Self.url.path)).resizable().frame(width: 64, height: 64)
            Text(Self.url.lastPathComponent).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.25)))
        }
        .onDrag { NSItemProvider(contentsOf: Self.url) ?? NSItemProvider() }
        .help("Drag me, then press the keys")
        .accessibilityLabel("Practice file. Drag it, then press the wheel keys.")
    }

    /// A small PNG in Application Support, recreated when missing.
    static let url: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WheelConvert/Practice", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Practice Photo.png")
        if !FileManager.default.fileExists(atPath: file.path) {
            let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
                NSGradient(starting: Brand.accentTop, ending: Brand.accentBottom)?.draw(in: rect, angle: 30)
                let text = NSAttributedString(string: "WheelConvert", attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
            }
        }
        return file
    }()
}

struct WelcomeButton: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(secondary ? Color.white : Color(nsColor: Brand.accentTop))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(secondary ? Color.white.opacity(0.18) : Color.white))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
