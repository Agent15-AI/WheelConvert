import AppKit
import SwiftUI

// MARK: - Compress

struct CompressView: View {
    let urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Compress) -> Void
    @State private var options = ToolOptions.Compress()
    @State private var sizeText = "1"
    @State private var unit = "MB"
    @ObservedObject private var settings = AppSettings.shared

    private var totalBytes: Int64 { urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
    private var isImage: Bool { urls.allSatisfy { FileFormat.detect($0)?.category == .images } }
    private var smallest: Int64 { urls.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }.min() ?? 0 }

    private var targetBytes: Int64? {
        guard let value = Double(sizeText.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return Int64(value * (unit == "MB" ? 1_000_000 : unit == "GB" ? 1_000_000_000 : 1_000))
    }

    private var problem: String? {
        switch options.mode {
        case .fileSize:
            guard let target = targetBytes, target >= 1_000 else { return String(localized: "Enter a target size of at least 1 KB.") }
            if target >= smallest { return String(localized: "Target size cannot exceed the original file size.") }
        case .percentage:
            if !(1...99).contains(options.reduction) { return String(localized: "Choose a reduction from 1% to 99%.") }
        case .preset: break
        }
        return nil
    }

    /// Photos, videos, audio and PDFs each remember their own compression settings.
    private var variant: String { FileFormat.detect(urls[0])?.category.rawValue ?? "files" }

    /// Settings → Compression defaults, used until this tool is first applied (and after Reset).
    private var defaults: ToolOptions.Compress {
        .init(strength: isImage ? settings.imageCompression.strength : settings.videoCompression, maxDimension: isImage ? settings.imageCompression.maxDimension : 0)
    }

    var body: some View {
        ToolFrame(primary: urls.count == 1 ? String(localized: "Save Compressed Copy") : String(localized: "Compress \(urls.count) Files"), canApply: problem == nil,
                  note: problem ?? String(localized: "Originals stay unchanged."), reset: {
                      ToolMemory.forget(.compress, variant: variant)
                      options = defaults
                      showTarget(nil)
                  }, cancel: close, apply: {
                      var o = options
                      if let target = targetBytes { o.targetBytes = target }
                      ToolMemory.save(o, for: .compress, variant: variant)
                      apply(o)
                  }) {
            Form {
                LabeledContent("Original size", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                Picker("Compression", selection: $options.mode) {
                    ForEach(ToolOptions.Compress.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch options.mode {
                case .preset:
                    Picker("Strength", selection: $options.strength) {
                        ForEach(CompressionStrength.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(options.strength.detail).font(.callout).foregroundStyle(.secondary)
                case .fileSize:
                    HStack {
                        TextField("Target size", text: $sizeText).frame(width: 90).accessibilityLabel("Target size")
                        Picker("Unit", selection: $unit) { ForEach(["KB", "MB", "GB"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 80)
                    }
                    Text(urls.count > 1 ? "The target applies to each file separately." : "Output will be at most this size.").font(.callout).foregroundStyle(.secondary)
                case .percentage:
                    LabeledSlider(title: "Reduce by", value: Binding(get: { Double(options.reduction) }, set: { options.reduction = Int($0) }),
                                  range: 1...99, step: 1, format: { "\(Int($0))%" })
                    Text("Aim for \(ByteCountFormatter.string(fromByteCount: totalBytes * Int64(100 - options.reduction) / 100, countStyle: .file)) in total.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if urls.contains(where: { FileFormat.detect($0) == .png }) && !(options.mode == .preset && options.strength == .light) {
                    Toggle("Smooth gradients (dithering)", isOn: $options.dither)
                        .help("Blends the reduced PNG colors so skies and gradients don’t show bands. Files may be a little larger.")
                }
                if isImage {
                    Picker("Resize", selection: $options.maxDimension) {
                        Text("Keep original dimensions").tag(0)
                        ForEach([4096, 3840, 2560, 1920, 1600, 1280, 1024, 800], id: \.self) { Text("\($0) px longest edge").tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                let remembered = ToolMemory.isStored(.compress, variant: variant)
                options = ToolMemory.load(.compress, variant: variant, default: defaults)
                showTarget(remembered ? options.targetBytes : nil)
            }
        }
    }

    /// Fills the target size field: a remembered target that fits these files, else half the smallest file.
    private func showTarget(_ remembered: Int64?) {
        let bytes = remembered.flatMap { $0 < smallest ? $0 : nil } ?? max(1_000, smallest / 2)
        if bytes >= 1_000_000 { unit = "MB"; sizeText = String(format: "%.1f", Double(bytes) / 1_000_000) } else { unit = "KB"; sizeText = "\(bytes / 1000)" }
    }
}

// MARK: - Metadata

struct MetadataView: View {
    let urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Metadata) -> Void
    @State private var entries: [MetadataEntry] = []
    @State private var edits: [String: String] = [:]
    @State private var removed: Set<String> = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var removeAll = ToolMemory.load(.removeMetadata, default: false)

    private var groups: [(String, [MetadataEntry])] {
        let filtered = entries.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
        return Dictionary(grouping: filtered, by: \.group).sorted { $0.key < $1.key }
    }

    private var changes: [String: String?] {
        var result: [String: String?] = [:]
        for (key, value) in edits { result[key] = value }
        for key in removed { result[key] = .some(nil) }
        return result
    }

    var body: some View {
        ToolFrame(primary: removeAll ? String(localized: "Remove Metadata") : String(localized: "Save Edited Copy"), canApply: removeAll || !changes.isEmpty,
                  note: removeAll ? String(localized: "Remove metadata now and save a new file. The original stays unchanged.") : (urls.count > 1 ? String(localized: "Edits apply to every selected file.") : nil),
                  reset: { ToolMemory.forget(.removeMetadata); removeAll = false },
                  cancel: close, apply: {
                      ToolMemory.save(removeAll, for: .removeMetadata)
                      apply(.init(removeAll: removeAll, changes: removeAll ? [:] : changes))
                  }) {
            VStack(spacing: 10) {
                Toggle(isOn: $removeAll) {
                    VStack(alignment: .leading) {
                        Text("Remove all metadata").fontWeight(.semibold)
                        Text("Clears camera, location, author and software details. Orientation and color profile are kept so photos look the same.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 18).padding(.top, 14)
                TextField("Search fields", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 18)
                if loading {
                    ProgressView("Loading file details…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.0) { group, items in
                            Section(group) {
                                ForEach(items) { entry in row(entry) }
                            }
                        }
                    }
                    .disabled(removeAll)
                    .opacity(removeAll ? 0.5 : 1)
                }
            }
        }
        .task {
            do { entries = try await MetadataTools.read(urls[0]) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    @ViewBuilder private func row(_ entry: MetadataEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.key).frame(width: 170, alignment: .leading).foregroundStyle(removed.contains(entry.key) ? .tertiary : .primary)
            if entry.editable && !removed.contains(entry.key) {
                TextField(entry.key, text: Binding(get: { edits[entry.key] ?? entry.value }, set: { edits[entry.key] = $0 }))
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(removed.contains(entry.key) ? String(localized: "Will be removed") : entry.value).textSelection(.enabled).lineLimit(3)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if entry.editable {
                Button {
                    if removed.contains(entry.key) { removed.remove(entry.key) } else { removed.insert(entry.key); edits[entry.key] = nil }
                } label: {
                    Image(systemName: removed.contains(entry.key) ? "arrow.uturn.backward" : "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(removed.contains(entry.key) ? "Keep this field" : "Remove this field")
                .accessibilityLabel(removed.contains(entry.key) ? "Keep \(entry.key)" : "Remove \(entry.key)")
            }
        }
    }
}

// MARK: - QR codes

@MainActor
enum QRResultsController {
    private static var windows: [NSWindow] = []

    static func show(_ urls: [URL]) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.title = String(localized: "QR Codes")
        window.subtitle = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) files")
        window.isFloatingPanel = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QRResultsView(urls: urls) { window.close() })
        window.center()
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === window } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct QRResultsView: View {
    let urls: [URL]
    let close: () -> Void
    @State private var codes: [ImageTools.Code] = []
    @State private var loading = true
    @State private var error: String?
    @State private var copied: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView("Reading QR codes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if codes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No QR codes found").font(.headline)
                    Text("Try a sharper or larger image.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(codes) { code in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(code.payload).textSelection(.enabled).lineLimit(4)
                        HStack {
                            Text(code.page.map { String(localized: "\(code.source), page \($0)") } ?? code.source).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let url = URL(string: code.payload), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                Button("Open") { NSWorkspace.shared.open(url) }.help("Open \(url.host ?? String(localized: "link")) in your browser")
                            }
                            Button(copied == code.id ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code.payload, forType: .string)
                                copied = code.id
                            }
                            .accessibilityLabel("Copy QR code text from \(code.source)")
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                if codes.count > 1 {
                    Button("Copy All") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(codes.map(\.payload).joined(separator: "\n"), forType: .string)
                    }
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .task {
            let urls = urls
            do {
                codes = try await Task.detached { try ImageTools.readCodes(urls) { _ in } }.value
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
