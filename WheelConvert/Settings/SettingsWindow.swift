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
            window.title = String(localized: "WheelConvert Settings")
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
            PresetSettings().tabItem { Label("Presets", systemImage: "wand.and.stars") }
            WatchFolderSettings().tabItem { Label("Watch Folders", systemImage: "eye") }
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
                            loginError = String(localized: "macOS couldn’t change this setting. Try again in Login Items.")
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if LoginItem.needsApproval || loginError != nil {
                    HStack {
                        Text(loginError ?? String(localized: "Allow WheelConvert in macOS Login Items to finish setup.")).foregroundStyle(.secondary)
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
            Section {
                Picker("Save results", selection: $settings.saveDestination) { ForEach(SaveDestination.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: settings.saveDestination) { value in
                        if value == .folder && settings.saveFolder == nil && !chooseSaveFolder() { settings.saveDestination = .besideOriginal }
                    }
                if settings.saveDestination == .folder {
                    HStack {
                        Text(settings.saveFolder.map { FileManager.default.displayName(atPath: $0.path) } ?? String(localized: "No folder chosen"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(settings.saveFolder?.path ?? "")
                        Spacer()
                        Button("Choose…") { _ = chooseSaveFolder() }
                    }
                }
            } header: {
                Text("Results")
            } footer: {
                Text("Results never replace existing files. When a folder can’t be written to, they go to Downloads.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Wheel") {
                Picker("Appearance", selection: $settings.wheelTheme) { ForEach(WheelTheme.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("Sound and haptic feedback", isOn: $settings.soundsAndHaptics)
                Toggle("Reveal results in Finder", isOn: $settings.revealResults)
            }
            if Updater.shared.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = $0 }))
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
            }
            Section("File actions") {
                Picker("Float", selection: $settings.floatBehavior) { ForEach(FloatBehavior.allCases) { Text($0.title).tag($0) } }
                Picker("Terminal app", selection: $settings.terminalApp) {
                    ForEach(FileActions.terminals, id: \.id) { terminal in
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.id) == nil ? String(localized: "\(terminal.name) (Not installed)") : terminal.name).tag(terminal.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// - Returns: Whether a folder was chosen.
    private func chooseSaveFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder where WheelConvert saves results.")
        panel.directoryURL = settings.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        settings.saveFolder = url
        return true
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
                Text(recording ? (peak.isEmpty ? String(localized: "Press keys…") : peak.symbols) : settings.modifiers(for: mode).symbols.isEmpty ? String(localized: "None") : settings.modifiers(for: mode).symbols)
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
            conflict = String(localized: "Used by \(other.title)")
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
            Section(String(localized: "settings.convertingTo", defaultValue: "Converting to \(format.title)",
                           comment: "Settings → Conversion header: the defaults used whenever a file is converted to this format")) {
                if applicable.isEmpty {
                    Text("This output format has no adjustable conversion defaults.").foregroundStyle(.secondary)
                }
                ConversionOptionRows(format: format, options: options)
            }
            if !applicable.isEmpty {
                Button("Restore Defaults") { settings.setOptions(nil, for: format) }.disabled(settings.conversionDefaults[format] == nil)
            }
        }
        .formStyle(.grouped)
    }
}

/// The controls for one output format's options, in Settings → Conversion and the preset editor.
struct ConversionOptionRows: View {
    let format: FileFormat
    @Binding var options: ConversionOptions

    var body: some View {
        ForEach(ConversionSetting.applicable(to: format), id: \.self) { setting in row(setting) }
    }

    @ViewBuilder private func row(_ setting: ConversionSetting) -> some View {
        switch setting {
        case .quality:
            Picker("Quality", selection: $options.quality) { ForEach(ConversionOptions.Quality.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
        case .preserveMetadata:
            Toggle("Preserve metadata", isOn: $options.preserveMetadata)
        case .videoMaxHeight:
            Picker("Maximum video height", selection: $options.videoMaxHeight) {
                ForEach(ConversionSetting.videoHeights, id: \.self) { Text($0 == 0 ? "Match Source" : "\($0)p").tag($0) }
            }
        case .audioBitrate:
            Picker("Audio bitrate", selection: $options.audioBitrate) { ForEach(ConversionSetting.bitrates, id: \.self) { Text("\($0) kbps").tag($0) } }
        case .audioSampleDepth:
            Picker("Sample depth", selection: $options.audioSampleDepth) {
                ForEach(ConversionOptions.SampleDepth.allCases.filter { format != .flac || ![.bit32, .float32].contains($0) }) { Text($0.title).tag($0) }
            }
        case .gifFrameRate:
            Picker("Frame rate", selection: $options.gifFrameRate) { ForEach(ConversionSetting.gifFrameRates, id: \.self) { Text("\($0) fps").tag($0) } }
        case .gifMaxWidth:
            Picker("Maximum width", selection: $options.gifMaxWidth) { ForEach(ConversionSetting.gifWidths, id: \.self) { Text($0 == 0 ? "Match Source" : "\($0) px").tag($0) } }
        case .compression:
            Picker("Compression", selection: $options.compression) { ForEach(ConversionOptions.ArchiveCompression.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
        case .epubLayout:
            VStack(alignment: .leading) {
                Picker("From PDF", selection: $options.epubLayout) { ForEach(ConversionOptions.EPUBLayout.allCases) { Text($0.title).tag($0) } }
                Text(options.epubLayout.detail).font(.callout).foregroundStyle(.secondary)
            }
        case .officeLayout:
            VStack(alignment: .leading) {
                Picker("From PDF", selection: $options.officeLayout) { ForEach(ConversionOptions.OfficeLayout.allCases) { Text($0.title).tag($0) } }
                Text(options.officeLayout.detail).font(.callout).foregroundStyle(.secondary)
            }
        case .pdfImageDPI:
            VStack(alignment: .leading) {
                Picker("From PDF", selection: $options.pdfImageDPI) { ForEach(ConversionSetting.pdfImageDPIs, id: \.self) { Text("\($0) DPI").tag($0) } }
                    .pickerStyle(.segmented)
                Text("Resolution of PDF pages saved as images. 150 DPI suits screens; 300 DPI suits printing.").font(.callout).foregroundStyle(.secondary)
            }
        case .imageMaxWidth:
            Picker("Maximum width", selection: $options.imageMaxWidth) {
                ForEach(ConversionSetting.imageWidths, id: \.self) { Text($0 == 0 ? "Match Source" : "\($0) px").tag($0) }
            }
        }
    }
}

// MARK: - Presets

struct PresetSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: Preset.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.presets) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).lineLimit(1)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(preset.id)
                    }
                    .onMove { settings.presets.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 8) {
                    Menu {
                        Button("Conversion Preset") { add(Preset(name: String(localized: "New Preset"), label: String(localized: "PRESET"), target: .jpg)) }
                        ForEach(Preset.tools) { tool in
                            Button("\(tool.title) Preset") { add(Self.blank(tool)) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Add a preset").accessibilityLabel("Add preset")
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Delete the selected preset").accessibilityLabel("Delete preset")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .disabled(selection == nil).help("Duplicate the selected preset").accessibilityLabel("Duplicate preset")
                    Spacer()
                    Button("Restore Defaults") {
                        settings.presets = Preset.defaults + settings.presets.filter { preset in !Preset.defaults.contains { $0.id == preset.id } }
                    }
                    .help("Bring back the presets WheelConvert comes with, as they were. Your own presets stay.")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 230, maxWidth: 290)
            if let index = settings.presets.firstIndex(where: { $0.id == selection }) {
                PresetEditor(preset: $settings.presets[index]).frame(minWidth: 340)
            } else {
                Text("Select a preset, or click + to add one. Presets appear on the Convert wheel for the files they fit.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(30)
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = settings.presets.first?.id } }
    }

    static func blank(_ tool: ToolKind) -> Preset {
        var preset = Preset(name: tool.title, label: tool.wheelLabel, tool: tool)
        switch tool {
        case .removeMetadata: preset.encode(ToolOptions.Metadata(removeAll: true))
        case .normalizeAudio: preset.encode(ToolOptions.Normalize())
        default: preset.encode(ToolOptions.Compress())
        }
        return preset
    }

    private func add(_ preset: Preset) {
        settings.presets.append(preset)
        selection = preset.id
    }

    private func remove() {
        guard let index = settings.presets.firstIndex(where: { $0.id == selection }) else { return }
        settings.presets.remove(at: index)
        selection = settings.presets[safe: min(index, settings.presets.count - 1)]?.id
    }

    private func duplicate() {
        guard let index = settings.presets.firstIndex(where: { $0.id == selection }) else { return }
        var copy = settings.presets[index]
        copy.id = UUID()
        copy.name = String(localized: "\(copy.name) Copy", comment: "Name of a duplicated preset")
        settings.presets.insert(copy, at: index + 1)
        selection = copy.id
    }
}

struct PresetEditor: View {
    @Binding var preset: Preset

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                TextField("Wheel label", text: Binding(get: { preset.label }, set: { preset.label = String($0.prefix(12)) }))
                Toggle("Show on the Convert wheel", isOn: $preset.showOnWheel)
                Picker("Use for", selection: $preset.category) {
                    Text("Any File It Fits").tag(FormatCategory?.none)
                    ForEach(FormatCategory.allCases) { Text($0.title).tag(FormatCategory?.some($0)) }
                }
            }
            if let target = preset.target {
                Section {
                    Picker("Convert to", selection: Binding(get: { target }, set: { preset.target = $0 })) {
                        ForEach(FileFormat.allCases.filter { !$0.isInputOnly }) { Text($0.title).tag($0) }
                    }
                    ConversionOptionRows(format: target, options: Binding(get: { preset.conversionOptions }, set: { preset.conversionOptions = $0 }))
                }
            } else if let tool = preset.tool {
                Section(tool.title) { toolRows(tool) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func toolRows(_ tool: ToolKind) -> some View {
        switch tool {
        case .compress:
            let options = Binding(get: { preset.decoded(ToolOptions.Compress()) }, set: { preset.encode($0) })
            Picker("Compression", selection: options.mode) { ForEach(ToolOptions.Compress.Mode.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            switch options.wrappedValue.mode {
            case .preset:
                Picker("Strength", selection: options.strength) { ForEach(CompressionStrength.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            case .fileSize:
                LabeledContent("Target size") {
                    HStack {
                        TextField("Target size", value: Binding(get: { Double(options.wrappedValue.targetBytes) / 1_000_000 }, set: { options.wrappedValue.targetBytes = Int64(max(0.001, $0) * 1_000_000) }),
                                  format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 80).labelsHidden()
                        Text("MB")
                    }
                }
            case .percentage:
                LabeledSlider(title: "Reduce by", value: Binding(get: { Double(options.wrappedValue.reduction) }, set: { options.wrappedValue.reduction = Int($0) }),
                              range: 1...99, step: 1, format: { "\(Int($0))%" })
            }
            Picker("Images", selection: options.maxDimension) {
                Text("Keep original dimensions").tag(0)
                ForEach([4096, 3840, 2560, 1920, 1600, 1280, 1024, 800], id: \.self) { Text("\($0) px longest edge").tag($0) }
            }
            Toggle("Smooth PNG gradients (dithering)", isOn: options.dither)
            Picker("Save video as", selection: options.videoFormat) {
                Text("Same Format").tag(FileFormat?.none)
                ForEach([FileFormat.mp4, .mov, .mkv, .webm]) { Text($0.title).tag(FileFormat?.some($0)) }
            }
        case .normalizeAudio:
            let options = Binding(get: { preset.decoded(ToolOptions.Normalize()) }, set: { preset.encode($0) })
            Picker("Loudness", selection: options.targetLoudness) {
                Text("Podcast & voice (−16 LUFS)").tag(-16.0)
                Text("Streaming music (−14 LUFS)").tag(-14.0)
                Text("Broadcast (−23 LUFS)").tag(-23.0)
            }
        default:
            Text("Removes camera, location, author and software details. Orientation and color profile are kept.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Watch folders

struct WatchFolderSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                if settings.watchFolders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach($settings.watchFolders) { $folder in
                    HStack(spacing: 10) {
                        Toggle("Watch \(FileManager.default.displayName(atPath: folder.path))", isOn: $folder.enabled).labelsHidden()
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(FileManager.default.displayName(atPath: folder.path)).lineLimit(1)
                            Text((folder.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Preset", selection: $folder.presetID) {
                            if !settings.presets.contains(where: { $0.id == folder.presetID }) { Text("Choose a Preset").tag(folder.presetID) }
                            ForEach(settings.presets) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 220)
                        Button { settings.watchFolders.removeAll { $0.id == folder.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop watching this folder")
                            .accessibilityLabel("Stop watching \(FileManager.default.displayName(atPath: folder.path))")
                    }
                }
                Button("Add Folder…", action: addFolder).disabled(settings.presets.isEmpty)
            } header: {
                Text("Watch folders")
            } footer: {
                Text("New files added to these folders run through the chosen preset while WheelConvert is open. Files still being copied or downloaded wait until they’re complete, and WheelConvert’s own results are never processed again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Watch")
        panel.message = String(localized: "Choose folders to watch for new files.")
        guard panel.runModal() == .OK, let preset = settings.presets.first else { return }
        for url in panel.urls where !settings.watchFolders.contains(where: { $0.path == url.path }) {
            settings.watchFolders.append(WatchFolder(path: url.path, presetID: preset.id))
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
            Text("\(ConversionMatrix.allPairs.count) conversions in total. Folders can also become ZIP, TAR, GZIP or 7Z archives.").font(.callout).foregroundStyle(.secondary)
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
            Text("Built with FFmpeg (LGPL), LAME, libvpx, Opus, Vorbis, libwebp, ExifTool, Apache POI, Apache PDFBox, docx-preview, JSZip, cupertino-files and Sparkle.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Show Licenses") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundled.resources.appendingPathComponent("Licenses")])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
