import Foundation

/// The last results WheelConvert saved, newest first, for the menu bar menu.
enum RecentResults {
    static let limit = 10
    private static let key = "recentResults"
    /// Swapped out by the unit tests.
    static var store = UserDefaults.standard

    /// Saved results that still exist.
    static var urls: [URL] {
        (store.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ new: [URL]) {
        guard !new.isEmpty else { return }
        let paths = new.reversed().map(\.path)
        let kept = (store.stringArray(forKey: key) ?? []).filter { !paths.contains($0) }
        store.set(Array((paths + kept).prefix(limit)), forKey: key)
    }

    static func remove(_ url: URL) {
        store.set((store.stringArray(forKey: key) ?? []).filter { $0 != url.path }, forKey: key)
    }

    static func clear() { store.removeObject(forKey: key) }
}
