import AppKit
import SwiftUI

/// Opens the right window (or runs immediately) for a tool chosen on the wheel.
@MainActor
enum ToolLauncher {
    private static var windows: [UUID: ToolWindowController] = [:]

    static func open(_ tool: ToolKind, urls: [URL]) {
        switch tool {
        case .muteVideo:
            ToolRunner.submit(tool, request: .mute, urls: urls)
        case .extractAudio:
            ToolRunner.submit(tool, request: .extractAudio, urls: urls)
        case .extractArchive:
            ToolRunner.submit(tool, request: .extract, urls: urls)
        case .extractText:
            ToolRunner.submit(tool, request: .extractText, urls: urls)
        case .readQRCode:
            QRResultsController.show(urls)
        default:
            let id = UUID()
            let controller = ToolWindowController(tool: tool, urls: urls) { windows[id] = nil }
            windows[id] = controller
            controller.show()
        }
    }
}

/// A floating window hosting one tool's SwiftUI view.
@MainActor
final class ToolWindowController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let onClose: () -> Void

    init(tool: ToolKind, urls: [URL], onClose: @escaping () -> Void) {
        self.onClose = onClose
        let size = Self.size(for: tool)
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = tool.title
        window.subtitle = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(size.width, 420), height: min(size.height, 320))
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        let close: () -> Void = { [weak self] in self?.window.close() }
        let root = ToolRoot(tool: tool, urls: urls, close: close)
        window.contentView = NSHostingView(rootView: root)
        window.center()
    }

    static func size(for tool: ToolKind) -> NSSize {
        switch tool {
        case .compress, .splitPDF, .normalizeAudio, .audioChannels, .changeVideoSpeed: NSSize(width: 520, height: 470)
        case .removeMetadata: NSSize(width: 620, height: 600)
        case .createPDF, .mergePDF, .joinVideos: NSSize(width: 520, height: 520)
        case .organizePDF: NSSize(width: 860, height: 640)
        case .audioToVideo: NSSize(width: 620, height: 560)
        default: NSSize(width: 900, height: 660)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Picks the view for a tool. Each view ends by calling `submit` with a configured request.
struct ToolRoot: View {
    let tool: ToolKind
    let urls: [URL]
    let close: () -> Void

    var body: some View {
        content
            .frame(minWidth: 380, minHeight: 280)
    }

    /// Closes the window once the job starts; it stays open if choosing where to save is cancelled.
    private func submit(_ request: ToolRequest, urls override: [URL]? = nil) {
        if ToolRunner.submit(tool, request: request, urls: override ?? urls) != nil { close() }
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .compress: CompressView(urls: urls, close: close) { submit(.compress($0)) }
        case .removeMetadata: MetadataView(urls: urls, close: close) { submit(.metadata($0)) }
        case .editImage: EditPhotoView(url: urls[0], close: close) { submit(.editImage($0)) }
        case .annotateImage: AnnotateView(url: urls[0], close: close) { submit(.annotate($0)) }
        case .frameImage: BackgroundView(urls: urls, close: close) { submit(.frame($0)) }
        case .cropImage: CropView(urls: urls, close: close) { submit(.crop($0)) }
        case .redactImage: RedactPhotoView(url: urls[0], close: close) { submit(.redactImage($0)) }
        case .createPDF: OrderToolView(urls: urls, primary: "Create PDF", note: "Each image becomes one page, in this order.", close: close) { submit(.createPDF(.init(paths: $0.map(\.path))), urls: $0) }
        case .createCollage: CollageView(urls: urls, close: close) { submit(.collage($0)) }
        case .trimVideo, .trimAudio: TrimView(urls: urls, isAudio: tool == .trimAudio, close: close) { submit(.trim($0)) }
        case .cropVideo: CropVideoView(url: urls[0], close: close) { submit(.cropVideo($0)) }
        case .changeVideoSpeed: SpeedView(url: urls[0], close: close) { submit(.speed($0)) }
        case .joinVideos: OrderToolView(urls: urls, primary: "Join Videos", note: "Clips play in this order. The first clip sets the size.", close: close) { submit(.join(.init(paths: $0.map(\.path))), urls: $0) }
        case .videoSnapshots: SnapshotsView(url: urls[0], close: close) { submit(.snapshots($0)) }
        case .splitVideo: SplitVideoView(url: urls[0], close: close) { submit(.split($0)) }
        case .redactVideo: RedactVideoView(url: urls[0], close: close) { submit(.redactVideo($0)) }
        case .normalizeAudio: NormalizeView(urls: urls, close: close) { submit(.normalize($0)) }
        case .audioToVideo: VisualizerView(url: urls[0], close: close) { submit(.visualize($0)) }
        case .audioChannels: ChannelsView(urls: urls, close: close) { submit(.channels($0)) }
        case .redactAudio: BleepView(url: urls[0], close: close) { submit(.bleep($0)) }
        case .mergePDF: OrderToolView(urls: urls, primary: "Merge PDFs", note: "Documents are combined in this order.", close: close) { submit(.mergePDF(.init(paths: $0.map(\.path))), urls: $0) }
        case .organizePDF: OrganizePDFView(url: urls[0], close: close) { submit(.organizePDF($0)) }
        case .splitPDF: SplitPDFView(url: urls[0], close: close) { submit(.splitPDF($0)) }
        case .muteVideo, .extractAudio, .extractArchive, .readQRCode, .extractText: EmptyView()
        }
    }
}

/// Simple reorder-then-run tools (Create PDF, Join Videos, Merge PDFs).
struct OrderToolView: View {
    @State var urls: [URL]
    let primary: String
    let note: String
    let close: () -> Void
    let apply: ([URL]) -> Void

    var body: some View {
        ToolFrame(primary: primary, canApply: urls.count >= 1, note: note, cancel: close, apply: { apply(urls) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Drag to reorder").foregroundStyle(.secondary)
                    Spacer()
                    Button("Sort by Name") { urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
                        .help("Order the files by name, as Finder lists them")
                }
                OrderList(urls: $urls)
            }
            .padding(18)
        }
    }
}
