import AVFoundation
import AppKit
import Vision

/// Runs a smart petal. Anything that can take a moment runs as a job (progress panel, Cancel, recent
/// results); clipboard actions finish at once with a confirmation bubble.
@MainActor
enum SmartRunner {
    /// - Returns: The work, for the developer modes to wait on; nil when it finished at once or didn't start.
    @discardableResult
    static func perform(_ action: SmartAction, content: DragContent, argument: String? = nil) -> Task<Void, Never>? {
        switch (action, content) {
        case (.removeBackground, .files(let urls)):
            guard #available(macOS 14, *) else { return nil }
            return wait(JobCenter.shared.run(title: String(localized: "Removing background"), items: urls, parallel: 2) { url, _ in [try await removeBackground(url)] })
        case (.palette, .files(let urls)):
            guard let url = urls.first else { return nil }
            return Task {
                do {
                    let colors = try await Task.detached { try Palette.colors(url) }.value
                    copy(colors.joined(separator: "\n"), confirm: String(localized: "Copied \(colors.count) colors"))
                } catch {
                    FileActions.alert(error.localizedDescription)
                }
            }
        case (.stripMetadata, .files(let urls)):
            return wait(ToolRunner.submit(.removeMetadata, request: .metadata(ToolOptions.Metadata(removeAll: true)), urls: urls))
        case (.resize, .files(let urls)):
            guard let edge = argument.flatMap(Int.init) ?? (headless ? nil : chooseSize()) else { return nil }
            return wait(JobCenter.shared.run(title: String(localized: "Resizing"), items: urls, parallel: 2) { url, _ in [try await resize(url, longestEdge: edge)] })
        case (.sha256, .files(let urls)), (.md5, .files(let urls)):
            return hash(urls, algorithm: action == .md5 ? .md5 : .sha256)
        case (.verifyChecksum, .files(let urls)):
            guard let url = urls.first, let expected = argument.flatMap(Checksum.expected(in:)) ?? (headless ? nil : askForChecksum(url)) else { return nil }
            return verify(url, expected: expected)
        case (.reveal, .files(let urls)):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case (.zip, .files(let urls)):
            return wait(JobCenter.shared.runBatch(title: String(localized: "Making zip"), items: urls) { _ in [try await zip(urls)] })
        case (.makeQRCode, .text(let text, _)):
            return saveLoose(title: String(localized: "Making QR code"), base: String(localized: "QR Code"), extension: "png") { try QRCode.png(text).write(to: $0) }
        case (.makeQRCode, .link(let url)):
            return saveLoose(title: String(localized: "Making QR code"), base: String(localized: "QR Code"), extension: "png") { try QRCode.png(url.absoluteString).write(to: $0) }
        case (.copyPlain, .text(let text, _)):
            copy(text, confirm: String(localized: "Copied as plain text"))
        case (.copyMarkdown, .text(let text, let rich)):
            copy(rich.flatMap(TextTools.markdown) ?? text, confirm: String(localized: "Copied as Markdown"))
        case (.copyQuoted, .text(let text, _)):
            copy(TextTools.quoted(text), confirm: String(localized: "Copied as a quote"))
        case (.countWords, .text(let text, _)):
            return Task {
                let counts = await Task.detached { TextTools.counts(text) }.value
                let message = String(localized: "\(counts.words) words · \(counts.characters) characters · \(counts.lines) lines")
                if headless { print("COUNT:\(counts.words) \(counts.characters) \(counts.lines)") } else { Feedback.confirm(message, seconds: 3) }
            }
        case (.translate, .text(let text, _)):
            guard #available(macOS 26, *) else { return nil }
            return runCopying(title: String(localized: "Translating"), done: String(localized: "Copied the translation")) { try await OnDevice.translate(text) }
        case (.summarize, .text(let text, _)):
            guard #available(macOS 26, *) else { return nil }
            return runCopying(title: String(localized: "Summarizing"), done: String(localized: "Copied the summary")) { try await OnDevice.summarize(text) }
        case (.speak, .text(let text, _)):
            return wait(JobCenter.shared.runBatch(title: String(localized: "Speaking"), items: [], name: TextTools.fileName(text), canAsk: false) { progress in
                try await Speaker().say(text, progress: progress)
                return []
            }, summary: String(localized: "Finished speaking"))
        case (.saveText, .text(let text, let rich)):
            let markdown = rich.flatMap(TextTools.markdown)
            return saveLoose(title: String(localized: "Saving text"), base: TextTools.fileName(text), extension: markdown == nil ? "txt" : "md") {
                try ((markdown ?? text) + "\n").write(to: $0, atomically: false, encoding: .utf8)
            }
        case (.cleanLink, .link(let url)):
            let clean = LinkCleaner.clean(url)
            copy(clean.absoluteString, confirm: clean == url ? String(localized: "Copied link (nothing to remove)") : String(localized: "Copied clean link"))
        case (.saveLink, .link(let url)):
            return saveLoose(title: String(localized: "Saving link"), base: url.host ?? String(localized: "Link"), extension: "webloc") {
                try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0).write(to: $0)
            }
        case (.openPrivate, .link(let url)):
            openPrivate(url)
        default:
            break
        }
        return nil
    }

    // MARK: Plumbing

    /// Developer modes run without UI; their clipboard goes to standard output so tests never touch the person's.
    static var headless: Bool { NSApp.activationPolicy() == .prohibited }

    static func copy(_ text: String, confirm message: String) {
        if headless {
            let json = (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            print("COPY:\(json)")
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return FileActions.alert(String(localized: "The text couldn’t be placed on the clipboard.")) }
        Feedback.confirm(message)
    }

    private static func wait(_ job: JobState?, summary: String? = nil) -> Task<Void, Never>? {
        guard let job else { return nil }
        job.summary = summary
        return Task {
            await job.task?.value
            if headless {
                job.outputs.forEach { print("OUT:\($0.path)") }
                job.failures.forEach { print("FAIL:\($0.name)\t\($0.message)") }
            }
        }
    }

    /// One file made from content that has no file of its own, saved where Settings says (Downloads by default).
    private static func saveLoose(title: String, base: String, extension ext: String, write: @escaping (URL) throws -> Void) -> Task<Void, Never>? {
        wait(JobCenter.shared.runBatch(title: title, items: [], name: base) { _ in
            let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: nil), base: base, extension: ext)
            return [try await AtomicOutput.write(to: destination) { try write($0) }]
        })
    }

    private static func runCopying(title: String, done: String, _ work: @escaping () async throws -> String) -> Task<Void, Never>? {
        wait(JobCenter.shared.runBatch(title: title, items: [], name: title, canAsk: false) { _ in
            let result = try await work()
            await MainActor.run { copy(result, confirm: done) }
            return []
        }, summary: done)
    }

    // MARK: Pictures

    @available(macOS 14, *)
    static func removeBackground(_ url: URL) async throws -> URL {
        let image = try ImageConverter.load(url, maxPixelSize: 8192).cgImage
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do { try handler.perform([request]) } catch { throw WheelError("The background couldn’t be removed: \(error.localizedDescription)") }
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw WheelError("No subject was found in “\(url.lastPathComponent)”.") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let cutout = ImageTools.ciContext.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw WheelError("The background couldn’t be removed.")
        }
        let destination = OutputNaming.tool(url, suffix: String(localized: "No Background"), extension: "png")
        return try await AtomicOutput.write(to: destination) {
            try ImageConverter.write(LoadedImage(cgImage: cutout, metadata: nil, dpi: nil), as: .png, quality: .high, keepMetadata: false, to: $0)
        }
    }

    static let sizes = [3840, 2048, 1920, 1600, 1280, 1080, 800, 512]

    /// A menu at the pointer: the longest edge to resize to.
    private static func chooseSize() -> Int? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Longest edge"), action: nil, keyEquivalent: "").isEnabled = false
        final class Target: NSObject { var chosen: Int?; @objc func pick(_ item: NSMenuItem) { chosen = item.tag } }
        let target = Target()
        for size in sizes {
            let item = menu.addItem(withTitle: String(localized: "\(size) px"), action: #selector(Target.pick(_:)), keyEquivalent: "")
            item.tag = size
            item.target = target
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return target.chosen
    }

    static func resize(_ url: URL, longestEdge: Int) async throws -> URL {
        let loaded = try ImageConverter.load(url)
        let longest = max(loaded.cgImage.width, loaded.cgImage.height)
        guard longest > longestEdge, let scaled = ImageTools.resize(loaded.cgImage, scale: CGFloat(longestEdge) / CGFloat(longest)) else {
            throw WheelError("“\(url.lastPathComponent)” is already \(longestEdge) px or smaller.")
        }
        return try await ImageTools.save(scaled, like: url, suffix: String(localized: "\(longestEdge) px"), metadata: loaded.metadata, needsAlpha: true)
    }

    // MARK: Files

    private static func hash(_ urls: [URL], algorithm: Checksum.Algorithm) -> Task<Void, Never>? {
        wait(JobCenter.shared.runBatch(title: String(localized: "Calculating \(algorithm.rawValue)"), items: urls, canAsk: false) { progress in
            var lines: [String] = []
            for (index, url) in urls.enumerated() {
                let hex = try Checksum.hex(url, algorithm) { progress((Double(index) + $0) / Double(urls.count)) }
                lines.append(urls.count == 1 ? hex : "\(hex)  \(url.lastPathComponent)")
            }
            await MainActor.run { copy(lines.joined(separator: "\n"), confirm: String(localized: "Copied \(algorithm.rawValue)")) }
            return []
        }, summary: String(localized: "Copied \(algorithm.rawValue)"))
    }

    /// Asks for the expected checksum, filled in from the clipboard when it holds one.
    private static func askForChecksum(_ url: URL) -> (hex: String, algorithm: Checksum.Algorithm)? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Verify “\(url.lastPathComponent)”")
        alert.informativeText = String(localized: "Paste the checksum the download page lists. MD5, SHA-1, SHA-256 and SHA-512 are recognized by their length.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = String(localized: "Checksum")
        field.setAccessibilityLabel(String(localized: "Checksum"))
        if let clip = NSPasteboard.general.string(forType: .string), let found = Checksum.expected(in: clip) { field.stringValue = found.hex }
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Verify"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let expected = Checksum.expected(in: field.stringValue) else {
            FileActions.alert(String(localized: "That isn’t an MD5, SHA-1, SHA-256 or SHA-512 checksum."))
            return nil
        }
        return expected
    }

    private static func verify(_ url: URL, expected: (hex: String, algorithm: Checksum.Algorithm)) -> Task<Void, Never>? {
        wait(JobCenter.shared.runBatch(title: String(localized: "Verifying \(expected.algorithm.rawValue)"), items: [url], canAsk: false) { progress in
            let actual = try Checksum.hex(url, expected.algorithm, progress: progress)
            await MainActor.run {
                let matches = actual == expected.hex
                if headless { print(matches ? "MATCH" : "MISMATCH:\(actual)") }
                else if matches { Feedback.confirm(String(localized: "\(expected.algorithm.rawValue) matches"), seconds: 2.5) }
                else { FileActions.alert(String(localized: "The file’s \(expected.algorithm.rawValue) is\n\(actual)\nwhich doesn’t match the checksum you entered. The file may be damaged or not the one you meant."),
                                         title: String(localized: "Checksum doesn’t match")) }
            }
            return []
        })
    }

    /// One archive of everything selected, without Mac-only metadata (no ._ files, .DS_Store or __MACOSX).
    static func zip(_ urls: [URL]) async throws -> URL {
        guard let first = urls.first else { throw WheelError("Nothing to work on.") }
        let base = urls.count == 1 ? OutputNaming.baseName(of: first) : String(localized: "Archive")
        let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: first), base: base, extension: "zip")
        return try await AtomicOutput.write(to: destination) { temp in
            // Each item is linked into a scratch folder under its own name and archived from there, so items from
            // different folders sit side by side. Names go through a NUL-separated list, never the command line, so
            // dashes, quotes and newlines stay names; -H follows only those top-level links, not links inside folders.
            let scratch = try ScratchDirectory()
            var names: [String] = []
            for url in urls {
                var name = url.lastPathComponent, counter = 2
                while names.contains(name) { name = "\(OutputNaming.baseName(of: url)) \(counter)" + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"); counter += 1 }
                try FileManager.default.createSymbolicLink(at: scratch.file(name), withDestinationURL: url)
                names.append(name)
            }
            try Data(names.map { $0 + "\u{0}" }.joined().utf8).write(to: scratch.url.appendingPathComponent(".list"))
            let result = try await ProcessRunner.run(Bundled.bsdtar, ["-c", "-f", temp.path, "--format", "zip", "-H", "--no-mac-metadata",
                                                                     "--exclude", ".DS_Store", "--exclude", ".wheelconvert-*",
                                                                     "-C", scratch.url.path, "--null", "-T", scratch.url.appendingPathComponent(".list").path])
            guard result.status == 0 else { throw ArchiveConverter.failure(result.stderr) }
        }
    }

    // MARK: Links

    private static func openPrivate(_ url: URL) {
        guard let id = PrivateBrowsing.defaultBrowser(), let flag = PrivateBrowsing.launchArguments(for: id),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // A second launch hands the arguments to the running browser, which opens the private window.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [flag, url.absoluteString]
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error { DispatchQueue.main.async { FileActions.alert(String(localized: "Couldn’t open a private window: \(error.localizedDescription)")) } }
        }
    }
}

/// Speaks text and finishes when it's done; cancelling the job stops the voice.
/// Delegate callbacks and cancellation only touch the synthesizer and the continuation, one at a time.
private final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var progress: ((Double) -> Void)?
    private var length = 1

    func say(_ text: String, progress: @escaping (Double) -> Void) async throws {
        self.progress = progress
        length = max(1, (text as NSString).length)
        let utterance = AVSpeechUtterance(string: text)
        if let code = OnDevice.language(of: text)?.minimalIdentifier { utterance.voice = AVSpeechSynthesisVoice(language: code) }
        if ProcessInfo.processInfo.environment["WHEELCONVERT_MUTE"] == "1" { utterance.volume = 0 }
        synthesizer.delegate = self
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            DispatchQueue.main.async { self.synthesizer.stopSpeaking(at: .immediate) }
        }
        try Task.checkCancellation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        progress?(Double(range.location) / Double(length))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}
