import Foundation
import PDFKit
import Quartz

enum PDFTools {
    // MARK: Compress

    /// Image downsampling/JPEG settings per step; text and vector art are untouched.
    static let levels: [(dpi: Int, quality: Double)] = [(220, 0.82), (160, 0.68), (120, 0.55), (96, 0.42), (72, 0.3)]

    static func compress(_ source: URL, options: ToolOptions.Compress, progress: @escaping (Double) -> Void) async throws -> URL {
        let document = try PDFConverter.open(source)
        let original = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let target: Int64? = switch options.mode {
        case .preset: nil
        case .fileSize: options.targetBytes
        case .percentage: original * Int64(100 - min(99, max(1, options.reduction))) / 100
        }
        if let target, target >= original { throw WheelError("Target size cannot exceed the original file size.") }
        let destination = OutputNaming.tool(source, suffix: String(localized: "Compressed"))
        let scratch = try ScratchDirectory()
        let candidates = target == nil ? [levels[options.strength == .light ? 0 : options.strength == .balanced ? 1 : 3]] : levels
        var smallest: (URL, Int64)?
        for (i, level) in candidates.enumerated() {
            let file = scratch.file("attempt-\(i).pdf")
            try render(document, to: file, dpi: level.dpi, quality: level.quality)
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max)
            if smallest == nil || size < smallest!.1 { smallest = (file, size) }
            progress(Double(i + 1) / Double(candidates.count))
            if let target, size > target { continue }
            break
        }
        guard let (best, size) = smallest, PDFDocument(url: best) != nil else { throw WheelError("The compressed PDF could not be verified.") }
        if let target, size > target {
            throw WheelError("Could not reach the target size. Smallest attempt was \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)). Try a larger target.")
        }
        guard size < original else { throw WheelError("This PDF is already well compressed. Its images can't be made smaller.") }
        return try await AtomicOutput.write(to: destination) { try FileManager.default.copyItem(at: best, to: $0) }
    }

    /// Saves the document through a Quartz filter that resamples and JPEG-compresses its images, the way
    /// Preview's "Reduce File Size" does. Text, vector art, links, annotations and page rotation are kept.
    static func render(_ document: PDFDocument, to url: URL, dpi: Int, quality: Double) throws {
        let filterURL = FileManager.default.temporaryDirectory.appendingPathComponent("wheelconvert-\(UUID().uuidString).qfilter")
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "WheelConvert Compression",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality, "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": dpi * 16, "ImageSizeMin": 0],
            ]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: filterURL)
        defer { try? FileManager.default.removeItem(at: filterURL) }
        guard let filter = QuartzFilter(url: filterURL) else { throw WheelError("The macOS PDF compression filter is unavailable.") }
        guard document.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]),
              PDFDocument(url: url)?.pageCount == document.pageCount else {
            throw WheelError("Could not create the compressed PDF.")
        }
    }

    // MARK: Merge, organize, split

    static func merge(_ sources: [URL], order: [String]) async throws -> URL {
        let ordered = order.isEmpty ? sources : order.map { URL(fileURLWithPath: $0) }
        guard ordered.count >= 2 else { throw WheelError("Select at least two PDFs to merge.") }
        let output = PDFDocument()
        for url in ordered {
            let document = try PDFConverter.open(url)
            for i in 0..<document.pageCount {
                if let page = document.page(at: i)?.copy() as? PDFPage { output.insert(page, at: output.pageCount) }
            }
        }
        let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: ordered[0]), base: String(localized: "Merged PDF"), extension: "pdf")
        return try await AtomicOutput.write(to: destination) {
            guard output.write(to: $0) else { throw WheelError("PDFKit could not write the combined PDF.") }
        }
    }

    static func organize(_ source: URL, options: ToolOptions.OrganizePDF) async throws -> URL {
        let document = try PDFConverter.open(source)
        guard !options.pages.isEmpty else { throw WheelError("Keep at least one page.") }
        guard options.pages.allSatisfy({ $0.source >= 0 && $0.source < document.pageCount }) else { throw WheelError("The page order must include valid pages.") }
        guard options.pages.allSatisfy({ $0.rotation % 90 == 0 }) else { throw WheelError("Page rotations must be 90-degree turns for pages in this PDF.") }
        var output = PDFDocument()
        for entry in options.pages {
            guard let page = document.page(at: entry.source)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + entry.rotation) % 360 + 360) % 360
            output.insert(page, at: output.pageCount)
        }
        if options.equalWidths { output = try equalizedWidths(output) }
        let destination = OutputNaming.tool(source, suffix: String(localized: "Organized"))
        return try await AtomicOutput.write(to: destination) {
            guard output.write(to: $0), PDFDocument(url: $0)?.pageCount == options.pages.count else { throw WheelError("The organized PDF could not be verified.") }
        }
    }

    /// Redraws pages so every page has the narrowest page's width; heights scale proportionally.
    static func equalizedWidths(_ document: PDFDocument) throws -> PDFDocument {
        func size(_ page: PDFPage) -> CGSize {
            let box = page.bounds(for: .cropBox)
            return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        }
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        guard let narrowest = pages.map({ size($0).width }).min(), narrowest > 0 else { return document }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw WheelError("Could not create the organized PDF.") }
        var box = CGRect(x: 0, y: 0, width: narrowest, height: narrowest)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "WheelConvert"] as CFDictionary) else {
            throw WheelError("Could not create the organized PDF.")
        }
        for page in pages {
            let s = size(page)
            let scale = narrowest / s.width
            var media = CGRect(x: 0, y: 0, width: narrowest, height: s.height * scale)
            context.beginPage(mediaBox: &media)
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            context.endPage()
        }
        context.closePDF()
        guard let result = PDFDocument(data: data as Data) else { throw WheelError("Could not create the organized PDF.") }
        return result
    }

    static func split(_ source: URL, options: ToolOptions.SplitPDF) async throws -> URL {
        let document = try PDFConverter.open(source)
        let count = document.pageCount
        var groups: [ClosedRange<Int>] = []
        switch options.mode {
        case .everyPage:
            groups = (0..<count).map { $0...$0 }
        case .everyN:
            let n = max(1, options.every)
            groups = stride(from: 0, to: count, by: n).map { $0...min(count - 1, $0 + n - 1) }
        case .ranges:
            groups = try parseRanges(options.ranges, pageCount: count)
        }
        guard groups.count >= 1 else { throw WheelError("Enter at least one page range.") }
        let base = OutputNaming.sanitize(OutputNaming.baseName(of: source))
        return try await Publisher.publish(for: source) { staging in
            var files: [URL] = []
            for group in groups {
                let part = PDFDocument()
                for i in group { if let page = document.page(at: i)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) } }
                let label = group.count == 1 ? "\(group.lowerBound + 1)" : "\(group.lowerBound + 1)-\(group.upperBound + 1)"
                let file = staging.url.appendingPathComponent("\(base) Pages \(label).pdf")
                guard part.write(to: file) else { throw WheelError("Could not write page \(label).") }
                files.append(file)
            }
            return files
        }
    }

    /// "1-3, 5, 8-" → zero-based ranges.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = piece.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "–", with: "-")
            guard !part.isEmpty else { continue }
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let start = Int(bounds[0]) ?? 1
            let end = bounds.count > 1 ? (bounds[1].isEmpty ? pageCount : Int(bounds[1]) ?? -1) : start
            guard start >= 1, end >= start, end <= pageCount else { throw WheelError("“\(part)” isn’t a valid range for a \(pageCount)-page PDF.") }
            result.append((start - 1)...(end - 1))
        }
        return result
    }
}

// MARK: - Metadata

struct MetadataEntry: Identifiable, Hashable {
    var id: String { group + ":" + key }
    let group: String
    let key: String
    var value: String
    let editable: Bool
}

enum MetadataTools {
    /// Fields WheelConvert lets you edit, per kind of file.
    static let editableImageTags = ["Title", "Description", "Artist", "Copyright", "Keywords", "DateTimeOriginal", "GPSLatitude", "GPSLongitude", "Make", "Model", "LensModel", "Software"]
    static let editableMediaTags = ["title", "artist", "album", "album_artist", "genre", "date", "comment", "composer", "copyright", "track", "description"]
    static let editablePDFTags = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"]

    static func read(_ url: URL) async throws -> [MetadataEntry] {
        let output = try await ProcessRunner.run(Bundled.perl, [Bundled.exiftool.path, "-json", "-G1", "-a", "-s", "-api", "LargeFileSupport=1", url.path])
        guard output.status == 0 || !output.stdout.isEmpty,
              let list = try? JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]], let tags = list.first else {
            throw WheelError("No readable metadata found.")
        }
        let format = FileFormat.detect(url)
        let editable: Set<String> = Set(format?.category == .pdf ? editablePDFTags : (format?.category == .images ? editableImageTags : editableMediaTags.map { $0.capitalized }))
        var entries: [MetadataEntry] = []
        for (compound, value) in tags {
            let parts = compound.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (group, key) = (parts[0], parts[1])
            if ["SourceFile", "ExifToolVersion"].contains(key) || group == "ExifTool" || group == "System" { continue }
            let text: String
            if let array = value as? [Any] { text = array.map { "\($0)" }.joined(separator: ", ") } else { text = "\(value)" }
            if text.hasPrefix("(Binary data") { continue }
            entries.append(MetadataEntry(group: group, key: key, value: text, editable: editable.contains(key) || editable.contains(key.capitalized)))
        }
        return entries.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }

    static func apply(_ source: URL, options: ToolOptions.Metadata, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let format = FileFormat.detect(source) else { throw WheelError("This metadata field is not supported.") }
        // Field names become ExifTool/ffmpeg arguments; only plain tag names are accepted.
        guard options.changes.keys.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }) else {
            throw WheelError("This metadata field is not supported.")
        }
        let destination = OutputNaming.tool(source, suffix: options.removeAll ? String(localized: "Metadata Removed") : String(localized: "Metadata Edited"))
        switch format.category {
        case .pdf:
            return try await AtomicOutput.write(to: destination) { try pdf(source, options: options, to: $0) }
        case .audio, .video:
            let info = try await MediaInfo.probe(source)
            var args = ["-i", source.path]
            if options.removeAll {
                args += ["-map", "0:v?", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy",
                         "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
                if format.category == .audio { args = ["-i", source.path, "-map", "0:a", "-map_metadata", "-1", "-c", "copy", "-fflags", "+bitexact"] }
            } else {
                args += ["-map", "0", "-c", "copy"]
                for (key, value) in options.changes { args += ["-metadata", "\(key.lowercased())=\(value ?? "")"] }
                if [.mp4, .mov, .m4a].contains(format) { args += ["-movflags", "+use_metadata_tags"] }
            }
            if format == .mp3 { args += ["-id3v2_version", "3"] }
            return try await MediaTools.render(args, to: destination, duration: info.duration, progress: progress)
        default:
            // Images: ExifTool. Remove All keeps orientation and the color profile so the picture looks the same.
            var args = [Bundled.exiftool.path, "-q", "-q", "-m"]
            if options.removeAll {
                args += ["-all=", "-tagsfromfile", "@", "-ICC_Profile", "-Orientation", "-ColorSpaceTags"]
            } else {
                for (key, value) in options.changes {
                    if key.hasPrefix("GPS"), let value, let number = Double(value) {
                        args.append("-\(key)=\(abs(number))")
                        args.append("-\(key)Ref=\(key == "GPSLatitude" ? (number < 0 ? "S" : "N") : (number < 0 ? "W" : "E"))")
                    } else {
                        args.append("-\(key)=\(value ?? "")")
                    }
                }
            }
            return try await AtomicOutput.write(to: destination) { temp in
                let result = try await ProcessRunner.run(Bundled.perl, args + ["-o", temp.path, source.path])
                guard result.status == 0, FileManager.default.fileExists(atPath: temp.path) else {
                    let message = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                    throw WheelError("This format could not save the change. The original file is unchanged.\(message.isEmpty ? "" : " \(message)")")
                }
                guard CGImageSourceCreateWithURL(temp as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil else {
                    throw WheelError("The image could not be verified. No output was saved.")
                }
            }
        }
    }

    static func pdf(_ source: URL, options: ToolOptions.Metadata, to url: URL) throws {
        let document = try PDFConverter.open(source)
        // A fresh document drops the catalog's XMP metadata stream along with the info dictionary.
        let output = PDFDocument()
        for i in 0..<document.pageCount { if let page = document.page(at: i)?.copy() as? PDFPage { output.insert(page, at: output.pageCount) } }
        var attributes: [AnyHashable: Any] = options.removeAll ? [:] : (document.documentAttributes ?? [:])
        if !options.removeAll {
            let keys: [String: PDFDocumentAttribute] = ["Title": .titleAttribute, "Author": .authorAttribute, "Subject": .subjectAttribute,
                                                        "Keywords": .keywordsAttribute, "Creator": .creatorAttribute, "Producer": .producerAttribute]
            for (key, value) in options.changes {
                guard let attribute = keys[key] else { continue }
                if let value, !value.isEmpty {
                    attributes[attribute] = attribute == .keywordsAttribute ? value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : value
                } else {
                    attributes[attribute] = nil
                }
            }
        }
        output.documentAttributes = attributes
        guard output.write(to: url) else { throw WheelError("PDFKit could not write the cleaned PDF.") }
    }
}
