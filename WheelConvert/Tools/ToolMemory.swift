import Foundation

/// Each tool's last applied settings, so its window opens the way it was last used. A variant keeps
/// separate settings where one tool serves different kinds of files (compressing photos vs. videos).
enum ToolMemory {
    /// Swapped out by the unit tests.
    static var store = UserDefaults.standard

    private static func key(_ tool: ToolKind, _ variant: String?) -> String {
        "toolSettings." + tool.rawValue + (variant.map { "." + $0 } ?? "")
    }

    static func isStored(_ tool: ToolKind, variant: String? = nil) -> Bool { store.data(forKey: key(tool, variant)) != nil }

    /// The remembered settings, with fields added since they were saved taken from `fallback`.
    static func load<T: Codable>(_ tool: ToolKind, variant: String? = nil, default fallback: T) -> T {
        guard let data = store.data(forKey: key(tool, variant)) else { return fallback }
        // Plain values (a Bool) aren't JSON objects, so they skip the field-by-field merge.
        return (try? JSONDecoder().decode(T.self, from: data, defaults: fallback)) ?? (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    static func save<T: Codable>(_ value: T, for tool: ToolKind, variant: String? = nil) {
        store.set(try? JSONEncoder().encode(value), forKey: key(tool, variant))
    }

    static func forget(_ tool: ToolKind, variant: String? = nil) { store.removeObject(forKey: key(tool, variant)) }
}
