import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Organize

struct OrganizePDFView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.OrganizePDF) -> Void
    @State private var document: PDFDocument?
    @State private var pages: [ToolOptions.OrganizePDF.Page] = []
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var selection: UUID?
    @State private var dragged: UUID?
    @State private var equalWidths = false
    @State private var error: String?

    private var original: [ToolOptions.OrganizePDF.Page] { (0..<(document?.pageCount ?? 0)).map { .init(source: $0) } }
    private var changed: Bool { equalWidths || pages.map(\.source) != original.map(\.source) || pages.contains { $0.rotation % 360 != 0 } }

    var body: some View {
        ToolFrame(primary: "Save Organized PDF", canApply: !pages.isEmpty && changed, note: "Drag pages to reorder. \(pages.count) page\(pages.count == 1 ? "" : "s").",
                  cancel: close, apply: { apply(.init(pages: pages, equalWidths: equalWidths)) }) {
            VStack(spacing: 8) {
                HStack {
                    Button { act { $0.rotation = ($0.rotation + 90) % 360 } } label: { Label("Rotate", systemImage: "rotate.right") }
                        .disabled(selection == nil).help("Rotate the selected page 90 degrees clockwise")
                    Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.disabled(selection == nil)
                    Button { remove() } label: { Label("Delete", systemImage: "trash") }.disabled(selection == nil || pages.count <= 1)
                    Spacer()
                    Toggle("Make all pages the same width", isOn: $equalWidths)
                        .help("Pages are scaled proportionally to match the narrowest page; their heights may still differ.")
                    Button("Reset Order") { pages = original; equalWidths = false }.disabled(!changed)
                }
                .padding(.horizontal, 16).padding(.top, 12)
                if let error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                cell(page, index: index)
                            }
                        }
                        .padding(16)
                    }
                    .background(DeleteKeyCatcher { remove() })
                }
            }
        }
        .task {
            guard let doc = PDFDocument(url: url), !doc.isLocked else { error = "This PDF cannot be read or is password-protected."; return }
            document = doc
            pages = original
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { thumbnails[i] = page.thumbnail(of: CGSize(width: 240, height: 240), for: .cropBox) }
                if i % 8 == 7 { await Task.yield() }
            }
        }
    }

    private func cell(_ page: ToolOptions.OrganizePDF.Page, index: Int) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = thumbnails[page.source] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.06))
                }
            }
            .rotationEffect(.degrees(Double(page.rotation)))
            .frame(width: 120, height: 150)
            .background(Color.white.shadow(radius: 1))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(selection == page.id ? Color(nsColor: Brand.accent) : .clear, lineWidth: 3))
            Text("\(index + 1)" + (page.source != index ? " · was \(page.source + 1)" : "")).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = page.id }
        .onDrag {
            dragged = page.id
            return NSItemProvider(object: page.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: PageDrop(target: page.id, pages: $pages, dragged: $dragged))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(index + 1)\(page.source != index ? ", originally page \(page.source + 1)" : "")\(page.rotation != 0 ? ", rotated \(page.rotation) degrees clockwise" : "")")
        .accessibilityAddTraits(selection == page.id ? .isSelected : [])
    }

    private func act(_ change: (inout ToolOptions.OrganizePDF.Page) -> Void) {
        guard let index = pages.firstIndex(where: { $0.id == selection }) else { return }
        change(&pages[index])
    }

    private func duplicate() {
        guard let index = pages.firstIndex(where: { $0.id == selection }) else { return }
        var copy = pages[index]
        copy.id = UUID()
        pages.insert(copy, at: index + 1)
        selection = copy.id
    }

    private func remove() {
        guard pages.count > 1, let index = pages.firstIndex(where: { $0.id == selection }) else { return }
        pages.remove(at: index)
        selection = pages.indices.contains(index) ? pages[index].id : pages.last?.id
    }

    private struct PageDrop: DropDelegate {
        let target: UUID
        @Binding var pages: [ToolOptions.OrganizePDF.Page]
        @Binding var dragged: UUID?

        func dropEntered(info: DropInfo) {
            guard let dragged, dragged != target, let from = pages.firstIndex(where: { $0.id == dragged }),
                  let to = pages.firstIndex(where: { $0.id == target }) else { return }
            withAnimation(.easeInOut(duration: 0.15)) { pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
    }
}

// MARK: - Split

struct SplitPDFView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.SplitPDF) -> Void
    @State private var options = ToolOptions.SplitPDF()
    @State private var pageCount = 0

    private var parts: Result<Int, WheelError> {
        switch options.mode {
        case .everyPage: return .success(pageCount)
        case .everyN: return .success(Int(ceil(Double(pageCount) / Double(max(1, options.every)))))
        case .ranges:
            do { return .success(try PDFTools.parseRanges(options.ranges, pageCount: pageCount).count) } catch let error as WheelError { return .failure(error) } catch { return .failure(WheelError("Invalid ranges.")) }
        }
    }

    var body: some View {
        let result = parts
        let count = (try? result.get()) ?? 0
        let message: String? = { if case .failure(let e) = result { return e.message }; return nil }()
        ToolFrame(primary: "Split into \(count) PDF\(count == 1 ? "" : "s")", canApply: count >= 1 && pageCount > 0,
                  note: message ?? "The parts are saved in one folder next to the PDF.", cancel: close, apply: { apply(options) }) {
            Form {
                LabeledContent("Pages", value: "\(pageCount)")
                Picker("Split", selection: $options.mode) { ForEach(ToolOptions.SplitPDF.Mode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.radioGroup)
                if options.mode == .everyN {
                    Stepper("Every \(options.every) pages", value: $options.every, in: 1...max(1, pageCount))
                }
                if options.mode == .ranges {
                    TextField("Ranges", text: $options.ranges, prompt: Text("1-3, 4, 5-"))
                    Text("Separate ranges with commas. “5-” means page 5 to the end.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task { pageCount = PDFDocument(url: url)?.pageCount ?? 0 }
    }
}
