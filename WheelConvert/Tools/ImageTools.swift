import AppKit
import CoreText
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import Vision

/// Still-image tools. Each returns the saved file(s); originals are never modified.
enum ImageTools {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    // MARK: Compress

    static func compress(_ source: URL, options: ToolOptions.Compress) async throws -> URL {
        guard let format = FileFormat.detect(source), ToolKind.rasterImages.contains(format) else { throw WheelError("This file type is not supported.") }
        let original = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard original > 1024 else { throw WheelError("This file is already smaller than 1 KB.") }
        var image = try ImageConverter.load(source, maxPixelSize: options.maxDimension > 0 ? options.maxDimension : nil)
        let target: Int64? = switch options.mode {
        case .preset: nil
        case .fileSize: options.targetBytes
        case .percentage: original * Int64(100 - min(99, max(1, options.reduction))) / 100
        }
        if let target {
            guard target >= 1024 else { throw WheelError("Enter a target size of at least 1 KB.") }
            guard target < original else { throw WheelError("Target size cannot exceed the original file size.") }
        }
        var data: Data?
        var smallest = Int64.max
        // Try quality first, then shrink dimensions until the target fits.
        for _ in 0..<7 {
            var attempt = try encode(image, format: format, strength: options.strength, target: target, dither: options.dither)
            // Dithering's fine grain can cost more bytes than it saves on clean, noise-free gradients;
            // rather than miss the size, those keep plain palette colors.
            if format == .png && options.dither && Int64(attempt.count) >= (target ?? original) {
                attempt = try encode(image, format: format, strength: options.strength, target: target, dither: false)
            }
            smallest = min(smallest, Int64(attempt.count))
            if let target, Int64(attempt.count) > target {
                let cg = image.cgImage
                guard let resized = resize(cg, scale: 0.8) else { break }
                image = LoadedImage(cgImage: resized, metadata: image.metadata, dpi: image.dpi)
                continue
            }
            data = attempt
            break
        }
        guard let data else {
            throw WheelError("Could not reach the target size. Smallest attempt was \(ByteCountFormatter.string(fromByteCount: smallest, countStyle: .file)). Try a larger target.")
        }
        guard Int64(data.count) < original || options.maxDimension > 0 else {
            throw WheelError("This image is already well compressed. Try a stronger preset or a smaller size.")
        }
        let destination = OutputNaming.tool(source, suffix: "Compressed")
        try await AtomicOutput.write(to: destination) { try data.write(to: $0) }
        return destination
    }

    static func quality(for strength: CompressionStrength) -> Double {
        switch strength {
        case .light: 0.86
        case .balanced: 0.72
        case .strong: 0.52
        }
    }

    /// Encodes once (or, with a target, searches quality) and returns the bytes.
    static func encode(_ image: LoadedImage, format: FileFormat, strength: CompressionStrength, target: Int64?, dither: Bool = true) throws -> Data {
        switch format {
        case .webp:
            // Like the other formats, compressed copies keep their metadata.
            if let target { return try WebPCodec.encode(image.cgImage, quality: 75, targetSize: Int(target), metadata: image.metadata ?? CGImageMetadataCreateMutable()) }
            return try WebPCodec.encode(image.cgImage, quality: Float(quality(for: strength) * 100), metadata: image.metadata ?? CGImageMetadataCreateMutable())
        case .jpg, .heic, .avif:
            guard let target else { return try encodeImage(image, format: format, quality: quality(for: strength)) }
            var lo = 0.05, hi = 0.95
            var best: Data?
            for _ in 0..<8 {
                let mid = (lo + hi) / 2
                let data = try encodeImage(image, format: format, quality: mid)
                if Int64(data.count) <= target { best = data; lo = mid } else { hi = mid }
            }
            return try best ?? encodeImage(image, format: format, quality: 0.05)
        case .png:
            if target == nil && strength == .light { return try encodeImage(image, format: .png, quality: 1) }
            let palettes = target == nil ? [strength == .strong ? 96 : 256] : [256, 160, 96, 64, 32]
            var last = Data()
            for colors in palettes {
                last = try PNGQuantizer.encode(image.cgImage, colors: colors, dither: dither)
                if let target, Int64(last.count) > target { continue }
                return last
            }
            return last
        default:
            // TIFF and BMP have no lossy mode; they shrink by size only.
            return try encodeImage(image, format: format, quality: 1)
        }
    }

    static func encodeImage(_ image: LoadedImage, format: FileFormat, quality: Double) throws -> Data {
        let scratch = try ScratchDirectory()
        let url = scratch.file("image.\(format.fileExtension)")
        try ImageConverter.write(image, as: format, quality: .high, keepMetadata: true, to: url, exactQuality: quality)
        return try Data(contentsOf: url)
    }

    static func resize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard width < image.width || height < image.height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: rgbSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The image's own color space when it is RGB; RGBA bitmap contexts can't use gray or CMYK spaces.
    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Writes an edited image next to its source in the source's format (PNG when transparency must survive).
    static func save(_ image: CGImage, like source: URL, suffix: String, metadata: CGImageMetadata?, needsAlpha: Bool = false) async throws -> URL {
        var format = FileFormat.detect(source) ?? .png
        if needsAlpha && [.jpg, .bmp].contains(format) { format = .png }
        let destination = OutputNaming.tool(source, suffix: suffix, extension: format.fileExtension)
        let loaded = LoadedImage(cgImage: image, metadata: metadata, dpi: nil)
        return try await AtomicOutput.write(to: destination) {
            try ImageConverter.write(loaded, as: format, quality: .high, keepMetadata: true, to: $0, exactQuality: 0.94)
        }
    }

    // MARK: Crop

    static func crop(_ source: URL, options: ToolOptions.Crop) async throws -> URL {
        let image = try ImageConverter.load(source)
        let w = Double(image.cgImage.width), h = Double(image.cgImage.height)
        let rect = CGRect(x: options.x * w, y: options.y * h, width: options.width * w, height: options.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cgImage.cropping(to: rect) else {
            throw WheelError("The crop must be at least 1 × 1 pixel.")
        }
        var result = cropped
        if options.outputWidth > 0 && options.outputHeight > 0 {
            guard let context = CGContext(data: nil, width: options.outputWidth, height: options.outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: rgbSpace(of: cropped), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WheelError("Could not create the cropped image.") }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: options.outputWidth, height: options.outputHeight))
            guard let scaled = context.makeImage() else { throw WheelError("Could not create the cropped image.") }
            result = scaled
        }
        return try await save(result, like: source, suffix: "Cropped", metadata: image.metadata)
    }

    // MARK: Background

    static let gradients: [(id: String, name: String, colors: [String])] = [
        ("dusk", "Dusk", ["6B5CFF", "2EA8FF"]), ("ocean", "Ocean", ["0F4C81", "2EC5CE"]), ("meadow", "Meadow", ["9BE15D", "00A86B"]),
        ("peach", "Peach", ["FFD3A5", "FD6585"]), ("lilac", "Lilac", ["E0C3FC", "8EC5FC"]), ("mint", "Mint", ["D4FC79", "96E6A1"]),
        ("sunset", "Sunset", ["FF7E5F", "FEB47B"]), ("sky", "Sky", ["A1C4FD", "C2E9FB"]), ("ember", "Ember", ["F83600", "F9D423"]),
        ("forest", "Forest", ["134E5E", "71B280"]), ("aurora", "Aurora", ["00C9FF", "92FE9D"]), ("rose", "Rose", ["F4C4F3", "FC67FA"]),
        ("sand", "Sand", ["E6DADA", "BFA58A"]), ("lagoon", "Lagoon", ["43CEA2", "185A9D"]), ("night", "Night", ["232526", "414345"]),
        ("graphite", "Graphite", ["4B4B52", "1C1C20"]),
    ]

    static let solids: [String] = ["FFFFFF", "F2F2F7", "000000", "1C1C1E", "FF3B30", "FF9500", "FFCC00", "34C759", "00C7BE", "30B0C7",
                                   "32ADE6", "007AFF", "5856D6", "AF52DE", "FF2D55", "A2845E", "8E8E93"]

    static func frame(_ source: URL, options: ToolOptions.Background) async throws -> URL {
        let photo = try ImageConverter.load(source)
        let canvas = try renderFrame(photo.cgImage, options: options)
        return try await save(canvas, like: source, suffix: "Background", metadata: photo.metadata, needsAlpha: options.kind == .transparent)
    }

    static func renderFrame(_ photo: CGImage, options: ToolOptions.Background) throws -> CGImage {
        let w = CGFloat(photo.width), h = CGFloat(photo.height)
        let pad = CGFloat(max(0, min(0.5, options.padding))) * max(w, h)
        var canvas = CGSize(width: w + 2 * pad, height: h + 2 * pad)
        if let ratio = options.ratio.value {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio } else { canvas.height = canvas.width / ratio }
        }
        guard canvas.width * canvas.height < 400_000_000 else { throw WheelError("This frame would be too large. Use less padding or a closer output ratio.") }
        let width = Int(canvas.width.rounded()), height = Int(canvas.height.rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WheelError("Could not prepare the image background.")
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        switch options.kind {
        case .transparent:
            break
        case .solid:
            let c = options.color.rgb
            context.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
            context.fill(full)
        case .gradient:
            let colors = (gradients.first { $0.id == options.preset } ?? gradients[0]).colors.map { hex -> CGColor in
                let c = hex.rgb
                return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            }
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: full.height), end: CGPoint(x: full.width, y: 0), options: [])
            }
        case .image:
            guard let path = options.imagePath, let backdrop = try? ImageConverter.load(URL(fileURLWithPath: path)) else {
                throw WheelError("Choose a background image.")
            }
            let bw = CGFloat(backdrop.cgImage.width), bh = CGFloat(backdrop.cgImage.height)
            let scale = max(full.width / bw, full.height / bh)
            let rect = CGRect(x: (full.width - bw * scale) / 2, y: (full.height - bh * scale) / 2, width: bw * scale, height: bh * scale)
            context.interpolationQuality = .high
            context.draw(backdrop.cgImage, in: rect)
        }
        let photoRect = CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h)
        let radius = CGFloat(max(0, min(0.5, options.cornerRadius))) * min(w, h)
        let path = CGPath(roundedRect: photoRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if options.shadow > 0 {
            context.saveGState()
            let blur = max(w, h) * 0.04 * CGFloat(options.shadow)
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur, color: CGColor(gray: 0, alpha: 0.35 + 0.25 * options.shadow))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(photo, in: photoRect)
        context.restoreGState()
        guard let image = context.makeImage() else { throw WheelError("Could not finish adding the background.") }
        return image
    }

    // MARK: Photo adjustments

    static func edit(_ source: URL, adjustments: ToolOptions.Adjustments) async throws -> URL {
        let photo = try ImageConverter.load(source)
        let output = try applyAdjustments(adjustments, to: photo.cgImage)
        return try await save(output, like: source, suffix: "Edited", metadata: photo.metadata, needsAlpha: photo.hasAlpha)
    }

    static func applyAdjustments(_ a: ToolOptions.Adjustments, to image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        var img = input
        let scale = Double(max(extent.width, extent.height)) / 1000 // keeps radius-based effects size-independent
        if a.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure / 50]) }
        if a.highlights != 0 || a.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 - max(0, -a.highlights) / 100 + max(0, a.highlights) / 200,
                                                                             "inputShadowAmount": a.shadows / 100])
        }
        if a.whites != 0 || a.blacks != 0 {
            let b = a.blacks / 400, w = a.whites / 400
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: max(0, b)), "inputPoint1": CIVector(x: 0.25, y: 0.25 + b * 0.5),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + (b + w) * 0.25), "inputPoint3": CIVector(x: 0.75, y: 0.75 + w * 0.5),
                "inputPoint4": CIVector(x: 1, y: min(1, 1 + w)),
            ])
        }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: a.brightness / 250, kCIInputContrastKey: 1 + a.contrast / 200,
                                                                    kCIInputSaturationKey: 1 + a.saturation / 100])
        }
        if a.temperature != 0 || a.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                          "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 30, y: a.tint)])
        }
        if a.vibrance != 0 { img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100]) }
        if a.hue != 0 { img = img.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue / 100 * .pi]) }
        if a.gamma != 0 { img = img.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -a.gamma / 100)]) }
        if a.dehaze != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + a.dehaze / 300, kCIInputSaturationKey: 1 + a.dehaze / 250,
                                                                    kCIInputBrightnessKey: -a.dehaze / 1200])
        }
        if a.clarity != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 20 * scale, kCIInputIntensityKey: a.clarity / 150]).cropped(to: extent)
        }
        if a.texture != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 3 * scale, kCIInputIntensityKey: a.texture / 120]).cropped(to: extent)
        }
        if a.sharpness > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness / 50, kCIInputRadiusKey: 1.5 * scale]) }
        if a.noiseReduction > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.002 + a.noiseReduction / 2500, kCIInputSharpnessKey: 0.4])
        }
        if a.blur > 0 { img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: a.blur / 10 * scale]).cropped(to: extent) }
        if a.fade > 0 {
            let f = a.fade / 300
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - f, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 - f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - f, w: 0), "inputBiasVector": CIVector(x: f * 0.9, y: f * 0.9, z: f * 0.9, w: 0),
            ])
        }
        if a.vignette != 0 {
            img = img.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                                                                       kCIInputRadiusKey: max(extent.width, extent.height) * 0.62,
                                                                       kCIInputIntensityKey: a.vignette / 100, "inputFalloff": 0.6])
        }
        if a.grain > 0 {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a.grain / 300),
                ])
            img = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: extent)
        }
        let space = rgbSpace(of: image)
        guard let output = ciContext.createCGImage(img.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space) else {
            throw WheelError("Could not render the photo adjustments.")
        }
        return output
    }

    // MARK: Redaction

    static func redact(_ source: URL, options: ToolOptions.Redact) async throws -> URL {
        guard !options.regions.isEmpty else { throw WheelError("Draw a rectangle over the area to hide.") }
        let photo = try ImageConverter.load(source)
        let output = try renderRedactions(photo.cgImage, options: options)
        // Redaction strips metadata too: it can describe what was hidden.
        return try await save(output, like: source, suffix: "Redacted", metadata: nil, needsAlpha: photo.hasAlpha)
    }

    static func renderRedactions(_ image: CGImage, options: ToolOptions.Redact) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var base = CIImage(cgImage: image)
        let extent = base.extent
        for region in options.regions {
            let rect = CGRect(x: region.x * w, y: (1 - region.y - region.height) * h, width: region.width * w, height: region.height * h).integral.intersection(extent)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let patch: CIImage
            if options.style == .blur {
                // Pixelate then blur: unrecoverable detail, soft look.
                let block = max(8, min(rect.width, rect.height) / 8)
                patch = base.cropped(to: rect).clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)])
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 0.6]).cropped(to: rect)
            } else {
                let c = options.color.rgb
                patch = CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b)).cropped(to: rect)
            }
            base = patch.composited(over: base)
        }
        let space = rgbSpace(of: image)
        guard let output = ciContext.createCGImage(base, from: extent, format: .RGBA8, colorSpace: space) else {
            throw WheelError("Could not prepare the redacted photo.")
        }
        return output
    }

    /// Faces or text regions, normalized with a top-left origin, padded slightly.
    static func detect(_ kind: String, in image: CGImage) throws -> [ToolOptions.Redaction] {
        let request: VNImageBasedRequest
        if kind == "faces" {
            request = VNDetectFaceRectanglesRequest()
        } else {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            request = text
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let boxes = (request.results as? [VNDetectedObjectObservation])?.map(\.boundingBox) ?? []
        return boxes.map { box in
            let pad = kind == "faces" ? 0.12 : 0.05
            let x = max(0, box.minX - box.width * pad), w = min(1 - x, box.width * (1 + 2 * pad))
            let top = max(0, 1 - box.maxY - box.height * pad), hgt = min(1 - top, box.height * (1 + 2 * pad))
            return ToolOptions.Redaction(x: x, y: top, width: w, height: hgt)
        }
    }

    // MARK: Collage

    static func collage(_ sources: [URL], options: ToolOptions.Collage) async throws -> URL {
        let ordered = options.order.isEmpty ? sources : options.order.map { URL(fileURLWithPath: $0) }
        guard ordered.count >= 2 else { throw WheelError("Select at least two images.") }
        let images = try ordered.map { try ImageConverter.load($0, maxPixelSize: 3000).cgImage }
        let output = try renderCollage(images, options: options)
        let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: ordered[0]), base: "Collage", extension: "png")
        return try await AtomicOutput.write(to: destination) {
            try ImageConverter.write(LoadedImage(cgImage: output, metadata: nil, dpi: nil), as: .png, quality: .high, keepMetadata: false, to: $0)
        }
    }

    static func collageCells(count: Int, options: ToolOptions.Collage, aspects: [CGFloat]) -> (CGSize, [CGRect]) {
        let width = CGFloat(max(400, min(8192, options.width)))
        let gap = width * CGFloat(options.spacing), pad = width * CGFloat(options.padding)
        var cells: [CGRect] = []
        var height: CGFloat
        switch options.layout {
        case .horizontal:
            let rowAspect = aspects.reduce(0, +)
            let cellHeight = (width - 2 * pad - gap * CGFloat(count - 1)) / max(rowAspect, 0.1)
            height = options.ratio.value.map { width / CGFloat($0) } ?? cellHeight + 2 * pad
            let h = height - 2 * pad
            var x = pad
            let scale = (width - 2 * pad - gap * CGFloat(count - 1)) / max(aspects.reduce(0, +) * h, 1)
            for aspect in aspects {
                let w = aspect * h * scale
                cells.append(CGRect(x: x, y: pad, width: w, height: h))
                x += w + gap
            }
        case .vertical:
            let w = width - 2 * pad
            let heights = aspects.map { w / max($0, 0.05) }
            height = options.ratio.value.map { width / CGFloat($0) } ?? heights.reduce(0, +) + gap * CGFloat(count - 1) + 2 * pad
            let scale = (height - 2 * pad - gap * CGFloat(count - 1)) / max(heights.reduce(0, +), 1)
            var y = pad
            for h in heights {
                cells.append(CGRect(x: pad, y: y, width: w, height: h * scale))
                y += h * scale + gap
            }
        case .featured:
            height = options.ratio.value.map { width / CGFloat($0) } ?? width * 0.75
            let inner = CGRect(x: pad, y: pad, width: width - 2 * pad, height: height - 2 * pad)
            let others = count - 1
            let mainWidth = others > 0 ? inner.width * 0.62 : inner.width
            cells.append(CGRect(x: inner.minX, y: inner.minY, width: mainWidth - (others > 0 ? gap / 2 : 0), height: inner.height))
            if others > 0 {
                let sideX = inner.minX + mainWidth + gap / 2, sideW = inner.width - mainWidth - gap / 2
                let h = (inner.height - gap * CGFloat(others - 1)) / CGFloat(others)
                for i in 0..<others { cells.append(CGRect(x: sideX, y: inner.minY + CGFloat(i) * (h + gap), width: sideW, height: h)) }
            }
        case .grid:
            let columns = options.columns > 0 ? options.columns : Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let cellW = (width - 2 * pad - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let averageAspect = aspects.reduce(0, +) / CGFloat(max(1, aspects.count))
            let cellH: CGFloat
            if let ratio = options.ratio.value {
                height = width / CGFloat(ratio)
                cellH = (height - 2 * pad - gap * CGFloat(rows - 1)) / CGFloat(rows)
            } else {
                cellH = cellW / max(averageAspect, 0.2)
                height = cellH * CGFloat(rows) + gap * CGFloat(rows - 1) + 2 * pad
            }
            for i in 0..<count {
                let r = i / columns, c = i % columns
                // The last row is centered when it isn't full.
                let inRow = r == rows - 1 ? count - r * columns : columns
                let offset = CGFloat(columns - inRow) * (cellW + gap) / 2
                cells.append(CGRect(x: pad + offset + CGFloat(c) * (cellW + gap), y: pad + CGFloat(r) * (cellH + gap), width: cellW, height: cellH))
            }
        }
        return (CGSize(width: width, height: height), cells)
    }

    static func renderCollage(_ images: [CGImage], options: ToolOptions.Collage) throws -> CGImage {
        let aspects = images.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) }
        let (size, cells) = collageCells(count: images.count, options: options, aspects: aspects)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 8, height >= 8, width <= 8192, height <= 8192,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WheelError("Choose a canvas and spacing that leave at least 8 × 8 pixels for each image (maximum canvas: 8192 × 8192).")
        }
        if options.background != "transparent" {
            let c = options.background.rgb
            context.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        for (image, cell) in zip(images, cells) {
            // Cells are laid out top-down; CoreGraphics draws bottom-up.
            let rect = CGRect(x: cell.minX, y: CGFloat(height) - cell.maxY, width: cell.width, height: cell.height)
            guard rect.width >= 8, rect.height >= 8 else {
                throw WheelError("Choose a canvas and spacing that leave at least 8 × 8 pixels for each image (maximum canvas: 8192 × 8192).")
            }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = options.fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
            let drawn = CGRect(x: rect.midX - iw * scale / 2, y: rect.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
            let radius = CGFloat(options.cornerRadius) * min(rect.width, rect.height)
            context.saveGState()
            let clip = options.fill ? rect : drawn
            context.addPath(CGPath(roundedRect: clip, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.draw(image, in: drawn)
            context.restoreGState()
        }
        guard let output = context.makeImage() else { throw WheelError("Could not render the collage.") }
        return output
    }

    // MARK: PDF from images

    static func createPDF(_ sources: [URL], order: [String]) async throws -> URL {
        let ordered = order.isEmpty ? sources : order.map { URL(fileURLWithPath: $0) }
        let images = try ordered.map { try ImageConverter.load($0) }
        let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: ordered[0]), base: "Combined Images", extension: "pdf")
        return try await AtomicOutput.write(to: destination) { try ImageConverter.writePDF(images, to: $0) }
    }

    // MARK: QR codes

    struct Code: Identifiable, Hashable {
        let id = UUID()
        let source: String
        let page: Int?
        let payload: String
        let symbology: String
    }

    // MARK: Text recognition

    /// Lines of text Vision reads in an image, in reading order, with normalized bounds (origin bottom-left).
    static func recognizeText(in image: CGImage) throws -> [(text: String, bounds: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw WheelError("Text recognition could not read this image: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap { observation in observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) } }
    }

    /// "Extract Text": the text of a photo, screenshot or scanned PDF as a .txt file. PDFs use their
    /// own text where pages have it and text recognition where they're scans.
    static func extractText(_ source: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        var text: String
        if FileFormat.detect(source) == .pdf {
            do {
                text = try PDFConverter.text(try PDFConverter.open(source), progress: progress)
            } catch let error as WheelError where error.message == "This PDF has no selectable text." {
                throw WheelError("No text was found in “\(source.lastPathComponent)”.")
            }
        } else {
            let image = try ImageConverter.load(source, maxPixelSize: 8192).cgImage
            text = try recognizeText(in: image).map(\.text).joined(separator: "\n")
            progress(1)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WheelError("No text was found in “\(source.lastPathComponent)”.") }
        let destination = OutputNaming.tool(source, suffix: "Text", extension: "txt")
        return try await AtomicOutput.write(to: destination) { try (text + "\n").write(to: $0, atomically: false, encoding: .utf8) }
    }

    static func readCodes(_ sources: [URL], progress: (Double) -> Void) throws -> [Code] {
        var codes: [Code] = []
        for (index, url) in sources.enumerated() {
            func scan(_ image: CGImage, page: Int?) throws {
                let request = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                for result in request.results ?? [] {
                    guard let payload = result.payloadStringValue, !payload.isEmpty else { continue }
                    if codes.contains(where: { $0.payload == payload && $0.source == url.lastPathComponent && $0.page == page }) { continue }
                    let name = result.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                    codes.append(Code(source: url.lastPathComponent, page: page, payload: payload, symbology: name))
                }
            }
            if FileFormat.detect(url) == .pdf, let document = PDFDocument(url: url) {
                // One page image at a time: a long PDF rendered up front would need gigabytes.
                for i in 0..<min(document.pageCount, 200) {
                    try autoreleasepool {
                        if let page = document.page(at: i), let image = PDFStructureReader.render(page, scale: 2.5) { try scan(image, page: i + 1) }
                    }
                }
            } else {
                try scan(try ImageConverter.load(url).cgImage, page: nil)
            }
            progress(Double(index + 1) / Double(sources.count))
        }
        return codes
    }

    // MARK: Annotations

    static func annotate(_ source: URL, options: ToolOptions.Annotate) async throws -> URL {
        guard !options.items.isEmpty else { throw WheelError("Add at least one annotation.") }
        let photo = try ImageConverter.load(source)
        let output = try renderAnnotations(options.items, on: photo.cgImage)
        return try await save(output, like: source, suffix: "Annotated", metadata: photo.metadata, needsAlpha: photo.hasAlpha)
    }

    static func renderAnnotations(_ items: [ToolOptions.Annotation], on image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WheelError("Could not prepare the annotated image.")
        }
        let w = CGFloat(width), h = CGFloat(height), side = min(w, h)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Annotation coordinates are top-left; flip once so they draw as authored.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        for item in items {
            AnnotationRenderer.draw(item, in: context, size: CGSize(width: w, height: h), side: side, source: image)
        }
        guard let output = context.makeImage() else { throw WheelError("Could not prepare the annotated image.") }
        return output
    }
}

/// Draws one annotation into a top-left-origin context. Shared by the editor preview and export.
enum AnnotationRenderer {
    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let c = hex.rgb
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    static func font(_ name: String, size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let design: NSFontDescriptor.SystemDesign = switch name {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// CoreText drawing into a top-left-origin rectangle of a flipped context.
    static func drawText(_ text: String, font: NSFont, color: CGColor, alignment: NSTextAlignment = .left, in rect: CGRect, context: CGContext) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color) ?? .black, .paragraphStyle: style,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        context.saveGState()
        // Local y-up space whose origin is the rectangle's bottom-left corner.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    static func draw(_ item: ToolOptions.Annotation, in context: CGContext, size: CGSize, side: CGFloat, source: CGImage?) {
        let p = { (x: Double, y: Double) in CGPoint(x: x * size.width, y: y * size.height) }
        let start = p(item.x, item.y), end = p(item.endX, item.endY)
        let line = max(1, CGFloat(item.lineWidth) * side)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch item.kind {
        case .arrow:
            context.setStrokeColor(color(item.color))
            context.setFillColor(color(item.color))
            context.setLineWidth(line)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = line * 4.2
            let base = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)
            context.move(to: start)
            context.addLine(to: base)
            context.strokePath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
            context.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
            context.closePath()
            context.fillPath()
        case .rectangle, .ellipse:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            context.setStrokeColor(color(item.color))
            context.setLineWidth(line)
            if item.kind == .rectangle {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: line * 1.5, cornerHeight: line * 1.5, transform: nil))
            } else {
                context.addEllipse(in: rect)
            }
            context.strokePath()
        case .freehand, .highlighter:
            guard let first = item.points.first, first.count == 2 else { return }
            let highlight = item.kind == .highlighter
            context.setStrokeColor(color(item.color, alpha: highlight ? 0.38 : 1))
            context.setLineWidth(highlight ? line * 4 : line)
            if highlight { context.setBlendMode(.multiply); context.setLineCap(.square) }
            context.move(to: p(first[0], first[1]))
            for point in item.points.dropFirst() where point.count == 2 { context.addLine(to: p(point[0], point[1])) }
            context.strokePath()
        case .text:
            let fontSize = max(6, CGFloat(item.fontSize) * side)
            let width = max(fontSize * 2, abs(end.x - start.x))
            drawText(item.text, font: font(item.font, size: fontSize), color: color(item.color), in: CGRect(x: start.x, y: start.y, width: width, height: size.height * 2), context: context)
        case .number:
            let radius = max(8, CGFloat(item.fontSize) * side * 0.75)
            let circle = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(color(item.color))
            context.fillEllipse(in: circle)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(max(1, radius * 0.12))
            context.strokeEllipse(in: circle)
            let labelFont = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
            let label = "\(item.number)" as NSString
            let labelSize = label.size(withAttributes: [.font: labelFont])
            drawText("\(item.number)", font: labelFont, color: CGColor(gray: 1, alpha: 1), alignment: .center,
                     in: CGRect(x: start.x - radius, y: start.y - labelSize.height / 2 - 1, width: radius * 2, height: labelSize.height + 4), context: context)
        case .magnifier:
            guard let source else { return }
            let radius = max(10, hypot(end.x - start.x, end.y - start.y))
            let zoom = max(1.2, CGFloat(item.magnification))
            let circle = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
            context.saveGState()
            context.addEllipse(in: circle)
            context.clip()
            // Canvas point q shows source point start + (q - start) / zoom; the flip draws the image upright.
            context.translateBy(x: start.x, y: start.y)
            context.scaleBy(x: zoom, y: zoom)
            context.translateBy(x: -start.x, y: -start.y)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
            context.setStrokeColor(color(item.color))
            context.setLineWidth(max(2, line))
            context.strokeEllipse(in: circle)
        case .image:
            guard let path = item.imagePath, let overlay = try? ImageConverter.load(URL(fileURLWithPath: path)).cgImage else { return }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(overlay, in: CGRect(origin: .zero, size: rect.size))
        }
    }
}
