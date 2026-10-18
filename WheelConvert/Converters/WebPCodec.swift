import CoreGraphics
import Foundation

/// WebP encoding through the statically linked libwebp (ImageIO can only decode WebP).
enum WebPCodec {
    /// - Parameters:
    ///   - quality: 0–100 for lossy encoding.
    ///   - targetSize: When set, libwebp searches quality to land at or under this many bytes.
    static func encode(_ image: CGImage, quality: Float, lossless: Bool = false, targetSize: Int? = nil) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16383, height <= 16383 else {
            throw WheelError("WebP images can be at most 16,383 pixels on each side.")
        }
        // libwebp has no color management; convert to sRGB RGBA first.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
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
        return Data(bytes: mem, count: writer.pointee.size)
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
