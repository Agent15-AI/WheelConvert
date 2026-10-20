import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A decoded still image plus the metadata worth carrying into a new file.
struct LoadedImage {
    let cgImage: CGImage
    /// Source metadata with orientation already applied to the pixels.
    let metadata: CGImageMetadata?
    /// Pixels per inch, when the source records it.
    let dpi: Double?
    var hasAlpha: Bool {
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}

enum ImageConverter {
    static func convert(_ source: URL, from input: FileFormat, to target: FileFormat, options: ConversionOptions,
                        destination: URL) async throws {
        var image = input == .svg ? try await SVGRenderer.rasterize(source) : try load(source)
        if options.imageMaxWidth > 0, target != .pdf { image = narrowed(image, to: options.imageMaxWidth) }
        if target == .pdf {
            if input == .svg {
                try await SVGRenderer.pdf(source, to: destination)
            } else {
                try writePDF([image], to: destination)
            }
            return
        }
        try write(image, as: target, quality: options.quality, keepMetadata: options.preserveMetadata, to: destination)
    }

    /// Scales the image down to `width` pixels wide (never up), keeping its metadata in step.
    static func narrowed(_ image: LoadedImage, to width: Int) -> LoadedImage {
        let cg = image.cgImage
        guard cg.width > width, let resized = ImageTools.resize(cg, scale: CGFloat(width) / CGFloat(cg.width)) else { return image }
        var metadata = image.metadata
        if let original = image.metadata, let mutable = CGImageMetadataCreateMutableCopy(original) {
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, resized.width as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, resized.height as CFNumber)
            metadata = mutable
        }
        return LoadedImage(cgImage: resized, metadata: metadata, dpi: image.dpi)
    }

    static func quality(_ q: ConversionOptions.Quality) -> Double {
        switch q {
        case .high: 0.92
        case .balanced: 0.82
        case .compact: 0.65
        }
    }

    /// Decodes the primary frame at full size with EXIF orientation applied.
    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw WheelError("Could not read the image \(url.lastPathComponent).")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        guard longest > 0 else { throw WheelError("Could not read the image \(url.lastPathComponent).") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if orientation == 1 && (maxPixelSize ?? longest) >= longest {
            // Already upright at full size: decode directly, keeping 16-bit and HDR pixels intact.
            image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? longest, longest),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
        guard let image else {
            throw WheelError("Could not read the image \(url.lastPathComponent).")
        }
        var metadata: CGImageMetadata?
        if let original = CGImageSourceCopyMetadataAtIndex(source, index, nil),
           let mutable = CGImageMetadataCreateMutableCopy(original) {
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, image.width as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, image.height as CFNumber)
            metadata = mutable
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil }
        return LoadedImage(cgImage: image, metadata: metadata, dpi: dpi)
    }

    static func utType(for format: FileFormat) -> UTType? {
        switch format {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .bmp: .bmp
        case .avif: UTType("public.avif")
        case .gif: .gif
        default: nil
        }
    }

    /// Encodes one image. `quality` applies to lossy formats; JPEG and BMP get a white backdrop for transparency.
    static func write(_ image: LoadedImage, as format: FileFormat, quality q: ConversionOptions.Quality,
                      keepMetadata: Bool, to url: URL, exactQuality: Double? = nil) throws {
        let level = exactQuality ?? quality(q)
        if format == .webp {
            let data = try WebPCodec.encode(image.cgImage, quality: Float(level * 100), metadata: keepMetadata ? (image.metadata ?? CGImageMetadataCreateMutable()) : nil)
            try data.write(to: url)
            return
        }
        guard let type = utType(for: format),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw WheelError("ImageIO could not create the \(format.title) image.")
        }
        var cg = image.cgImage
        if (format == .jpg || format == .bmp) && image.hasAlpha { cg = flatten(cg) }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if format.isLossyImage { properties[kCGImageDestinationLossyCompressionQuality] = level }
        if format == .tiff { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] } // LZW
        if let dpi = image.dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        if keepMetadata, let metadata = image.metadata, format != .bmp {
            CGImageDestinationAddImageAndMetadata(destination, cg, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw WheelError("ImageIO could not finish the \(format.title) image.")
        }
    }

    /// Draws the image over white, for formats without transparency.
    static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        let space = ImageTools.rgbSpace(of: image)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// One page per image, each page the image's size at its recorded resolution (72 ppi when unknown).
    static func writePDF(_ images: [LoadedImage], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw WheelError("Could not create the PDF.") }
        // Every page sets its own box; this default only fills the page tree's inherited entry.
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "WheelConvert"] as CFDictionary) else {
            throw WheelError("Could not create the PDF.")
        }
        for image in images {
            let scale = 72.0 / (image.dpi ?? 72.0)
            var page = CGRect(x: 0, y: 0, width: Double(image.cgImage.width) * scale, height: Double(image.cgImage.height) * scale)
            // PDF pages larger than 200 inches are rejected by some readers.
            let limit = 14_400.0
            if max(page.width, page.height) > limit {
                let fit = limit / max(page.width, page.height)
                page.size = CGSize(width: page.width * fit, height: page.height * fit)
            }
            context.beginPage(mediaBox: &page)
            context.interpolationQuality = .high
            context.draw(image.cgImage, in: page)
            context.endPage()
        }
        context.closePDF()
    }
}
