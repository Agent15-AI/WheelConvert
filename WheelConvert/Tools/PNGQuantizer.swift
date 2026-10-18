import CoreGraphics
import Foundation

/// Lossy PNG compression: reduce an image to a palette (median cut over RGBA) and write an
/// indexed PNG with per-entry alpha. Typically 50–80% smaller than truecolor PNG.
enum PNGQuantizer {
    static func encode(_ image: CGImage, colors: Int) throws -> Data {
        let width = image.width, height = image.height
        var rgba = try pixels(image)
        let palette = medianCut(rgba, colors: max(2, min(256, colors)))
        var indices = [UInt8](repeating: 0, count: width * height)
        // Nearest palette entry per 5-bit RGB / 3-bit alpha cell, resolved lazily.
        var table = [Int16](repeating: -1, count: 32 * 32 * 32 * 8)
        rgba.withUnsafeMutableBufferPointer { p in
            for i in 0..<(width * height) {
                let o = i * 4
                let cell = (Int(p[o]) >> 3) << 14 | (Int(p[o + 1]) >> 3) << 9 | (Int(p[o + 2]) >> 3) << 4 | (Int(p[o + 3]) >> 5) << 1
                let key = cell >> 1
                if table[key] >= 0 { indices[i] = UInt8(table[key]); continue }
                var best = 0, bestDistance = Int.max
                for (j, c) in palette.enumerated() {
                    let dr = Int(p[o]) - Int(c.0), dg = Int(p[o + 1]) - Int(c.1), db = Int(p[o + 2]) - Int(c.2), da = Int(p[o + 3]) - Int(c.3)
                    let d = dr * dr * 3 + dg * dg * 4 + db * db * 2 + da * da * 3
                    if d < bestDistance { bestDistance = d; best = j }
                }
                table[key] = Int16(best)
                indices[i] = UInt8(best)
            }
        }
        return try png(width: width, height: height, palette: palette, indices: indices)
    }

    /// Straight (non-premultiplied) sRGB RGBA bytes.
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw WheelError("Could not read the image.") }
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Int(data[i + 3])
            if a > 0 && a < 255 {
                data[i] = UInt8(min(255, Int(data[i]) * 255 / a))
                data[i + 1] = UInt8(min(255, Int(data[i + 1]) * 255 / a))
                data[i + 2] = UInt8(min(255, Int(data[i + 2]) * 255 / a))
            }
        }
        return data
    }

    typealias Color = (UInt8, UInt8, UInt8, UInt8)

    private struct Box {
        var colors: [Color]
        var channel = 0
        var spread = 0

        init(_ colors: [Color]) {
            self.colors = colors
            var lo = (255, 255, 255, 255), hi = (0, 0, 0, 0)
            for c in colors {
                lo = (min(lo.0, Int(c.0)), min(lo.1, Int(c.1)), min(lo.2, Int(c.2)), min(lo.3, Int(c.3)))
                hi = (max(hi.0, Int(c.0)), max(hi.1, Int(c.1)), max(hi.2, Int(c.2)), max(hi.3, Int(c.3)))
            }
            let spreads = [hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2, hi.3 - lo.3]
            spread = spreads.max() ?? 0
            channel = spreads.firstIndex(of: spread) ?? 0
        }

        /// Larger, more varied boxes split first.
        var priority: Int { colors.count > 1 ? spread * colors.count : -1 }
    }

    /// Median cut on a sample of pixels; boxes split along their widest channel.
    static func medianCut(_ rgba: [UInt8], colors: Int) -> [Color] {
        let count = rgba.count / 4
        let step = max(1, count / 120_000)
        var samples: [Color] = []
        samples.reserveCapacity(count / step + 1)
        var i = 0
        while i < count {
            let o = i * 4
            samples.append((rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]))
            i += step
        }
        var boxes = [Box(samples)]
        while boxes.count < colors {
            guard let index = boxes.indices.max(by: { boxes[$0].priority < boxes[$1].priority }), boxes[index].priority > 0 else { break }
            var sorted = boxes[index].colors
            switch boxes[index].channel {
            case 0: sorted.sort { $0.0 < $1.0 }
            case 1: sorted.sort { $0.1 < $1.1 }
            case 2: sorted.sort { $0.2 < $1.2 }
            default: sorted.sort { $0.3 < $1.3 }
            }
            let mid = sorted.count / 2
            boxes[index] = Box(Array(sorted[..<mid]))
            boxes.append(Box(Array(sorted[mid...])))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0, a = 0
            for c in box.colors { r += Int(c.0); g += Int(c.1); b += Int(c.2); a += Int(c.3) }
            let n = max(1, box.colors.count)
            return (UInt8(r / n), UInt8(g / n), UInt8(b / n), UInt8(a / n))
        }
    }

    static func png(width: Int, height: Int, palette: [Color], indices: [UInt8]) throws -> Data {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: Data) {
            out.append32be(UInt32(body.count))
            var typed = Data(type.utf8)
            typed.append(body)
            out.append(typed)
            out.append32be(UInt32(ZipArchive.checksum(typed)))
        }
        var header = Data()
        header.append32be(UInt32(width)); header.append32be(UInt32(height))
        header.append(contentsOf: [8, 3, 0, 0, 0]) // 8-bit palette
        chunk("IHDR", header)
        chunk("PLTE", Data(palette.flatMap { [$0.0, $0.1, $0.2] }))
        if palette.contains(where: { $0.3 < 255 }) {
            var alpha = palette.map(\.3)
            while alpha.last == 255 { alpha.removeLast() }
            chunk("tRNS", Data(alpha))
        }
        var raw = Data(capacity: (width + 1) * height)
        for y in 0..<height {
            raw.append(0) // no filter: palette images compress best unfiltered
            raw.append(contentsOf: indices[(y * width)..<((y + 1) * width)])
        }
        chunk("IDAT", try zlibCompress(raw))
        chunk("IEND", Data())
        return out
    }

    static func zlibCompress(_ input: Data) throws -> Data {
        var length = compressBound(uLong(input.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                compress2(out.bindMemory(to: Bytef.self).baseAddress, &length, inp.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), 9)
            }
        }
        guard status == Z_OK else { throw WheelError("Could not create the compressed PNG.") }
        output.count = Int(length)
        return output
    }
}

extension Data {
    mutating func append32be(_ value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
}
