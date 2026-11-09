import AppKit
import UniformTypeIdentifiers

/// What a drag or a Services request carries. Files win, then picture bytes, then links, then text: a
/// browser's picture drag also carries the picture's address as a link (docs/WHEEL-OF-ANYTHING-DECISIONS.md).
enum DragContent: Equatable {
    case files([URL])
    /// Picture bytes offered by a browser or app, not on disk yet.
    case image(type: UTType, name: String)
    /// A web address (http or https).
    case link(URL)
    /// Text, with its formatting (RTF or HTML) when the drag carried it.
    case text(String, rich: RichText?)

    struct RichText: Equatable {
        let data: Data
        let isHTML: Bool
    }

    var files: [URL] {
        if case .files(let urls) = self { urls } else { [] }
    }

    /// Encoded picture types, original encodings first; Safari also offers a much larger TIFF conversion.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .init("public.jpeg"), .init("public.heic"), .init("com.compuserve.gif"), .tiff]

    /// Reads a pasteboard without loading picture bytes (`savingImage` does that on drop).
    static func read(_ pasteboard: NSPasteboard) -> DragContent? {
        let urls = DragMonitor.fileURLs(on: pasteboard)
        if !urls.isEmpty { return .files(urls) }
        guard let types = pasteboard.types else { return nil }
        if let type = imageTypes.first(where: types.contains), let uti = UTType(type.rawValue) {
            return .image(type: uti, name: imageName(pasteboard.string(forType: .URL), type: uti))
        }
        if let link = pasteboard.string(forType: .URL).flatMap(webLink) { return .link(link) }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let link = webLink(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return .link(link) }
        let rich = pasteboard.data(forType: .rtf).map { RichText(data: $0, isHTML: false) }
            ?? pasteboard.data(forType: .html).map { RichText(data: $0, isHTML: true) }
        return .text(text, rich: rich)
    }

    /// A single http(s) address with a host, and nothing else.
    static func webLink(_ string: String) -> URL? {
        guard !string.contains(where: \.isWhitespace), let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The file name for a dropped picture: the last part of its address when that looks like a picture name.
    static func imageName(_ address: String?, type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? "png"
        if let last = address.flatMap(URL.init(string:))?.lastPathComponent, !last.isEmpty, last != "/" {
            let base = (last as NSString).deletingPathExtension
            if !base.isEmpty { return OutputNaming.sanitize(base) + "." + ext }
        }
        return String(localized: "Image") + "." + ext
    }

    // MARK: Files for content that has none

    /// Dropped pictures are written here so the jobs can treat them like files. Results never go here:
    /// `Publisher.destinationDirectory` skips it and saves them where Settings says (Downloads by default).
    static let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("WheelConvert-Dropped", isDirectory: true)

    static func isScratch(_ directory: URL) -> Bool {
        directory.standardizedFileURL.path.hasPrefix(scratchRoot.standardizedFileURL.path + "/")
    }

    /// Writes the picture bytes on a pasteboard to a private file.
    static func savingImage(from pasteboard: NSPasteboard, name: String) throws -> URL {
        guard let type = imageTypes.first(where: { pasteboard.types?.contains($0) == true }),
              let data = pasteboard.data(forType: type), !data.isEmpty else {
            throw WheelError("The picture’s data wasn’t available.")
        }
        let folder = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The content ready for a petal: pictures become files, everything else is already complete.
    func materialized(from pasteboard: NSPasteboard) throws -> DragContent {
        guard case .image(_, let name) = self else { return self }
        return .files([try Self.savingImage(from: pasteboard, name: name)])
    }

    /// Developer modes and tests: file paths, `text:<file with UTF-8 text>`, `html:<file>` or `link:<address>`,
    /// up to the first `-option` (such as a `-key value` pair for the settings).
    static func arguments(_ all: [String]) throws -> DragContent {
        let args = Array(all.prefix { !$0.hasPrefix("-") })
        if let first = args.first, args.count == 1 {
            if first.hasPrefix("link:") {
                guard let link = webLink(String(first.dropFirst(5))) else { throw WheelError("Not a web link.") }
                return .link(link)
            }
            for prefix in ["text:", "html:"] where first.hasPrefix(prefix) {
                let data = try Data(contentsOf: URL(fileURLWithPath: String(first.dropFirst(prefix.count))))
                let html = prefix == "html:"
                let text = html ? (PlainTextWriter.write(StructuredDocument(blocks: HTMLReader(imageLoader: { _ in nil }).parse(data)))) : String(decoding: data, as: UTF8.self)
                // Like a real drag: whitespace alone is nothing to work on.
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WheelError("Nothing to work on.") }
                return .text(text, rich: html ? RichText(data: data, isHTML: true) : nil)
            }
        }
        guard !args.isEmpty else { throw WheelError("Nothing to work on.") }
        return .files(args.map { URL(fileURLWithPath: $0).standardizedFileURL })
    }
}
