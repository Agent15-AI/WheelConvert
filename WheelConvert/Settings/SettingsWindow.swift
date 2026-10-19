import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "WheelConvert Settings"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 440)
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.setFrameAutosaveName("WheelConvertSettings")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ConversionSettings().tabItem { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }
            CompressionSettings().tabItem { Label("Compression", systemImage: "arrow.down.right.and.arrow.up.left") }
            FormatCompatibility().tabItem { Label("Formats", systemImage: "tablecells") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 420)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch WheelConvert at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        do { try LoginItem.set(value); loginError = nil } catch {
                            loginError = "macOS couldn’t change this setting. Try again in Login Items."
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if LoginItem.needsApproval || loginError != nil {
                    HStack {
                        Text(loginError ?? "Allow WheelConvert in macOS Login Items to finish setup.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppServiceHelper.openLoginItems() }
                    }
                }
            }
            Section {
                ShortcutRow(mode: .convert)
                ShortcutRow(mode: .tools)
                ShortcutRow(mode: .actions)
            } header: {
                Text("Wheel shortcuts")
            } footer: {
                Text("Start dragging a file, then press the keys. The wheel stays open until you drop.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Wheel") {
                Picker("Appearance", selection: $settings.wheelTheme) { ForEach(WheelTheme.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("Sound and haptic feedback", isOn: $settings.soundsAndHaptics)
                Toggle("Reveal results in Finder", isOn: $settings.revealResults)
            }
            Section("File actions") {
                Picker("Float", selection: $settings.floatBehavior) { ForEach(FloatBehavior.allCases) { Text($0.title).tag($0) } }
                Picker("Terminal app", selection: $settings.terminalApp) {
                    ForEach(FileActions.terminals, id: \.id) { terminal in
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.id) == nil ? "\(terminal.name) (Not installed)" : terminal.name).tag(terminal.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum SMAppServiceHelper {
    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// Records a modifier-key combination for one wheel.
struct ShortcutRow: View {
    let mode: WheelMode
    @ObservedObject private var settings = AppSettings.shared
    @State private var recording = false
    @State private var pressed: NSEvent.ModifierFlags = []
    @State private var peak: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var conflict: String?

    var body: some View {
        HStack {
            Text(mode.title)
            Spacer()
            if let conflict { Text(conflict).font(.callout).foregroundStyle(.orange) }
            Button(action: toggle) {
                Text(recording ? (peak.isEmpty ? "Press keys…" : peak.symbols) : settings.modifiers(for: mode).symbols.isEmpty ? "None" : settings.modifiers(for: mode).symbols)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .frame(minWidth: 90)
            }
            .help(settings.modifiers(for: mode).names)
            .accessibilityLabel("\(mode.title) shortcut, \(settings.modifiers(for: mode).names)")
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        peak = []
        conflict = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop() } // Escape cancels
                return nil
            }
            let flags = event.modifierFlags.intersection(DragMonitor.relevantModifiers)
            if flags.isEmpty, !peak.isEmpty {
                commit(peak)
            } else if flags.rawValue.nonzeroBitCount >= peak.rawValue.nonzeroBitCount {
                peak = flags
            }
            return event
        }
    }

    private func commit(_ flags: NSEvent.ModifierFlags) {
        if let other = WheelMode.allCases.first(where: { $0 != mode && settings.modifiers(for: $0) == flags }) {
            conflict = "Used by \(other.title)"
        } else {
            settings.setModifiers(flags, for: mode)
        }
        stop()
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Conversion defaults

struct ConversionSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selected: FileFormat = .jpg
    @State private var search = ""

    private var outputs: [FileFormat] {
        FileFormat.allCases.filter { !$0.isInputOnly && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.category.title.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 6) {
                TextField("Search formats", text: $search).textFieldStyle(.roundedBorder)
                List(selection: $selected) {
                    ForEach(FormatCategory.allCases) { category in
                        let items = outputs.filter { $0.category == category }
                        if !items.isEmpty {
                            Section(category.title) {
                                ForEach(items) { format in
                                    HStack {
                                        Text(format.title)
                                        Spacer()
                                        if settings.conversionDefaults[format] != nil { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Color(nsColor: Brand.accent)) }
                                    }
                                    .tag(format)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 180, maxWidth: 240)
            FormatOptionsEditor(format: selected).frame(minWidth: 320)
        }
    }
}

struct FormatOptionsEditor: View {
    let format: FileFormat
    @ObservedObject private var settings = AppSettings.shared

    private var options: Binding<ConversionOptions> {
        Binding(get: { settings.options(for: format) }, set: { settings.setOptions($0, for: format) })
    }

    var body: some View {
        let applicable = ConversionSetting.applicable(to: format)
        Form {
            Section("Converting to \(format.title)") {
                if applicable.isEmpty {
                    Text("This output format has no adjustable conversion defaults.").foregroundStyle(.secondary)
                }
                ForEach(applicable, id: \.self) { setting in row(setting) }
            }
            if !applicable.isEmpty {
                Button("Restore Defaults") { settings.setOptions(nil, for: format) }.disabled(settings.conversionDefaults[format] == nil)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func row(_ setting: ConversionSetting) -> some View {
        switch setting {
        case .quality:
            Picker("Quality", selection: options.quality) { ForEach(ConversionOptions.Quality.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
        case .preserveMetadata:
            Toggle("Preserve metadata", isOn: options.preserveMetadata)
        case .videoMaxHeight:
            Picker("Maximum video height", selection: options.videoMaxHeight) {
                ForEach(ConversionSetting.videoHeights, id: \.self) { Text($0 == 0 ? "Match Source" : "\($0)p").tag($0) }
            }
        case .audioBitrate:
            Picker("Audio bitrate", selection: options.audioBitrate) { ForEach(ConversionSetting.bitrates, id: \.self) { Text("\($0) kbps").tag($0) } }
        case .audioSampleDepth:
            Picker("Sample depth", selection: options.audioSampleDepth) {
                ForEach(ConversionOptions.SampleDepth.allCases.filter { format != .flac || ![.bit32, .float32].contains($0) }) { Text($0.title).tag($0) }
            }
        case .gifFrameRate:
            Picker("Frame rate", selection: options.gifFrameRate) { ForEach(ConversionSetting.gifFrameRates, id: \.self) { Text("\($0) fps").tag($0) } }
        case .gifMaxWidth:
            Picker("Maximum width", selection: options.gifMaxWidth) { ForEach(ConversionSetting.gifWidths, id: \.self) { Text($0 == 0 ? "Match Source" : "\($0) px").tag($0) } }
        case .compression:
            Picker("Compression", selection: options.compression) { ForEach(ConversionOptions.ArchiveCompression.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
        case .epubLayout:
            VStack(alignment: .leading) {
                Picker("From PDF", selection: options.epubLayout) { ForEach(ConversionOptions.EPUBLayout.allCases) { Text($0.title).tag($0) } }
                Text(settings.options(for: format).epubLayout.detail).font(.callout).foregroundStyle(.secondary)
            }
        case .officeLayout:
            VStack(alignment: .leading) {
                Picker("From PDF", selection: options.officeLayout) { ForEach(ConversionOptions.OfficeLayout.allCases) { Text($0.title).tag($0) } }
                Text(settings.options(for: format).officeLayout.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Compression defaults

struct CompressionSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Image compression") {
                Picker("Default strength", selection: $settings.imageCompression.strength) { ForEach(CompressionStrength.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                Text(settings.imageCompression.strength.detail).font(.callout).foregroundStyle(.secondary)
                Picker("Default size", selection: $settings.imageCompression.maxDimension) {
                    Text("Keep original dimensions").tag(0)
                    ForEach([4096, 3840, 2560, 1920, 1600, 1280, 1024, 800], id: \.self) { Text("\($0) px longest edge").tag($0) }
                }
            }
            Section("Video compression") {
                Picker("Default strength", selection: $settings.videoCompression) { ForEach(CompressionStrength.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                Text(settings.videoCompression.detail).font(.callout).foregroundStyle(.secondary)
            }
            Button("Restore Compression Defaults") {
                settings.imageCompression = ImageCompressionDefaults()
                settings.videoCompression = .balanced
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Formats

struct FormatCompatibility: View {
    @State private var category: FormatCategory = .images

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Category", selection: $category) { ForEach(FormatCategory.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.menu).frame(width: 220)
            let inputs = FileFormat.allCases.filter { $0.category == category && !$0.isOutputOnly }
            Table(inputs) {
                TableColumn("From") { format in
                    VStack(alignment: .leading) {
                        Text(format.title).fontWeight(.medium)
                        if format.isInputOnly { Text("Input-only format").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .width(min: 110, ideal: 130, max: 160)
                TableColumn("Converts to") { format in
                    Text(ConversionMatrix.outputs(for: format).map(\.title).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text("\(ConversionMatrix.allPairs.count) conversions in total. Folders can also become ZIP, TAR or GZIP archives.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("WheelConvert").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")").foregroundStyle(.secondary)
            Text("Free, offline file conversion. Every conversion and tool runs on your Mac; files are never uploaded.")
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Text("Built with FFmpeg (LGPL), LAME, libvpx, Opus, Vorbis, libwebp, ExifTool, Apache POI, Apache PDFBox, docx-preview, JSZip and cupertino-files.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Show Licenses") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundled.resources.appendingPathComponent("Licenses")])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
