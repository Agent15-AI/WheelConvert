import AppKit
import CryptoKit
import FoundationModels
import NaturalLanguage
import Translation

/// The smart wheel's own petals. It also reuses existing tools and actions (see `petals(for:)`).
enum SmartAction: String, CaseIterable, Codable, Identifiable {
    case removeBackground, palette, stripMetadata, resize
    case sha256, md5, verifyChecksum, reveal, zip
    case makeQRCode, copyPlain, copyMarkdown, copyQuoted, countWords, translate, summarize, speak, saveText
    case cleanLink, saveLink, openPrivate

    var id: String { rawValue }

    var title: String { String(localized: titleKey) }

    private var titleKey: String.LocalizationValue {
        switch self {
        case .removeBackground: "Remove Background"
        case .palette: "Copy Colors"
        case .stripMetadata: "Remove Location and Metadata"
        case .resize: "Resize"
        case .sha256: "Copy SHA-256"
        case .md5: "Copy MD5"
        case .verifyChecksum: "Verify Checksum"
        case .reveal: "Show in Finder"
        case .zip: "Make Zip to Share"
        case .makeQRCode: "Make QR Code"
        case .copyPlain: "Copy as Plain Text"
        case .copyMarkdown: "Copy as Markdown"
        case .copyQuoted: "Copy as Quote"
        case .countWords: "Count Words"
        case .translate: "Translate"
        case .summarize: "Summarize"
        case .speak: "Speak"
        case .saveText: "Save as File"
        case .cleanLink: "Copy Clean Link"
        case .saveLink: "Save Link File"
        case .openPrivate: "Open in Private Window"
        }
    }

    var wheelLabel: String { String(localized: wheelLabelKey) }

    private var wheelLabelKey: String.LocalizationValue {
        switch self {
        case .removeBackground: "NO BG"
        case .palette: "COLORS"
        case .stripMetadata: "STRIP"
        case .resize: "RESIZE"
        case .sha256: "SHA-256"
        case .md5: "MD5"
        case .verifyChecksum: "VERIFY"
        case .reveal: "REVEAL"
        case .zip: "ZIP"
        case .makeQRCode: "QR CODE"
        case .copyPlain: "PLAIN"
        case .copyMarkdown: "MARKDOWN"
        case .copyQuoted: "QUOTE"
        case .countWords: "COUNT"
        case .translate: "TRANSLATE"
        case .summarize: "SUMMARY"
        case .speak: "SPEAK"
        case .saveText: "SAVE"
        case .cleanLink: "CLEAN"
        case .saveLink: "SAVE LINK"
        case .openPrivate: "PRIVATE"
        }
    }

    var symbol: String {
        switch self {
        case .removeBackground: "person.crop.rectangle"
        case .palette: "paintpalette"
        case .stripMetadata: "location.slash"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .sha256, .md5: "number"
        case .verifyChecksum: "checkmark.seal"
        case .reveal: "magnifyingglass"
        case .zip: "doc.zipper"
        case .makeQRCode: "qrcode"
        case .copyPlain: "doc.plaintext"
        case .copyMarkdown: "number.square"
        case .copyQuoted: "text.quote"
        case .countWords: "textformat.123"
        case .translate: "translate"
        case .summarize: "text.append"
        case .speak: "speaker.wave.2"
        case .saveText: "square.and.arrow.down"
        case .cleanLink: "link.badge.plus"
        case .saveLink: "link"
        case .openPrivate: "hand.raised"
        }
    }

    /// At most this many petals; the ring grows past 8 the way the other wheels do.
    static let petalLimit = 12

    /// Petals that work for this content on this Mac, in wheel order. Cheap: no file is read.
    static func petals(for content: DragContent) -> [WheelItem.Action] {
        var petals: [WheelItem.Action] = []
        switch content {
        case .files(let urls):
            let folders = urls.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            let formats = urls.map(FileFormat.detect)
            if !folders.contains(true), formats.allSatisfy({ $0.map(ToolKind.rasterImages.contains) ?? false }) {
                petals += imagePetals(single: urls.count == 1)
            }
            if !folders.contains(true) { petals += [.smart(.sha256), .smart(.md5)] }
            if urls.count == 1, folders == [false] { petals.append(.smart(.verifyChecksum)) }
            petals += [.smart(.reveal), .fileAction(.copyPath), .smart(.zip)]
        case .image:
            petals = imagePetals(single: true)
        case .link:
            petals = [.smart(.cleanLink), .smart(.makeQRCode), .smart(.saveLink)]
            if PrivateBrowsing.launchArguments(for: PrivateBrowsing.defaultBrowser()) != nil { petals.append(.smart(.openPrivate)) }
        case .text(let text, let rich):
            if QRCode.fits(text) { petals.append(.smart(.makeQRCode)) }
            petals.append(.smart(.copyPlain))
            if rich != nil { petals.append(.smart(.copyMarkdown)) }
            petals += [.smart(.copyQuoted), .smart(.countWords)]
            if OnDevice.canTranslate(text) { petals.append(.smart(.translate)) }
            if OnDevice.canSummarize(text) { petals.append(.smart(.summarize)) }
            petals += [.smart(.speak), .smart(.saveText)]
        }
        return Array(petals.prefix(petalLimit))
    }

    private static func imagePetals(single: Bool) -> [WheelItem.Action] {
        var petals: [WheelItem.Action] = []
        if #available(macOS 14, *) { petals.append(.smart(.removeBackground)) }
        petals += [.tool(.extractText), .tool(.readQRCode)]
        if single { petals.append(.smart(.palette)) }
        petals += [.smart(.stripMetadata), .smart(.resize)]
        return petals
    }
}

// MARK: - Links

enum LinkCleaner {
    /// Query parameters that only track where a click came from. Kept short on purpose: removing a parameter a
    /// site needs would break the link.
    static let trackingNames: Set<String> = ["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
                                             "_hsenc", "_hsmi", "mkt_tok", "ttclid", "twclid", "li_fat_id", "srsltid", "oly_anon_id", "oly_enc_id", "vero_id", "_ga", "_gl"]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || trackingNames.contains(lower)
    }

    /// The link without tracking parameters; everything else (order, encoding, fragment) stays as it was.
    static func clean(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.percentEncodedQueryItems else { return url }
        let kept = items.filter { !isTracking($0.name.removingPercentEncoding ?? $0.name) }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }
}

enum PrivateBrowsing {
    static func defaultBrowser() -> String? {
        URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// The launch argument that opens a private window, for browsers that have one. Safari has none.
    static func launchArguments(for bundleID: String?) -> String? {
        switch bundleID {
        case "com.google.Chrome", "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium": "--incognito"
        case "com.microsoft.edgemac": "--inprivate"
        case "com.operasoftware.Opera", "com.operasoftware.OperaGX": "--private"
        case "org.mozilla.firefox": "-private-window"
        default: nil
        }
    }
}

// MARK: - Text

enum TextTools {
    /// Every line as a Markdown quote; blank lines stay inside the quote.
    static func quoted(_ text: String) -> String {
        text.trimmingCharacters(in: .newlines).components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    static func markdown(_ rich: DragContent.RichText) -> String? {
        let document: StructuredDocument
        if rich.isHTML {
            document = StructuredDocument(blocks: HTMLReader(imageLoader: { _ in nil }).parse(rich.data))
        } else {
            guard let attributed = try? NSAttributedString(data: rich.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return nil }
            document = RichTextReader.document(from: attributed)
        }
        var writer = MarkdownWriter()
        let text = writer.write(document).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    struct Counts: Equatable {
        var words = 0, characters = 0, lines = 0
    }

    /// Words as the language's own rules split them (CJK has no spaces), user-perceived characters, and lines.
    static func counts(_ text: String) -> Counts {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var counts = Counts(characters: text.count, lines: text.isEmpty ? 0 : text.trimmingCharacters(in: .newlines).components(separatedBy: .newlines).count)
        // Emoji and symbols are tokens too, but not words.
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { counts.words += 1 }
            return true
        }
        return counts
    }

    /// A file name from the first line, like a text clipping's.
    static func fileName(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        let short = line.count > 40 ? String(line.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : line
        return OutputNaming.sanitize(short.isEmpty ? String(localized: "Text") : short)
    }
}

enum QRCode {
    /// Bytes a QR code holds at error correction M (version 40).
    static let capacity = 2331

    static func fits(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= capacity }

    /// A black-on-white PNG, scaled up without smoothing so the modules stay sharp.
    static func png(_ text: String) throws -> Data {
        guard fits(text), let filter = CIFilter(name: "CIQRCodeGenerator") else { throw WheelError("This text is too long for a QR code.") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { throw WheelError("This text is too long for a QR code.") }
        let scale = max(4, (1024 / code.extent.width).rounded(.down))
        let image = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ImageTools.ciContext.createCGImage(image, from: image.extent) else { throw WheelError("The QR code couldn’t be drawn.") }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw WheelError("The QR code couldn’t be drawn.") }
        return data
    }
}

// MARK: - Checksums

enum Checksum {
    enum Algorithm: String, CaseIterable {
        case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256", sha512 = "SHA-512"
        var hexLength: Int {
            switch self {
            case .md5: 32
            case .sha1: 40
            case .sha256: 64
            case .sha512: 128
            }
        }
    }

    /// Streams the file in 1 MB pieces, so any size works without loading it.
    static func hex(_ url: URL, _ algorithm: Algorithm, progress: (Double) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        var done = 0.0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            switch algorithm {
            case .md5: md5.update(data: chunk)
            case .sha1: sha1.update(data: chunk)
            case .sha256: sha256.update(data: chunk)
            case .sha512: sha512.update(data: chunk)
            }
            done += Double(chunk.count)
            if total > 0 { progress(done / total) }
        }
        let digest: any Digest = switch algorithm {
        case .md5: md5.finalize()
        case .sha1: sha1.finalize()
        case .sha256: sha256.finalize()
        case .sha512: sha512.finalize()
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The hex digest in pasted text such as "abc…", "SHA256 (file) = abc…" or "abc…  file", and its algorithm.
    static func expected(in text: String) -> (hex: String, algorithm: Algorithm)? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "=" || $0 == ":" }).map { $0.lowercased() }
        for word in words where word.allSatisfy(\.isHexDigit) {
            if let algorithm = Algorithm.allCases.first(where: { $0.hexLength == word.count }) { return (word, algorithm) }
        }
        return nil
    }
}

// MARK: - Pictures

enum Palette {
    /// The image's main colors, most common first, as #RRGGBB: pixels of a 256-pixel thumbnail are counted in
    /// 4,096 buckets, and each bucket is named by its most common exact color, so the answer is deterministic,
    /// cheap for huge pictures, and not smeared by the thumbnail's blended edges. Colors under 1% are ignored.
    static func colors(_ url: URL, count: Int = 5) throws -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw WheelError("The picture could not be read.")
        }
        let width = thumb.width, height = thumb.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WheelError("The picture could not be read.")
        }
        context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))
        var buckets: [Int: Int] = [:], exact: [Int: Int] = [:]
        var opaque = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            buckets[(r >> 4) << 8 | (g >> 4) << 4 | (b >> 4), default: 0] += 1
            exact[r << 16 | g << 8 | b, default: 0] += 1
            opaque += 1
        }
        guard opaque > 0 else { throw WheelError("The picture is fully transparent.") }
        var best: [Int: (color: Int, count: Int)] = [:]
        for (color, n) in exact {
            let key = (color >> 20 & 0xF) << 8 | (color >> 12 & 0xF) << 4 | (color >> 4 & 0xF)
            if let current = best[key], current.count > n || (current.count == n && current.color < color) { continue }
            best[key] = (color, n)
        }
        var chosen: [Int] = []
        // Most common first; ties broken by bucket so the order never depends on hashing.
        for (key, n) in buckets.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) where n * 100 >= opaque {
            guard let color = best[key]?.color else { continue }
            // Skip shades of a color already chosen.
            func distance(_ a: Int, _ b: Int) -> Int { abs((a >> 16) - (b >> 16)) + abs((a >> 8 & 0xFF) - (b >> 8 & 0xFF)) + abs((a & 0xFF) - (b & 0xFF)) }
            if chosen.contains(where: { distance($0, color) < 60 }) { continue }
            chosen.append(color)
            if chosen.count == count { break }
        }
        return chosen.map { String(format: "#%06X", $0) }
    }
}

// MARK: - On-device language features (macOS 26)

enum OnDevice {
    /// Languages whose translation into the person's language is installed on this Mac; refreshed in the
    /// background, because asking is asynchronous and the wheel has to open instantly.
    private(set) static var installedSources: Set<String> = []

    static var targetLanguage: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }

    static func language(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    static func canTranslate(_ text: String) -> Bool {
        guard #available(macOS 26, *), let source = language(of: text), let code = source.languageCode?.identifier,
              code != targetLanguage.languageCode?.identifier else { return false }
        return installedSources.contains(code)
    }

    static func refreshTranslationLanguages() async {
        guard #available(macOS 26, *) else { return }
        let availability = LanguageAvailability()
        let target = targetLanguage
        var installed: Set<String> = []
        for language in await availability.supportedLanguages {
            guard let code = language.languageCode?.identifier, code != target.languageCode?.identifier else { continue }
            if await availability.status(from: language, to: target) == .installed { installed.insert(code) }
        }
        await MainActor.run { [installed] in installedSources = installed }
    }

    @available(macOS 26, *)
    static func translate(_ text: String) async throws -> String {
        guard let source = language(of: text) else { throw WheelError("The text’s language couldn’t be recognized.") }
        let session = TranslationSession(installedSource: source, target: targetLanguage)
        return try await session.translate(text).targetText
    }

    /// The on-device model's context is about 4,000 tokens; longer text gets no Summarize petal.
    static let summaryLimit = 8000

    static func canSummarize(_ text: String) -> Bool {
        guard #available(macOS 26, *), text.count <= summaryLimit, TextTools.counts(String(text.prefix(summaryLimit))).words >= 40 else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    @available(macOS 26, *)
    static func summarize(_ text: String) async throws -> String {
        // The on-device system model only; FoundationModels' Private Cloud Compute model is never used.
        let session = LanguageModelSession(model: SystemLanguageModel.default,
                                           instructions: "Summarize the user's text in its own language in two to four sentences. Reply with the summary only.")
        return try await session.respond(to: text).content
    }
}
