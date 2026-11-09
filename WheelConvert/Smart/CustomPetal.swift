import AppKit

/// A petal the person adds in Settings → Custom. It runs only what they typed there; nothing is ever
/// imported, and the exact action is shown for approval before its first run and after every change.
struct CustomPetal: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case shortcut, shell, openWith, urlScheme
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shortcut: String(localized: "Run a Shortcut")
            case .shell: String(localized: "Run a Shell Script")
            case .openWith: String(localized: "Open With an App")
            case .urlScheme: String(localized: "Open a URL")
            }
        }
    }

    var id = UUID()
    var name = ""
    /// An SF Symbol name or an emoji.
    var icon = "star"
    var acceptsPictures = false
    var acceptsText = false
    var acceptsLinks = false
    var acceptsFiles = true
    /// File extensions the petal is for, separated by commas or spaces; empty means any file.
    var extensions = ""
    var kind = Kind.shell
    var shortcutName = ""
    var script = ""
    var appPath = ""
    /// With {path}, {text} or {url} where the item goes, percent-encoded.
    var urlTemplate = ""
    var timeoutSeconds = 120
    var showOnWheel = true
    /// The action text the person approved; a petal whose action changed since asks again.
    var approved: String?

    /// Exactly what runs, as shown in the approval dialog.
    var actionDescription: String {
        switch kind {
        case .shortcut: String(localized: "Shortcut: \(shortcutName)")
        case .shell: String(localized: "zsh script (\(timeoutSeconds) s limit):\n\(script)")
        case .openWith: String(localized: "Open with: \(appPath)")
        case .urlScheme: String(localized: "URL: \(urlTemplate)")
        }
    }

    var needsApproval: Bool { approved != actionDescription }

    var extensionList: [String] {
        extensions.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0.drop(while: { $0 == "." })) }.filter { !$0.isEmpty }
    }

    /// Whether the petal shows for this content.
    func accepts(_ content: DragContent) -> Bool {
        guard showOnWheel, isComplete else { return false }
        switch content {
        case .files(let urls):
            if acceptsPictures, urls.allSatisfy({ FileFormat.detect($0).map(ToolKind.rasterImages.contains) ?? false }) { return true }
            guard acceptsFiles else { return false }
            let wanted = extensionList
            return wanted.isEmpty || urls.allSatisfy { wanted.contains($0.pathExtension.lowercased()) }
        case .image: return acceptsPictures
        case .link: return acceptsLinks
        case .text: return acceptsText
        }
    }

    /// Filled in enough to run.
    var isComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .shortcut: return !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        case .shell: return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openWith: return appPath.hasSuffix(".app")
        case .urlScheme: return Self.scheme(of: urlTemplate) != nil
        }
    }

    /// Emoji icons go in front of the label; SF Symbols are drawn above it like the built-in petals.
    var symbol: String? { NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil ? icon : nil }
    var wheelLabel: String {
        let text = String(name.uppercased().prefix(12))
        return symbol == nil && !icon.isEmpty ? "\(icon.prefix(2)) \(text)" : text
    }

    // MARK: URL templates

    /// The template's scheme, when it's one a petal may open: not file: or javascript:, which could read or run
    /// things on the Mac.
    static func scheme(of template: String) -> String? {
        guard let colon = template.firstIndex(of: ":") else { return nil }
        let scheme = template[..<colon].lowercased()
        guard let first = scheme.first, first.isLetter, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
              !["file", "javascript", "data"].contains(scheme) else { return nil }
        return scheme
    }

    /// The URL with the item in place of {path}, {text} and {url}. Values are percent-encoded so they can't
    /// change the URL's structure (no extra parameters, fragments or schemes).
    static func url(from template: String, path: String, text: String, link: String) -> URL? {
        guard let scheme = scheme(of: template) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let filled = template.replacingOccurrences(of: "{path}", with: encode(path))
            .replacingOccurrences(of: "{text}", with: encode(text))
            .replacingOccurrences(of: "{url}", with: encode(link))
        guard let url = URL(string: filled), url.scheme?.lowercased() == scheme else { return nil }
        return url
    }
}
