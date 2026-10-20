import CoreGraphics
import Foundation
import ImageIO

/// WebP encoding through the statically linked libwebp (ImageIO can only decode WebP); libwebpmux
/// adds the EXIF, XMP and ICC chunks.
enum WebPCodec {
    /// - Parameters:
    ///   - quality: 0–100 for lossy encoding.
    ///   - targetSize: When set, libwebp searches quality to land at or under this many bytes.
    ///   - metadata: EXIF and XMP to embed. With it, a photo also keeps its own RGB color profile
    ///     (Display P3…) instead of being converted to sRGB.
    static func encode(_ image: CGImage, quality: Float, lossless: Bool = false, targetSize: Int? = nil, metadata: CGImageMetadata? = nil) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16383, height <= 16383 else {
            throw WheelError("WebP images can be at most 16,383 pixels on each side.")
        }
        // libwebp has no color management: pixels go in either as sRGB or in the profile that's embedded.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let profile = metadata == nil ? nil : image.colorSpace.flatMap { $0.model == .rgb && $0.name != CGColorSpace.sRGB ? $0.copyICCData() as Data? : nil }
        let space = profile != nil ? image.colorSpace! : sRGB
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw WheelError("ImageIO could not prepare the WebP conversion.") }
        unpremultiply(&pixels)

        var config = WebPConfig()
        guard WebPConfigInitInternal(&config, WEBP_PRESET_PHOTO, quality, WEBP_ENCODER_ABI_VERSION) != 0 else {
            throw WheelError("The WebP encoder could not start.")
        }
        config.lossless = lossless ? 1 : 0
        config.method = 4
        config.use_sharp_yuv = 1
        if let targetSize {
            config.target_size = Int32(clamping: targetSize)
            config.pass = 6
        }
        guard WebPValidateConfig(&config) != 0 else { throw WheelError("The WebP settings are invalid.") }

        var picture = WebPPicture()
        guard WebPPictureInitInternal(&picture, WEBP_ENCODER_ABI_VERSION) != 0 else { throw WheelError("The WebP encoder could not start.") }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = lossless ? 1 : 0
        let imported = pixels.withUnsafeBufferPointer { WebPPictureImportRGBA(&picture, $0.baseAddress, Int32(stride)) }
        guard imported != 0 else { throw WheelError("ImageIO could not prepare the WebP conversion.") }

        // The writer must outlive WebPEncode at a stable address, so it lives on the heap.
        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        WebPMemoryWriterInit(writer)
        defer { WebPMemoryWriterClear(writer); writer.deallocate() }
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)
        guard WebPEncode(&config, &picture) != 0, let mem = writer.pointee.mem else {
            throw WheelError("The WebP encoder could not encode this image.")
        }
        let encoded = Data(bytes: mem, count: writer.pointee.size)
        guard let metadata else { return encoded }
        return try embed(encoded, exif: exif(metadata, width: width, height: height), xmp: xmp(metadata), icc: profile)
    }

    /// Adds metadata chunks to an encoded WebP.
    static func embed(_ webp: Data, exif: Data?, xmp: Data?, icc: Data?) throws -> Data {
        let chunks = [("ICCP", icc), ("EXIF", exif), ("XMP ", xmp)].compactMap { tag, data in data.map { (tag, $0) } }
        guard !chunks.isEmpty else { return webp }
        return try webp.withUnsafeBytes { (image: UnsafeRawBufferPointer) -> Data in
            var bitstream = WebPData(bytes: image.bindMemory(to: UInt8.self).baseAddress, size: image.count)
            guard let mux = WebPMuxCreateInternal(&bitstream, 1, WEBP_MUX_ABI_VERSION) else { throw WheelError("The WebP metadata could not be added.") }
            defer { WebPMuxDelete(mux) }
            for (tag, data) in chunks {
                let status = data.withUnsafeBytes { bytes -> WebPMuxError in
                    var chunk = WebPData(bytes: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)
                    return WebPMuxSetChunk(mux, tag, &chunk, 1)
                }
                guard status == WEBP_MUX_OK else { throw WheelError("The WebP metadata could not be added.") }
            }
            var assembled = WebPData()
            guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK, let bytes = assembled.bytes else { throw WheelError("The WebP metadata could not be added.") }
            defer { WebPDataClear(&assembled) }
            return Data(bytes: bytes, count: assembled.size)
        }
    }

    /// The EXIF block for these properties. ImageIO doesn't hand raw EXIF out, but writes it into a
    /// JPEG's APP1 segment, so a 1×1 JPEG carries it; its pixel dimensions are then set to the image's.
    static func exif(_ metadata: CGImageMetadata, width: Int, height: Int) -> Data? {
        let jpeg = NSMutableData()
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixel = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(destination, pixel, metadata, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = [UInt8](jpeg as Data)
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF, bytes[i + 1] != 0xDA {
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let payload = bytes[(i + 4)..<min(bytes.count, i + 2 + length)]
            if bytes[i + 1] == 0xE1, payload.starts(with: Array("Exif\0\0".utf8)) {
                var tiff = Array(payload.dropFirst(6))
                setPixelDimensions(&tiff, width: width, height: height)
                return Data(tiff)
            }
            i += 2 + length
        }
        return nil
    }

    /// Rewrites PixelXDimension and PixelYDimension (0xA002, 0xA003) in the EXIF sub-IFD of a TIFF block.
    static func setPixelDimensions(_ tiff: inout [UInt8], width: Int, height: Int) {
        guard tiff.count >= 8 else { return }
        let little = tiff[0] == 0x49
        func read(_ offset: Int, _ size: Int) -> Int {
            guard offset >= 0, offset + size <= tiff.count else { return -1 }
            return (0..<size).reduce(0) { value, k in value | Int(tiff[offset + (little ? k : size - 1 - k)]) << (8 * k) }
        }
        func write(_ offset: Int, _ size: Int, _ value: Int) {
            for k in 0..<size { tiff[offset + (little ? k : size - 1 - k)] = UInt8((value >> (8 * k)) & 0xFF) }
        }
        func entries(_ ifd: Int) -> [(tag: Int, type: Int, at: Int)] {
            let count = read(ifd, 2)
            guard count > 0, count < 512 else { return [] }
            return (0..<count).map { n in let at = ifd + 2 + n * 12; return (read(at, 2), read(at + 2, 2), at) }
        }
        guard let pointer = entries(read(4, 4)).first(where: { $0.tag == 0x8769 }) else { return }
        for entry in entries(read(pointer.at + 8, 4)) where entry.tag == 0xA002 || entry.tag == 0xA003 {
            let value = entry.tag == 0xA002 ? width : height
            if entry.type == 3 { write(entry.at + 8, 2, min(value, 65_535)) } else if entry.type == 4 { write(entry.at + 8, 4, value) }
        }
    }

    /// An XMP packet, only when the image has XMP of its own (titles, keywords, ratings…) rather than
    /// just the EXIF and TIFF values the EXIF chunk already carries.
    static func xmp(_ metadata: CGImageMetadata) -> Data? {
        guard let own = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        var paths: [String] = [], kept = 0
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            if ["exif", "exifEX", "tiff", "aux"].contains(CGImageMetadataTagCopyPrefix(tag) as String? ?? "") { paths.append(path as String) } else { kept += 1 }
            return true
        }
        guard kept > 0 else { return nil }
        for path in paths { CGImageMetadataRemoveTagWithPath(own, nil, path as CFString) }
        return CGImageMetadataCreateXMPData(own, nil) as Data?
    }

    private static func unpremultiply(_ pixels: inout [UInt8]) {
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let a = Int(p[i + 3])
                if a > 0 && a < 255 {
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
    }
}
