import AppKit
import SwiftUI

/// Loads a downsized copy of an image for previews.
@MainActor
final class ImagePreviewSource: ObservableObject {
    @Published var image: CGImage?
    @Published var pixelSize: CGSize = .zero
    @Published var error: String?

    func load(_ url: URL, maxPixel: Int = 1600) async {
        do {
            let full = try await Task.detached { try ImageConverter.load(url, maxPixelSize: maxPixel) }.value
            if let props = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }) {
                let w = props[kCGImagePropertyPixelWidth] as? Double ?? Double(full.cgImage.width)
                let h = props[kCGImagePropertyPixelHeight] as? Double ?? Double(full.cgImage.height)
                let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
                pixelSize = rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            } else {
                pixelSize = CGSize(width: full.cgImage.width, height: full.cgImage.height)
            }
            image = full.cgImage
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PreviewImage: View {
    let image: CGImage?
    var error: String?
    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(12)
                    .accessibilityLabel("Preview")
            } else if let error {
                Text(error).foregroundStyle(.secondary).padding()
            } else {
                ProgressView()
            }
        }
    }
}

// MARK: - Edit photo

struct EditPhotoView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Adjustments) -> Void
    @StateObject private var source = ImagePreviewSource()
    @State private var adjustments = ToolOptions.Adjustments()
    @State private var rendered: CGImage?
    @State private var showOriginal = false

    var body: some View {
        ToolFrame(primary: "Save Edited Copy", canApply: !adjustments.isNeutral, cancel: close, apply: { apply(adjustments) }) {
            HStack(spacing: 0) {
                PreviewImage(image: showOriginal ? source.image : (rendered ?? source.image), error: source.error)
                    .overlay(alignment: .bottomLeading) {
                        Button { } label: { Label("Hold to Compare", systemImage: "eye") }
                            .buttonStyle(.bordered).padding(16)
                            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in showOriginal = true }.onEnded { _ in showOriginal = false })
                            .help("Hold to see the original")
                    }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Adjustments").font(.headline)
                            Spacer()
                            Button("Reset") { adjustments = .neutral }.disabled(adjustments.isNeutral)
                        }
                        SectionTitle("Light")
                        LabeledSlider(title: "Exposure", value: $adjustments.exposure)
                        LabeledSlider(title: "Brightness", value: $adjustments.brightness)
                        LabeledSlider(title: "Contrast", value: $adjustments.contrast)
                        LabeledSlider(title: "Highlights", value: $adjustments.highlights)
                        LabeledSlider(title: "Shadows", value: $adjustments.shadows)
                        LabeledSlider(title: "Whites", value: $adjustments.whites)
                        LabeledSlider(title: "Blacks", value: $adjustments.blacks)
                        SectionTitle("Color")
                        LabeledSlider(title: "Temperature", value: $adjustments.temperature)
                        LabeledSlider(title: "Tint", value: $adjustments.tint)
                        LabeledSlider(title: "Saturation", value: $adjustments.saturation)
                        LabeledSlider(title: "Vibrance", value: $adjustments.vibrance)
                        LabeledSlider(title: "Hue", value: $adjustments.hue)
                        LabeledSlider(title: "Gamma", value: $adjustments.gamma)
                        SectionTitle("Detail")
                        LabeledSlider(title: "Clarity", value: $adjustments.clarity)
                        LabeledSlider(title: "Texture", value: $adjustments.texture)
                        LabeledSlider(title: "Sharpness", value: $adjustments.sharpness, range: 0...100)
                        LabeledSlider(title: "Dehaze", value: $adjustments.dehaze)
                        LabeledSlider(title: "Noise Reduction", value: $adjustments.noiseReduction, range: 0...100)
                        SectionTitle("Effects")
                        LabeledSlider(title: "Fade", value: $adjustments.fade, range: 0...100)
                        LabeledSlider(title: "Vignette", value: $adjustments.vignette)
                        LabeledSlider(title: "Grain", value: $adjustments.grain, range: 0...100)
                        LabeledSlider(title: "Blur", value: $adjustments.blur, range: 0...100)
                    }
                    .padding(16)
                }
                .frame(width: 330)
            }
        }
        .task { await source.load(url) }
        .task(id: adjustments) {
            guard let image = source.image else { return }
            try? await Task.sleep(nanoseconds: 60_000_000) // coalesce slider drags
            guard !Task.isCancelled else { return }
            let a = adjustments
            rendered = a.isNeutral ? nil : try? await Task.detached { try ImageTools.applyAdjustments(a, to: image) }.value
        }
    }
}

// MARK: - Background

struct BackgroundView: View {
    let urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Background) -> Void
    @StateObject private var source = ImagePreviewSource()
    @State private var options = ToolOptions.Background()
    @State private var rendered: CGImage?
    @State private var custom = Color.white

    var body: some View {
        ToolFrame(primary: urls.count == 1 ? "Save with Background" : "Add Background to \(urls.count) Photos", canApply: options.kind != .image || options.imagePath != nil,
                  cancel: close, apply: { apply(options) }) {
            HStack(spacing: 0) {
                PreviewImage(image: rendered ?? source.image, error: source.error)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Background", selection: $options.kind) {
                            Text("Gradient").tag(ToolOptions.Background.Kind.gradient)
                            Text("Color").tag(ToolOptions.Background.Kind.solid)
                            Text("Image").tag(ToolOptions.Background.Kind.image)
                            Text("None").tag(ToolOptions.Background.Kind.transparent)
                        }
                        .pickerStyle(.segmented)
                        switch options.kind {
                        case .gradient:
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 5), spacing: 8) {
                                ForEach(ImageTools.gradients, id: \.id) { gradient in
                                    swatch(selected: options.preset == gradient.id, label: gradient.name) {
                                        LinearGradient(colors: gradient.colors.map(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                                    } action: { options.preset = gradient.id }
                                }
                            }
                        case .solid:
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 5), spacing: 8) {
                                ForEach(ImageTools.solids, id: \.self) { hex in
                                    swatch(selected: options.color == hex, label: "#\(hex)") { Color(hex: hex) } action: { options.color = hex }
                                }
                            }
                            ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                                .onChange(of: custom) { options.color = $0.hexString }
                        case .image:
                            Button(options.imagePath == nil ? "Choose Image…" : "Change Image…") {
                                if let url = chooseImage() { options.imagePath = url.path }
                            }
                            if let path = options.imagePath { Text(URL(fileURLWithPath: path).lastPathComponent).font(.callout).foregroundStyle(.secondary) }
                        case .transparent:
                            Text("The photo keeps rounded corners and a shadow on a transparent PNG.").font(.callout).foregroundStyle(.secondary)
                        }
                        Divider()
                        Picker("Canvas", selection: $options.ratio) {
                            ForEach(ToolOptions.Background.Ratio.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledSlider(title: "Padding", value: Binding(get: { options.padding * 100 }, set: { options.padding = $0 / 100 }), range: 0...40, format: { "\(Int($0))%" })
                        LabeledSlider(title: "Corners", value: Binding(get: { options.cornerRadius * 100 }, set: { options.cornerRadius = $0 / 100 }), range: 0...30, format: { "\(Int($0))%" })
                        LabeledSlider(title: "Shadow", value: Binding(get: { options.shadow * 100 }, set: { options.shadow = $0 / 100 }), range: 0...100, format: { "\(Int($0))%" })
                    }
                    .padding(16)
                }
                .frame(width: 320)
            }
        }
        .task { await source.load(urls[0], maxPixel: 1200) }
        .task(id: PreviewKey(options: options, ready: source.image != nil)) {
            guard let image = source.image else { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            let o = options
            rendered = try? await Task.detached { try ImageTools.renderFrame(image, options: o) }.value
        }
    }

    private struct PreviewKey: Equatable { let options: ToolOptions.Background; let ready: Bool }

    private func swatch<S: View>(selected: Bool, label: String, @ViewBuilder fill: () -> S, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            fill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

func chooseImage() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
}

extension Color {
    init(hex: String) {
        let c = hex.rgb
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

// MARK: - Crop

struct CropView: View {
    let urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Crop) -> Void
    @StateObject private var source = ImagePreviewSource()
    @State private var rects: [CGRect] = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)]
    @State private var selection: Int? = 0
    @State private var aspect: Double? = nil
    @State private var outputWidth = ""
    @State private var outputHeight = ""

    static let aspects: [(String, Double?)] = [("Free", nil), ("Original", -1), ("Square", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("3:4", 0.75), ("4:5", 0.8), ("9:16", 9.0 / 16)]

    private var rect: CGRect { rects.first ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
    private var cropPixels: CGSize { CGSize(width: (rect.width * source.pixelSize.width).rounded(), height: (rect.height * source.pixelSize.height).rounded()) }

    var body: some View {
        ToolFrame(primary: urls.count == 1 ? "Save Cropped Copy" : "Crop \(urls.count) Images", canApply: rect.width > 0.001 && rect.height > 0.001,
                  note: urls.count > 1 ? "The same share of each image is kept, for every image." : nil, cancel: close, apply: {
                      apply(.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, outputWidth: Int(outputWidth) ?? 0, outputHeight: Int(outputHeight) ?? 0))
                  }) {
            VStack(spacing: 10) {
                if let image = source.image {
                    RectEditor(image: image, rects: $rects, selection: $selection, single: true, aspect: effectiveAspect, dimOutside: true)
                        .padding(12)
                        .accessibilityLabel("Crop selection. Drag to reposition.")
                } else {
                    PreviewImage(image: nil, error: source.error)
                }
                HStack(spacing: 12) {
                    Picker("Aspect", selection: Binding(get: { aspect ?? 0 }, set: { aspect = $0 == 0 ? nil : $0; fitAspect() })) {
                        ForEach(Self.aspects, id: \.0) { Text($0.0).tag($0.1 ?? 0) }
                    }
                    .frame(width: 180)
                    Text("\(Int(cropPixels.width)) × \(Int(cropPixels.height)) px").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Text("Output")
                    TextField("Width", text: $outputWidth).frame(width: 64).accessibilityLabel("Crop width in pixels")
                    Text("×")
                    TextField("Height", text: $outputHeight).frame(width: 64).accessibilityLabel("Crop height in pixels")
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .task { await source.load(urls[0]) }
    }

    private var effectiveAspect: Double? {
        guard let aspect else { return nil }
        return aspect < 0 ? Double(source.pixelSize.width / max(1, source.pixelSize.height)) : aspect
    }

    private func fitAspect() {
        guard let a = effectiveAspect, source.pixelSize.width > 0 else { return }
        let unit = CGFloat(a) * source.pixelSize.height / source.pixelSize.width
        var r = rect
        if r.width / max(r.height, 0.001) > unit { r.size.width = r.height * unit } else { r.size.height = r.width / unit }
        rects = [r]
    }
}

// MARK: - Redact photo

struct RedactPhotoView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Redact) -> Void
    @StateObject private var source = ImagePreviewSource()
    @State private var rects: [CGRect] = []
    @State private var selection: Int?
    @State private var style: ToolOptions.Redact.Style = .solid
    @State private var color = Color.black
    @State private var detecting = false
    @State private var message: String?

    var body: some View {
        ToolFrame(primary: "Save Redacted Copy", canApply: !rects.isEmpty, note: message ?? (style == .blur ? "Blur softens details. Use Solid for sensitive information." : "Metadata is removed from redacted copies."),
                  cancel: close, apply: {
                      apply(.init(regions: rects.map { .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }, style: style, color: color.hexString))
                  }) {
            VStack(spacing: 10) {
                if let image = source.image {
                    RectEditor(image: image, rects: $rects, selection: $selection, tint: style == .solid ? color : .white)
                        .padding(12)
                        .accessibilityLabel("Redaction preview. Draw rectangles to cover areas.")
                        .background(DeleteKeyCatcher { if let s = selection, s < rects.count { rects.remove(at: s); selection = nil } })
                } else {
                    PreviewImage(image: nil, error: source.error)
                }
                HStack(spacing: 10) {
                    Button("Detect Faces") { detect("faces") }.disabled(detecting || source.image == nil)
                    Button("Detect Text") { detect("text") }.disabled(detecting || source.image == nil)
                    if detecting { ProgressView().controlSize(.small) }
                    Spacer()
                    Picker("Style", selection: $style) { ForEach(ToolOptions.Redact.Style.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 150)
                    if style == .solid { ColorPicker("Color", selection: $color, supportsOpacity: false).labelsHidden() }
                    Button("Delete") { if let s = selection, s < rects.count { rects.remove(at: s); selection = nil } }.disabled(selection == nil)
                    Button("Clear") { rects = []; selection = nil }.disabled(rects.isEmpty)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .task { await source.load(url, maxPixel: 2400) }
    }

    private func detect(_ kind: String) {
        guard let image = source.image else { return }
        detecting = true
        Task {
            let found = (try? await Task.detached { try ImageTools.detect(kind, in: image) }.value) ?? []
            rects += found.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            message = found.isEmpty ? "No \(kind) found." : "Added \(found.count) area\(found.count == 1 ? "" : "s")."
            detecting = false
        }
    }
}

/// Calls back when Delete or Backspace is pressed while the window is key.
struct DeleteKeyCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window == view.window, [51, 117].contains(event.keyCode),
                  !(event.window?.firstResponder is NSTextView) else { return event }
            action()
            return nil
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { if let m = coordinator.monitor { NSEvent.removeMonitor(m) } }
    final class Coordinator { var monitor: Any? }
}

// MARK: - Collage

struct CollageView: View {
    @State var urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Collage) -> Void
    @State private var options = ToolOptions.Collage()
    @State private var images: [CGImage] = []
    @State private var rendered: CGImage?
    @State private var color = Color.white

    init(urls: [URL], close: @escaping () -> Void, apply: @escaping (ToolOptions.Collage) -> Void) {
        _urls = State(initialValue: urls)
        self.close = close
        self.apply = apply
    }

    var body: some View {
        ToolFrame(primary: "Create Collage", canApply: urls.count >= 2, cancel: close, apply: {
            var o = options
            o.order = urls.map(\.path)
            apply(o)
        }) {
            HStack(spacing: 0) {
                PreviewImage(image: rendered)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Layout", selection: $options.layout) { ForEach(ToolOptions.Collage.Layout.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented)
                        if options.layout == .grid {
                            Stepper(options.columns == 0 ? "Columns: Automatic" : "Columns: \(options.columns)", value: $options.columns, in: 0...max(1, urls.count))
                        }
                        Picker("Canvas", selection: $options.ratio) { ForEach(ToolOptions.Background.Ratio.allCases) { Text($0.title).tag($0) } }
                        Picker("Width", selection: $options.width) { ForEach([1080, 1600, 2400, 3200, 4096], id: \.self) { Text("\($0) px").tag($0) } }
                        LabeledSlider(title: "Spacing", value: Binding(get: { options.spacing * 1000 }, set: { options.spacing = $0 / 1000 }), range: 0...60, format: { String(format: "%.1f%%", $0 / 10) })
                        LabeledSlider(title: "Margin", value: Binding(get: { options.padding * 1000 }, set: { options.padding = $0 / 1000 }), range: 0...100, format: { String(format: "%.1f%%", $0 / 10) })
                        LabeledSlider(title: "Corners", value: Binding(get: { options.cornerRadius * 100 }, set: { options.cornerRadius = $0 / 100 }), range: 0...50, format: { "\(Int($0))%" })
                        Picker("Images", selection: $options.fill) {
                            Text("Fill cells (crop edges)").tag(true)
                            Text("Fit whole images").tag(false)
                        }
                        ColorPicker("Background", selection: $color, supportsOpacity: false).onChange(of: color) { options.background = $0.hexString }
                        SectionTitle("Order")
                        OrderList(urls: $urls).frame(height: 200)
                    }
                    .padding(16)
                }
                .frame(width: 330)
            }
        }
        .task {
            let list = urls
            images = (try? await Task.detached { try list.map { try ImageConverter.load($0, maxPixelSize: 900).cgImage } }.value) ?? []
        }
        .task(id: CollageKey(options: options, urls: urls, count: images.count)) {
            guard images.count == urls.count, !images.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            var o = options
            o.width = 1200
            let byPath = Dictionary(uniqueKeysWithValues: zip(urls.indices, images))
            let ordered = urls.indices.compactMap { byPath[$0] }
            rendered = try? await Task.detached { try ImageTools.renderCollage(ordered, options: o) }.value
        }
        .onChange(of: urls) { _ in
            let list = urls
            Task { images = (try? await Task.detached { try list.map { try ImageConverter.load($0, maxPixelSize: 900).cgImage } }.value) ?? [] }
        }
    }

    private struct CollageKey: Equatable { let options: ToolOptions.Collage; let urls: [URL]; let count: Int }
}
