import AppKit
import PDFKit

/// Converts one file (or folder) to a target format and saves the result beside it.
enum Converter {
    /// - Returns: The saved files or folders, for revealing in Finder.
    static func convert(_ source: URL, to target: FileFormat, options: ConversionOptions,
                        progress: @escaping (Double) -> Void) async throws -> [URL] {
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isReadableKey])
        guard values?.isReadable != false, FileManager.default.fileExists(atPath: source.path) else {
            throw WheelError("The source file could not be read.")
        }
        if values?.isDirectory == true && values?.isPackage != true {
            guard target.category == .archives else { throw WheelError("Folders can only become archives.") }
            return [try await Publisher.publish(for: source) { staging in
                let file = staging.url.appendingPathComponent(OutputNaming.baseName(of: source) + "." + target.fileExtension)
                try await ArchiveConverter.archiveFolder(source, to: target, options: options, destination: file)
                return [file]
            }]
        }
        guard let input = FileFormat.detect(source) else { throw WheelError("This file type is not supported.") }
        guard ConversionMatrix.outputs(for: input).contains(target) else {
            throw WheelError("Conversion from \(input.title) to \(target.title) is unavailable.")
        }
        let base = OutputNaming.baseName(of: source)
        return [try await Publisher.publish(for: source) { staging in
            let single = staging.url.appendingPathComponent(OutputNaming.sanitize(base) + "." + target.fileExtension)
            var outputs: [URL] = [single]
            switch input.category {
            case .images:
                try await ImageConverter.convert(source, from: input, to: target, options: options, destination: single)
            case .video, .audio:
                try await MediaConverter.convert(source, from: input, to: target, options: options, destination: single, progress: progress)
            case .pdf:
                outputs = try await PDFConverter.convert(source, to: target, options: options, staging: staging.url, base: base, progress: progress)
            case .documents:
                try await DocumentConverter.convert(source, from: input, to: target, options: options, destination: single, progress: progress)
            case .slides:
                outputs = try await OfficeHelper.slides(source, to: target, staging: staging.url, base: base, progress: progress)
            case .spreadsheets:
                outputs = try await OfficeHelper.spreadsheet(source, from: input, to: target, staging: staging.url, base: base, progress: progress)
            case .subtitles:
                try SubtitleConverter.convert(source, from: input, to: target, destination: single)
            case .archives:
                try await ArchiveConverter.convert(source, from: input, to: target, options: options, destination: single)
            }
            progress(1)
            return outputs
        }]
    }
}

/// Collects a job's results in a hidden folder beside the source, then moves them into place:
/// one file keeps the source's name with the new extension; several files become a folder.
struct Staging {
    let url: URL
    let directory: URL

    func publish(_ files: [URL], source: URL) throws -> URL {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            throw WheelError("The converter finished without creating an output file.")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        if existing.count == 1, let file = existing.first {
            let name = file.lastPathComponent
            let ext = name.lowercased().hasSuffix(".tar.gz") ? "tar.gz" : file.pathExtension
            let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            return try OutputNaming.place(file, in: directory, base: base, extension: ext.isEmpty ? nil : ext)
        }
        // Several results: the staging folder itself becomes the visible folder.
        let inner = url.appendingPathComponent("__results", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for file in existing where file.deletingLastPathComponent().standardizedFileURL != inner.standardizedFileURL {
            try FileManager.default.moveItem(at: file, to: inner.appendingPathComponent(file.lastPathComponent))
        }
        return try OutputNaming.place(inner, in: directory, base: OutputNaming.baseName(of: source), extension: nil)
    }
}

enum Publisher {
    /// Results go beside the source; read-only places (disk images, shared folders) fall back to Downloads.
    static func destinationDirectory(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: directory.path) { return directory }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// Runs `body` in a fresh staging folder and publishes the files it returns. A failed or
    /// cancelled job leaves nothing behind.
    static func publish(for source: URL, _ body: (Staging) async throws -> [URL]) async throws -> URL {
        let staging = try staging(for: source)
        do {
            return try staging.publish(try await body(staging), source: source)
        } catch {
            try? FileManager.default.removeItem(at: staging.url)
            throw error
        }
    }

    static func staging(for source: URL) throws -> Staging {
        let directory = destinationDirectory(for: source)
        let url = directory.appendingPathComponent(".wheelconvert-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw WheelError("WheelConvert can't save to “\(directory.lastPathComponent)”.")
        }
        return Staging(url: url, directory: directory)
    }
}

// MARK: - PDF sources

enum PDFConverter {
    static func open(_ source: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: source), !document.isLocked else {
            throw WheelError("The PDF cannot be read, is empty, or is password-protected.")
        }
        guard document.pageCount > 0 else { throw WheelError("This PDF has no pages.") }
        return document
    }

    static func convert(_ source: URL, to target: FileFormat, options: ConversionOptions, staging: URL, base: String,
                        progress: @escaping (Double) -> Void) async throws -> [URL] {
        let single = staging.appendingPathComponent(OutputNaming.sanitize(base) + "." + target.fileExtension)
        switch target {
        case .jpg, .png:
            let document = try open(source)
            return try renderPages(document, as: target, staging: staging, base: base, dpi: 300, progress: progress)
        case .txt:
            let document = try open(source)
            try text(document, progress: progress).write(to: single, atomically: false, encoding: .utf8)
            return [single]
        case .pptx:
            return try await OfficeHelper.run("pdf2pptx", source, single, progress: progress)
        case .xlsx:
            return try await OfficeHelper.run("pdf2sheet", source, single, progress: progress)
        case .docx, .pages, .epub, .md:
            let document = try open(source)
            let preserve = (target == .epub && options.epubLayout == .preservePages)
                || ((target == .docx || target == .pages) && options.officeLayout == .preservePages)
            if preserve {
                try pagesAsImages(document, to: target, destination: single, title: base, progress: progress)
            } else {
                var doc = try PDFStructureReader.read(document) { progress($0 * 0.85) }
                if doc.title == nil { doc.title = base }
                try await DocumentConverter.write(doc, as: target, destination: single, progress: progress)
            }
            return [single]
        default:
            throw WheelError("Conversion from PDF to \(target.title) is unavailable.")
        }
    }

    /// Text of every page; scanned pages are read with OCR.
    static func text(_ document: PDFDocument, progress: (Double) -> Void) throws -> String {
        guard document.allowsCopying else { throw WheelError("This PDF does not allow copying its content.") }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
                text = (try? PDFStructureReader.ocrLines(page).map(\.text).joined(separator: "\n")) ?? text
            }
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            progress(Double(index + 1) / Double(document.pageCount))
        }
        let joined = pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !joined.isEmpty else { throw WheelError("This PDF has no selectable text.") }
        return joined + "\n"
    }

    static func renderPages(_ document: PDFDocument, as format: FileFormat, staging: URL, base: String, dpi: CGFloat,
                            progress: (Double) -> Void) throws -> [URL] {
        var outputs: [URL] = []
        let count = document.pageCount
        for index in 0..<count {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let longest = max(box.width, box.height)
            guard longest > 0 else { throw WheelError("A PDF page has invalid dimensions or could not be rendered.") }
            let scale = min(dpi / 72, 12_000 / longest)
            guard let image = PDFStructureReader.render(page, scale: scale) else {
                throw WheelError("Could not create the PDF page image.")
            }
            let name = count == 1 ? OutputNaming.sanitize(base) : "\(OutputNaming.sanitize(base)) - Page \(index + 1)"
            let url = staging.appendingPathComponent(name + "." + format.fileExtension)
            let loaded = LoadedImage(cgImage: image, metadata: nil, dpi: Double(scale * 72))
            try ImageConverter.write(loaded, as: format, quality: .high, keepMetadata: false, to: url)
            outputs.append(url)
            progress(Double(index + 1) / Double(count))
        }
        return outputs
    }

    /// "Preserve pages": every page becomes a sharp image in the target format.
    static func pagesAsImages(_ document: PDFDocument, to target: FileFormat, destination: URL, title: String, progress: (Double) -> Void) throws {
        var pages: [(data: Data, width: Double, height: Double, pixels: CGSize)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
            let scale = min(200 / 72, 8_000 / max(w, h))
            guard let image = PDFStructureReader.render(page, scale: scale) else { throw WheelError("A PDF page could not be rendered.") }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw WheelError("A PDF page could not be rendered.") }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw WheelError("A PDF page could not be rendered.") }
            pages.append((data as Data, Double(w), Double(h), CGSize(width: image.width, height: image.height)))
            progress(0.9 * Double(index + 1) / Double(document.pageCount))
        }
        switch target {
        case .docx:
            var writer = DOCXWriter()
            try writer.writePageImages(pages.map { ($0.data, $0.width, $0.height) }, title: title).write(to: destination)
        case .epub:
            try EPUBWriter.writePages(pages.map { ($0.data, Int($0.pixels.width), Int($0.pixels.height)) }, title: title).write(to: destination)
        case .pages:
            var doc = StructuredDocument()
            if let first = pages.first {
                doc.page = .init(width: first.width, height: first.height, top: 18, right: 18, bottom: 18, left: 18)
            }
            for (i, page) in pages.enumerated() {
                if i > 0 { doc.blocks.append(.pageBreak) }
                let fit = min(1, (page.width - 36) / page.width)
                doc.blocks.append(.image(.init(data: page.data, width: page.width * fit, height: page.height * fit, alt: "Page \(i + 1)")))
            }
            try PagesBridge.write(doc).write(to: destination)
        default:
            break
        }
    }
}

// MARK: - Document sources

enum DocumentConverter {
    static func read(_ source: URL, as input: FileFormat) throws -> StructuredDocument {
        var doc: StructuredDocument
        switch input {
        case .docx: doc = try DOCXReader.read(source)
        case .pages: doc = try PagesBridge.read(source)
        case .md: doc = try MarkdownReader.read(source)
        case .txt: doc = try PlainTextReader.read(source)
        case .epub: doc = try EPUBReader.read(source)
        case .rtf, .rtfd, .textClipping: doc = try RichTextReader.read(source, format: input)
        default: throw WheelError("This file type is not supported.")
        }
        if doc.title == nil { doc.title = doc.inferredTitle ?? OutputNaming.baseName(of: source) }
        guard !doc.isEmpty else { throw WheelError("The document is empty.") }
        return doc
    }

    static func convert(_ source: URL, from input: FileFormat, to target: FileFormat, options: ConversionOptions,
                        destination: URL, progress: @escaping (Double) -> Void) async throws {
        if input == .docx && target == .pdf {
            try await DocumentPrinter.printDOCX(source, to: destination, progress: progress)
            return
        }
        let doc = try read(source, as: input)
        progress(0.4)
        try await write(doc, as: target, destination: destination, progress: progress)
    }

    static func write(_ doc: StructuredDocument, as target: FileFormat, destination: URL, progress: @escaping (Double) -> Void) async throws {
        switch target {
        case .pdf:
            var writer = HTMLWriter()
            let html = writer.document(doc, css: HTMLWriter.printCSS)
            try await DocumentPrinter.printHTML(html, page: doc.page ?? DOCXWriter.defaultPage(), to: destination)
        case .docx:
            var writer = DOCXWriter()
            try writer.write(doc).write(to: destination)
        case .pages:
            try PagesBridge.write(doc).write(to: destination)
        case .md:
            var writer = MarkdownWriter()
            try writer.write(doc).write(to: destination, atomically: false, encoding: .utf8)
        case .txt:
            try PlainTextWriter.write(doc).write(to: destination, atomically: false, encoding: .utf8)
        case .epub:
            try EPUBWriter.write(doc).write(to: destination)
        case .html:
            var writer = HTMLWriter()
            try writer.document(doc, css: HTMLWriter.screenCSS).write(to: destination, atomically: false, encoding: .utf8)
        default:
            throw WheelError("Conversion to \(target.title) is unavailable.")
        }
        progress(1)
    }
}
