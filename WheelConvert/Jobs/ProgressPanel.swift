import AppKit
import Combine
import SwiftUI

/// Small floating panel showing one job's progress, stacked under the menu bar.
@MainActor
final class ProgressPanelController {
    let created = Date()
    private let panel: NSPanel
    private let job: JobState
    private var stackIndex: Int
    private var observer: AnyCancellable?
    private let host: NSHostingView<ProgressPanelView>
    static let size = NSSize(width: 340, height: 92)

    init(job: JobState, stackIndex: Int) {
        self.job = job
        self.stackIndex = stackIndex
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = NSHostingView(rootView: ProgressPanelView(job: job, close: { JobCenter.shared.close(job) }))
        panel.contentView = host
        panel.setAccessibilityLabel("\(job.title) progress")
        observer = job.$phase.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.fit() }
    }

    /// Grows or shrinks to the content (error lists) while keeping the top edge in place.
    private func fit() {
        DispatchQueue.main.async { [self] in
            let size = host.fittingSize
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = NSSize(width: Self.size.width, height: size.height)
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    func show() {
        position()
        panel.orderFrontRegardless()
    }

    func move(to index: Int) {
        stackIndex = index
        position(animated: true)
    }

    private func position(animated: Bool = false) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size.width > 0 ? panel.frame.size : Self.size
        let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - 16 - (size.height + 10) * CGFloat(stackIndex + 1))
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }

    func close() { panel.orderOut(nil) }
}

struct ProgressPanelView: View {
    @ObservedObject var job: JobState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(job.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if job.phase == .running {
                    Button(action: job.cancel) { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel").accessibilityLabel("Cancel \(job.title)")
                }
            }
            if job.phase == .running {
                ProgressView(value: job.overallProgress).progressViewStyle(.linear).tint(Color(nsColor: Brand.accent))
                    .accessibilityLabel("Progress")
            }
            if job.phase == .failed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(job.failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.name): \(failure.message)").font(.system(size: 11)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 90)
                HStack {
                    Spacer()
                    if !job.outputs.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                    }
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var icon: some View {
        switch job.phase {
        case .running:
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        case .finished:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green).frame(width: 22)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange).frame(width: 22)
        case .cancelled:
            Image(systemName: "xmark.circle").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 22)
        }
    }
}
