import AppKit
import SwiftUI

/// Observable state of one running job, shown in its progress panel.
@MainActor
final class JobState: ObservableObject, Identifiable {
    enum Phase: Equatable { case running, finished, failed, cancelled }

    let id = UUID()
    let title: String
    let total: Int
    @Published var phase: Phase = .running
    @Published var currentName = ""
    @Published var currentIndex = 0
    @Published var itemProgress: Double = 0
    @Published var failures: [(name: String, message: String)] = []
    @Published var outputs: [URL] = []
    var task: Task<Void, Never>?

    init(title: String, total: Int) {
        self.title = title
        self.total = total
    }

    var overallProgress: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(currentIndex) + itemProgress) / Double(total))
    }

    var statusText: String {
        switch phase {
        case .running: total > 1 ? "\(min(currentIndex + 1, total)) of \(total) — \(currentName)" : currentName
        case .finished: outputs.count == 1 ? "Saved \(outputs[0].lastPathComponent)" : "Saved \(outputs.count) items"
        case .failed: failures.count == total ? (total == 1 ? "Couldn’t finish" : "Operation failed") : "Finished with errors"
        case .cancelled: "Cancelled"
        }
    }

    func cancel() { task?.cancel() }
}

/// Runs conversions and tools, one progress panel per job, and reveals results in Finder.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    @Published private(set) var jobs: [JobState] = []
    private var panels: [UUID: ProgressPanelController] = [:]

    var isBusy: Bool { jobs.contains { $0.phase == .running } }

    /// Converts each file to the target format.
    func convert(_ urls: [URL], to target: FileFormat) {
        let options = AppSettings.shared.options(for: target)
        run(title: "Converting to \(target.title)", items: urls) { url, progress in
            try await Converter.convert(url, to: target, options: options, progress: progress)
        }
    }

    /// Runs work item by item. Each item reports its own progress and returns what it saved.
    func run(title: String, items: [URL], work: @escaping (URL, @escaping (Double) -> Void) async throws -> [URL]) {
        let job = JobState(title: title, total: items.count)
        start(job) {
            for (index, url) in items.enumerated() {
                if Task.isCancelled { break }
                job.currentIndex = index
                job.currentName = url.lastPathComponent
                job.itemProgress = 0
                do {
                    let outputs = try await work(url) { [weak job] fraction in
                        Task { @MainActor in job?.itemProgress = max(job?.itemProgress ?? 0, min(1, fraction)) }
                    }
                    job.outputs += outputs
                } catch is CancellationError {
                    break
                } catch {
                    job.failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }
        }
    }

    /// One job over the whole selection (merge, join, collage…), saving a single result set.
    func runBatch(title: String, items: [URL], work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        let job = JobState(title: title, total: 1)
        job.currentName = items.count == 1 ? items[0].lastPathComponent : "\(items.count) files"
        start(job) {
            do {
                job.outputs = try await work { [weak job] fraction in
                    Task { @MainActor in job?.itemProgress = max(job?.itemProgress ?? 0, min(1, fraction)) }
                }
            } catch is CancellationError {
            } catch {
                job.failures.append((job.currentName, error.localizedDescription))
            }
        }
    }

    private func start(_ job: JobState, _ body: @escaping @MainActor () async -> Void) {
        jobs.append(job)
        let panel = ProgressPanelController(job: job, stackIndex: panels.count)
        panels[job.id] = panel
        panel.show()
        job.task = Task { @MainActor in
            await body()
            finish(job)
        }
    }

    private func finish(_ job: JobState) {
        if job.task?.isCancelled == true && job.failures.isEmpty {
            job.phase = .cancelled
        } else {
            job.phase = job.failures.isEmpty ? .finished : .failed
        }
        job.itemProgress = 1
        job.currentIndex = job.total
        if !job.outputs.isEmpty && AppSettings.shared.revealResults {
            NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
        }
        if job.phase == .finished || job.phase == .cancelled {
            DispatchQueue.main.asyncAfter(deadline: .now() + (job.phase == .finished ? 1.2 : 0.4)) { [weak self] in self?.close(job) }
        }
    }

    func close(_ job: JobState) {
        panels[job.id]?.close()
        panels[job.id] = nil
        jobs.removeAll { $0.id == job.id }
        if job.phase == .running { job.cancel() }
        restack()
    }

    private func restack() {
        for (index, panel) in panels.values.sorted(by: { $0.created < $1.created }).enumerated() { panel.move(to: index) }
    }
}
