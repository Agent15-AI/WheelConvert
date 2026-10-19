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
    /// Items being worked on, by position in the selection: file name and progress 0…1.
    @Published var active: [Int: (name: String, progress: Double)] = [:]
    @Published var completed = 0
    @Published var failures: [(name: String, message: String)] = []
    @Published var outputs: [URL] = []
    var task: Task<Void, Never>?

    init(title: String, total: Int) {
        self.title = title
        self.total = total
    }

    var overallProgress: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(completed) + active.values.map(\.progress).reduce(0, +)) / Double(total))
    }

    var statusText: String {
        switch phase {
        case .running:
            let names = active.sorted { $0.key < $1.key }.map(\.value.name).joined(separator: ", ")
            return total > 1 ? "\(completed) of \(total) done — \(names)" : names
        case .finished: return outputs.count == 1 ? "Saved \(outputs[0].lastPathComponent)" : "Saved \(outputs.count) items"
        case .failed: return failures.count == total ? (total == 1 ? "Couldn’t finish" : "Operation failed") : "Finished with errors"
        case .cancelled: return "Cancelled"
        }
    }

    /// A late or out-of-order update must not move an item backwards or revive a finished one.
    func report(_ index: Int, _ fraction: Double) {
        guard let item = active[index] else { return }
        active[index] = (item.name, max(item.progress, min(1, fraction)))
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

    /// Converts each file to the target format. Await `task` on the result to wait for the outputs.
    @discardableResult
    func convert(_ urls: [URL], to target: FileFormat) -> JobState {
        let options = AppSettings.shared.options(for: target)
        let hardwareVideo = [.mp4, .mov, .mkv].contains(target) && urls.contains { FileFormat.detect($0)?.category == .video }
        return run(title: "Converting to \(target.title)", items: urls, parallel: Self.parallelLimit(hardwareVideo: hardwareVideo)) { url, progress in
            try await Converter.convert(url, to: target, options: options, progress: progress)
        }
    }

    /// How many files of a batch run at once: one per two cores, two to four. H.264/HEVC encoding
    /// runs one file at a time: every file shares the Mac's hardware encoder, so parallel jobs only
    /// take turns (on an M4, four 1080p files took 16.6 s one by one and 16.2 s four at once, while
    /// software VP9 went from 91 s to 64 s).
    static func parallelLimit(hardwareVideo: Bool) -> Int {
        hardwareVideo ? 1 : max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Runs work over the items, up to `parallel` at a time. Each item reports its own progress and
    /// returns what it saved; outputs and failures are listed in selection order.
    @discardableResult
    func run(title: String, items: [URL], parallel: Int = 1, work: @escaping (URL, @escaping (Double) -> Void) async throws -> [URL]) -> JobState {
        let job = JobState(title: title, total: items.count)
        start(job) {
            var saved: [Int: [URL]] = [:]
            var failed: [Int: (name: String, message: String)] = [:]
            @MainActor func record(_ index: Int, _ result: Result<[URL], Error>) {
                let name = job.active[index]?.name ?? items[index].lastPathComponent
                job.active[index] = nil
                job.completed += 1
                switch result {
                case .success(let urls): saved[index] = urls
                case .failure(let error) where !(error is CancellationError): failed[index] = (name, error.localizedDescription)
                case .failure: break
                }
            }
            await withTaskGroup(of: (Int, Result<[URL], Error>).self) { group in
                for (index, url) in items.enumerated() {
                    if index >= max(1, parallel), let done = await group.next() { record(done.0, done.1) }
                    if Task.isCancelled { break }
                    job.active[index] = (url.lastPathComponent, 0)
                    group.addTask {
                        do {
                            return (index, .success(try await work(url) { fraction in Task { @MainActor in job.report(index, fraction) } }))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for await done in group { record(done.0, done.1) }
            }
            job.outputs = saved.sorted { $0.key < $1.key }.flatMap(\.value)
            job.failures = failed.sorted { $0.key < $1.key }.map(\.value)
        }
        return job
    }

    /// One job over the whole selection (merge, join, collage…), saving a single result set.
    func runBatch(title: String, items: [URL], work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        let job = JobState(title: title, total: 1)
        let name = items.count == 1 ? items[0].lastPathComponent : "\(items.count) files"
        job.active[0] = (name, 0)
        start(job) {
            do {
                job.outputs = try await work { fraction in Task { @MainActor in job.report(0, fraction) } }
            } catch is CancellationError {
            } catch {
                job.failures.append((name, error.localizedDescription))
            }
        }
    }

    /// Scripted runs (`--batch`) stay off screen: no panels, no Finder windows.
    private var showsUI: Bool { NSApp.activationPolicy() != .prohibited }

    private func start(_ job: JobState, _ body: @escaping @MainActor () async -> Void) {
        jobs.append(job)
        if showsUI {
            let panel = ProgressPanelController(job: job, stackIndex: panels.count)
            panels[job.id] = panel
            panel.show()
        }
        job.task = Task { @MainActor in
            await body()
            finish(job)
        }
    }

    private func finish(_ job: JobState) {
        objectWillChange.send() // isBusy changes with the phase
        if job.task?.isCancelled == true && job.failures.isEmpty {
            job.phase = .cancelled
        } else {
            job.phase = job.failures.isEmpty ? .finished : .failed
        }
        job.active = [:]
        if !job.outputs.isEmpty && AppSettings.shared.revealResults && showsUI {
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
