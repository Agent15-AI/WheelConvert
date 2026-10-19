import CoreServices
import Foundation

/// Paths WheelConvert saved while running. Watch folders skip them, so a folder never processes its
/// own results, even when a preset saves into the folder it watches.
enum OutputLedger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: Set<String> = []

    static func record(_ url: URL) { lock.withLock { _ = paths.insert(url.resolvingSymlinksInPath().path) } }
    static func contains(_ url: URL) -> Bool { lock.withLock { paths.contains(url.resolvingSymlinksInPath().path) } }
}

/// Runs a preset on each new file in the folders chosen in Settings → Watch Folders. A file waits until
/// its size has stopped changing; hidden files, downloads in progress and WheelConvert's own results
/// are skipped.
@MainActor
final class FolderWatcher {
    struct Watch {
        let folder: URL
        let preset: Preset
    }

    static let shared = FolderWatcher()
    /// Called with every job a watch folder starts (the --watch test mode collects them).
    var onJob: ((JobState) -> Void)?
    private var watches: [Watch] = []
    private var stream: FSEventStreamRef?
    private var timer: Timer?
    /// Files waiting to settle: their watch, last size and date, and since when they've been unchanged.
    private var pending: [String: (watch: Watch, signature: String, stableSince: Date?)] = [:]
    /// Files already handed to a preset, by path, size and date, so repeated events run them once.
    private var handled: Set<String> = []

    nonisolated static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "temp", "opdownload", "icloud"]

    /// Watches the enabled folders in Settings, following later changes.
    func followSettings() {
        let settings = AppSettings.shared
        watch(settings.watchFolders.filter(\.enabled).compactMap { folder in
            settings.presets.first { $0.id == folder.presetID }.map { Watch(folder: URL(fileURLWithPath: folder.path, isDirectory: true), preset: $0) }
        })
    }

    func watch(_ watches: [Watch]) {
        stopStream()
        self.watches = watches
        pending = pending.filter { entry in watches.contains { $0.folder.path == entry.value.watch.folder.path } }
        guard !watches.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { watcher.received(list, flagList) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, watches.map(\.folder.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let interesting = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
        for (path, flag) in zip(paths, flags) where flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 && flag & UInt32(interesting) != 0 {
            let url = URL(fileURLWithPath: path)
            // Only files placed directly in a watched folder; result folders and subfolders are left alone.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard let watch = watches.first(where: { $0.folder.resolvingSymlinksInPath().path == parent }), Self.isCandidate(url) else { continue }
            pending[path] = (watch, Self.signature(url) ?? "", nil)
        }
        if !pending.isEmpty && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.settle() } }
        }
    }

    nonisolated static func isCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return !name.hasPrefix(".") && !partialExtensions.contains(url.pathExtension.lowercased()) && !OutputLedger.contains(url)
    }

    /// Finder dates a file it is still copying January 24, 1984.
    nonisolated private static let finderBusyDate = Date(timeIntervalSince1970: 443_779_200)

    /// Size and modification date ("0|…" while empty or still being copied by Finder); nil once the file is gone.
    nonisolated static func signature(_ url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, let size = values.fileSize else { return nil }
        let busy = values.creationDate == finderBusyDate
        return "\(busy ? 0 : size)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Starts the files that have stayed unchanged for three seconds, one job per watch folder.
    private func settle() {
        var ready: [String: (watch: Watch, urls: [URL])] = [:]
        for (path, entry) in pending {
            let url = URL(fileURLWithPath: path)
            guard Self.isCandidate(url), let signature = Self.signature(url) else { pending[path] = nil; continue }
            if signature != entry.signature || signature.hasPrefix("0|") {
                pending[path] = (entry.watch, signature, nil)
            } else if let since = entry.stableSince {
                guard Date().timeIntervalSince(since) >= 3 else { continue }
                pending[path] = nil
                guard handled.insert(path + "|" + signature).inserted, entry.watch.preset.applies(to: [url]) else { continue }
                ready[entry.watch.folder.path, default: (entry.watch, [])].urls.append(url)
            } else {
                pending[path] = (entry.watch, signature, Date())
            }
        }
        for (_, batch) in ready {
            let urls = batch.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if let job = batch.watch.preset.run(on: urls, canAsk: false) { onJob?(job) }
        }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
