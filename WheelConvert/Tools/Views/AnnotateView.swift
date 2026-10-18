import AppKit
import SwiftUI

struct AnnotateView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Annotate) -> Void

    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, rectangle, ellipse, freehand, highlighter, text, number, magnifier, image
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .freehand: "scribble"
            case .highlighter: "highlighter"
            case .text: "textformat"
            case .number: "1.circle"
            case .magnifier: "plus.magnifyingglass"
            case .image: "photo.badge.plus"
            }
        }
        var help: String {
            switch self {
            case .select: "Select: drag an annotation to move it"
            case .arrow: "Arrow — drag from the tail toward the arrowhead"
            case .rectangle: "Rectangle — drag to draw"
            case .ellipse: "Ellipse — drag to draw"
            case .freehand: "Draw freehand"
            case .highlighter: "Highlighter — drag over the image"
            case .text: "Text — click to add a text box"
            case .number: "Numbered callout — click to place"
            case .magnifier: "Magnifier — drag from the detail outward"
            case .image: "Place an image"
            }
        }
    }

    static let palette = ["FF3B30", "FF9500", "FFCC00", "34C759", "007AFF", "AF52DE", "FFFFFF", "000000"]

    @StateObject private var source = ImagePreviewSource()
    @State private var items: [ToolOptions.Annotation] = []
    @State private var history: [[ToolOptions.Annotation]] = []
    @State private var tool: Tool = .arrow
    @State private var color = "FF3B30"
    @State private var lineWidth = 0.006
    @State private var fontSize = 0.045
    @State private var font = "system"
    @State private var magnification = 2.0
    @State private var selected: UUID?
    @State private var rendered: CGImage?
    private enum DragMode { case move, create }
    @State private var drag: (id: UUID, start: CGPoint, original: ToolOptions.Annotation, mode: DragMode)?
    @State private var editingText: UUID?
    @State private var draft = ""
    @State private var customColor = Color.red

    var body: some View {
        ToolFrame(primary: "Save Annotated Copy", canApply: !items.isEmpty, note: tool.help, cancel: close, apply: { apply(.init(items: items)) }) {
            VStack(spacing: 8) {
                toolbar
                GeometryReader { geo in
                    canvas(in: geo.size)
                }
                .padding(.horizontal, 12)
                .background(DeleteKeyCatcher { deleteSelected() })
            }
            .padding(.vertical, 10)
        }
        .task { await source.load(url, maxPixel: 1600) }
        .task(id: RenderKey(items: items, ready: source.image != nil)) {
            guard let image = source.image else { return }
            let list = items
            rendered = try? await Task.detached { try ImageTools.renderAnnotations(list, on: image) }.value
        }
    }

    private struct RenderKey: Equatable { let items: [ToolOptions.Annotation]; let ready: Bool }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { t in
                Button { pick(t) } label: {
                    Image(systemName: t.symbol).frame(width: 26, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tool == t ? Color(nsColor: Brand.accent).opacity(0.25) : .clear))
                }
                .buttonStyle(.plain)
                .help(t.help)
                .accessibilityLabel(t.help)
            }
            Divider().frame(height: 20)
            ForEach(Self.palette, id: \.self) { hex in
                Button { setColor(hex) } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(color == hex ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.25), lineWidth: color == hex ? 2.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Annotation color #\(hex)")
            }
            ColorPicker("Annotation color", selection: $customColor, supportsOpacity: false).labelsHidden()
                .onChange(of: customColor) { setColor($0.hexString) }
            Divider().frame(height: 20)
            if [.text, .number].contains(tool) || selectedItem.map({ [.text, .number].contains($0.kind) }) == true {
                Picker("Font", selection: $font) {
                    Text("System").tag("system"); Text("Rounded").tag("rounded"); Text("Serif").tag("serif"); Text("Mono").tag("mono")
                }
                .labelsHidden().frame(width: 92)
                .onChange(of: font) { value in updateSelected { $0.font = value } }
                Slider(value: $fontSize, in: 0.02...0.14).frame(width: 80).accessibilityLabel("Text size")
                    .onChange(of: fontSize) { value in updateSelected { $0.fontSize = value } }
            } else if tool == .magnifier || selectedItem?.kind == .magnifier {
                Slider(value: $magnification, in: 1.5...4).frame(width: 90).accessibilityLabel("Magnifier zoom level")
                    .onChange(of: magnification) { value in updateSelected { $0.magnification = value } }
            } else {
                Slider(value: $lineWidth, in: 0.002...0.02).frame(width: 90).accessibilityLabel("Line width")
                    .onChange(of: lineWidth) { value in updateSelected { $0.lineWidth = value } }
            }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(history.isEmpty).help("Undo last annotation")
                .keyboardShortcut("z", modifiers: .command).accessibilityLabel("Undo last annotation")
            Button { deleteSelected() } label: { Image(systemName: "trash") }.disabled(selected == nil).help("Delete selected annotation")
                .accessibilityLabel("Delete selected annotation")
            Button("Clear Drawing") { record(); items.removeAll { [.freehand, .highlighter].contains($0.kind) } }
                .disabled(!items.contains { [.freehand, .highlighter].contains($0.kind) }).help("Remove all drawn strokes")
        }
        .padding(.horizontal, 12)
    }

    private var selectedItem: ToolOptions.Annotation? { items.first { $0.id == selected } }

    @ViewBuilder private func canvas(in size: CGSize) -> some View {
        if let image = rendered ?? source.image {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let fit = min(size.width / w, size.height / h)
            let shown = CGSize(width: w * fit, height: h * fit)
            let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
            let unit = { (p: CGPoint) in CGPoint(x: min(max(0, (p.x - origin.x) / shown.width), 1), y: min(max(0, (p.y - origin.y) / shown.height), 1)) }
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: shown.width, height: shown.height).offset(x: origin.x, y: origin.y)
                    .accessibilityLabel("Annotation preview")
                if let item = selectedItem {
                    let b = bounds(item, aspect: w / h)
                    Rectangle().stroke(Color(nsColor: Brand.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: max(8, b.width * shown.width) + 8, height: max(8, b.height * shown.height) + 8)
                        .offset(x: origin.x + b.minX * shown.width - 4, y: origin.y + b.minY * shown.height - 4)
                }
                if let id = editingText, let item = items.first(where: { $0.id == id }) {
                    TextField("Text", text: $draft, onCommit: { commitText() })
                        .textFieldStyle(.roundedBorder)
                        .frame(width: max(160, CGFloat(item.endX - item.x) * shown.width))
                        .offset(x: origin.x + item.x * shown.width, y: origin.y + item.y * shown.height - 30)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                changed(start: unit(value.startLocation), current: unit(value.location), aspect: w / h)
            }.onEnded { value in
                ended(start: unit(value.startLocation), end: unit(value.location))
            })
        } else {
            PreviewImage(image: nil, error: source.error)
        }
    }

    // MARK: Interaction

    private func pick(_ t: Tool) {
        commitText()
        if t == .image {
            if let file = chooseImage() {
                record()
                var item = ToolOptions.Annotation(kind: .image)
                item.imagePath = file.path
                let aspect = imageAspect(file) * Double(source.pixelSize.height / max(1, source.pixelSize.width))
                item.x = 0.35; item.y = 0.35; item.endX = 0.65; item.endY = 0.35 + 0.3 * (1 / max(aspect, 0.05))
                items.append(item)
                selected = item.id
            }
            tool = .select
            return
        }
        tool = t
    }

    private func imageAspect(_ url: URL) -> Double {
        guard let props = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }),
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, h > 0 else { return 1 }
        return w / h
    }

    private func setColor(_ hex: String) {
        color = hex
        updateSelected { $0.color = hex }
    }

    private func updateSelected(_ change: (inout ToolOptions.Annotation) -> Void) {
        guard let id = selected, let index = items.firstIndex(where: { $0.id == id }) else { return }
        var copy = items[index]
        change(&copy)
        if copy != items[index] { items[index] = copy }
    }

    private func record() {
        history.append(items)
        if history.count > 100 { history.removeFirst() }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        items = last
        selected = nil
    }

    private func deleteSelected() {
        guard let id = selected else { return }
        record()
        items.removeAll { $0.id == id }
        selected = nil
    }

    private func commitText() {
        guard let id = editingText, let index = items.firstIndex(where: { $0.id == id }) else { editingText = nil; return }
        if draft.trimmingCharacters(in: .whitespaces).isEmpty { items.remove(at: index) } else { items[index].text = draft }
        editingText = nil
        draft = ""
    }

    private func hit(_ point: CGPoint, aspect: CGFloat) -> ToolOptions.Annotation? {
        items.reversed().first { bounds($0, aspect: aspect).insetBy(dx: -0.015, dy: -0.015).contains(point) }
    }

    /// Normalized bounds of an annotation, for selection.
    private func bounds(_ item: ToolOptions.Annotation, aspect: CGFloat) -> CGRect {
        switch item.kind {
        case .freehand, .highlighter:
            let xs = item.points.compactMap(\.first), ys = item.points.compactMap { $0.count > 1 ? $0[1] : nil }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case .number:
            let r = item.fontSize * 0.75 * Double(min(1, 1 / aspect))
            return CGRect(x: item.x - r, y: item.y - r * Double(aspect), width: 2 * r, height: 2 * r * Double(aspect))
        case .text:
            let lines = max(1, item.text.components(separatedBy: "\n").count)
            return CGRect(x: item.x, y: item.y, width: max(0.05, item.endX - item.x), height: item.fontSize * 1.3 * Double(lines) * Double(min(aspect, 1)) * 1.2)
        case .magnifier:
            let r = hypot((item.endX - item.x) * Double(aspect), item.endY - item.y)
            return CGRect(x: item.x - r / Double(aspect), y: item.y - r, width: 2 * r / Double(aspect), height: 2 * r)
        default:
            return CGRect(x: min(item.x, item.endX), y: min(item.y, item.endY), width: abs(item.endX - item.x), height: abs(item.endY - item.y))
        }
    }

    private func changed(start: CGPoint, current: CGPoint, aspect: CGFloat) {
        if drag == nil {
            commitText()
            let target = hit(start, aspect: aspect)
            // Select tool, the already-selected annotation, or any text box: grab and move it.
            if let target, tool == .select || target.id == selected || target.kind == .text {
                record()
                selected = target.id
                drag = (target.id, start, target, .move)
            } else if tool == .select {
                selected = nil
                return
            } else {
                record()
                var item = ToolOptions.Annotation(kind: kind(for: tool))
                item.color = color
                item.lineWidth = lineWidth
                item.fontSize = fontSize
                item.font = font
                item.magnification = magnification
                item.x = start.x; item.y = start.y; item.endX = start.x; item.endY = start.y
                if tool == .number { item.number = (items.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1 }
                if tool == .freehand || tool == .highlighter { item.points = [[start.x, start.y]] }
                items.append(item)
                selected = item.id
                drag = (item.id, start, item, .create)
            }
        }
        guard let drag, let index = items.firstIndex(where: { $0.id == drag.id }) else { return }
        var item = items[index]
        switch drag.mode {
        case .move:
            let dx = current.x - drag.start.x, dy = current.y - drag.start.y
            let o = drag.original
            item.x = o.x + dx; item.y = o.y + dy
            item.endX = o.endX + dx; item.endY = o.endY + dy
            item.points = o.points.map { [$0[0] + dx, $0[1] + dy] }
        case .create:
            if item.kind == .freehand || item.kind == .highlighter {
                item.points.append([current.x, current.y])
            } else if item.kind != .number {
                item.endX = current.x
                item.endY = current.y
            }
        }
        items[index] = item
    }

    private func ended(start: CGPoint, end: CGPoint) {
        defer { drag = nil }
        guard let drag, let index = items.firstIndex(where: { $0.id == drag.id }) else { return }
        let item = items[index]
        let distance = hypot(end.x - start.x, end.y - start.y)
        switch drag.mode {
        case .move:
            if distance < 0.004 {
                _ = history.popLast() // a click, not a move
                if item.kind == .text { editingText = item.id; draft = item.text }
            }
        case .create:
            switch item.kind {
            case .text:
                if items[index].endX - items[index].x < 0.12 { items[index].endX = min(1, items[index].x + 0.35) }
                editingText = item.id
                draft = ""
            case .arrow, .rectangle, .ellipse, .magnifier:
                if distance < 0.01 { items.remove(at: index); _ = history.popLast(); selected = nil }
            case .freehand, .highlighter:
                if item.points.count < 2 { items.remove(at: index); _ = history.popLast(); selected = nil }
            case .number, .image:
                break
            }
        }
    }

    private func kind(for tool: Tool) -> ToolOptions.Annotation.Kind {
        switch tool {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .text: .text
        case .number: .number
        case .magnifier: .magnifier
        case .image, .select: .image
        }
    }
}
