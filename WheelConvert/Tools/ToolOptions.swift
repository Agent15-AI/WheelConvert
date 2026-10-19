import Foundation

/// Settings for each file tool. All geometry is normalized (0…1, origin top-left) unless noted,
/// so one set of choices applies to images of any size.
enum ToolOptions {
    struct Compress: Codable, Equatable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            case preset, fileSize, percentage
            var id: String { rawValue }
            var title: String { self == .preset ? "Preset" : self == .fileSize ? "Target Size" : "Percentage" }
        }
        var mode: Mode = .preset
        var strength: CompressionStrength = .balanced
        /// Bytes, for `.fileSize`.
        var targetBytes: Int64 = 1_000_000
        /// 1…99, for `.percentage`.
        var reduction = 50
        /// Longest edge for images; 0 keeps the size.
        var maxDimension = 0
        /// Container for compressed video (MP4, MOV, MKV or WebM); nil keeps the source's when it can.
        var videoFormat: FileFormat?
        /// Floyd–Steinberg dithering when PNGs are reduced to a palette, so gradients don't band.
        var dither = true
    }

    struct Metadata: Codable, Equatable {
        var removeAll = false
        /// Tag name → new value; nil removes the tag.
        var changes: [String: String?] = [:]
    }

    struct Adjustments: Codable, Equatable {
        // Ranges are -100…100 unless noted; 0 is unchanged.
        var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
        var whites = 0.0, blacks = 0.0, temperature = 0.0, tint = 0.0, saturation = 0.0, vibrance = 0.0
        var hue = 0.0, gamma = 0.0, clarity = 0.0, texture = 0.0, sharpness = 0.0, dehaze = 0.0
        var fade = 0.0, vignette = 0.0, grain = 0.0, noiseReduction = 0.0, blur = 0.0

        static let neutral = Adjustments()
        var isNeutral: Bool { self == .neutral }
    }

    struct Background: Codable, Equatable {
        enum Kind: String, Codable { case gradient, solid, image, transparent }
        enum Ratio: String, Codable, CaseIterable, Identifiable {
            case automatic, square, landscape16x9, landscape4x3, portrait4x5, portrait9x16
            var id: String { rawValue }
            var title: String {
                switch self {
                case .automatic: "Automatic"
                case .square: "Square · 1:1"
                case .landscape16x9: "Landscape · 16:9"
                case .landscape4x3: "Landscape · 4:3"
                case .portrait4x5: "Portrait · 4:5"
                case .portrait9x16: "Portrait · 9:16"
                }
            }
            var value: Double? {
                switch self {
                case .automatic: nil
                case .square: 1
                case .landscape16x9: 16.0 / 9
                case .landscape4x3: 4.0 / 3
                case .portrait4x5: 4.0 / 5
                case .portrait9x16: 9.0 / 16
                }
            }
        }
        var kind: Kind = .gradient
        var preset = "dusk"
        /// Hex RGB for `.solid`.
        var color = "FFFFFF"
        var imagePath: String?
        /// Padding as a fraction of the photo's longer side.
        var padding = 0.08
        /// Corner radius as a fraction of the photo's shorter side.
        var cornerRadius = 0.03
        var shadow = 0.5
        var ratio: Ratio = .automatic
    }

    struct Crop: Codable, Equatable {
        var x = 0.0, y = 0.0, width = 1.0, height = 1.0
        /// Exact output pixels, applied after cropping; 0 keeps the cropped size.
        var outputWidth = 0
        var outputHeight = 0
    }

    struct Redaction: Codable, Equatable, Identifiable {
        var id = UUID()
        var x: Double, y: Double, width: Double, height: Double
        /// Seconds, for video. nil spans the whole file.
        var start: Double?
        var end: Double?
    }

    struct Redact: Codable, Equatable {
        enum Style: String, Codable, CaseIterable, Identifiable {
            case solid, blur
            var id: String { rawValue }
            var title: String { rawValue.capitalized }
        }
        var regions: [Redaction] = []
        var style: Style = .solid
        var color = "000000"
    }

    struct Collage: Codable, Equatable {
        enum Layout: String, Codable, CaseIterable, Identifiable {
            case grid, horizontal, vertical, featured
            var id: String { rawValue }
            var title: String { self == .horizontal ? "Row" : self == .vertical ? "Column" : rawValue.capitalized }
        }
        var layout: Layout = .grid
        var columns = 0          // 0 picks automatically
        var width = 2400
        var ratio: Background.Ratio = .automatic
        var spacing = 0.012      // fraction of width
        var padding = 0.02
        var cornerRadius = 0.0   // fraction of cell's shorter side
        var fill = true          // crop to fill cells, or fit whole images
        var background = "FFFFFF"
        var order: [String] = [] // file paths in order; empty keeps the selection order
    }

    struct Annotate: Codable, Equatable {
        var items: [Annotation] = []
    }

    struct Annotation: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable, Identifiable {
            case arrow, freehand, rectangle, ellipse, highlighter, text, number, magnifier, image
            var id: String { rawValue }
        }
        var id = UUID()
        var kind: Kind
        /// Start/end (arrow, rectangle, ellipse, magnifier source, text box) in normalized coordinates.
        var x = 0.0, y = 0.0, endX = 0.0, endY = 0.0
        var points: [[Double]] = []
        var text = ""
        var number = 1
        var color = "FF3B30"
        /// Stroke width as a fraction of the image's shorter side.
        var lineWidth = 0.006
        var fontSize = 0.045
        var font = "system"
        var magnification = 2.0
        var imagePath: String?
    }

    struct Trim: Codable, Equatable {
        var start = 0.0
        var end = 0.0              // 0 = to the end
        var autoTrimSilence = false
        var silenceThreshold = -45.0
    }

    struct VideoCrop: Codable, Equatable {
        var x = 0.0, y = 0.0, width = 1.0, height = 1.0
    }

    struct Speed: Codable, Equatable {
        var factor = 2.0
        var preservePitch = true
    }

    struct Snapshots: Codable, Equatable {
        var times: [Double] = []
    }

    struct Split: Codable, Equatable {
        enum Export: String, Codable { case clips, merged }
        var points: [Double] = []
        var removed: [Int] = []
        var export: Export = .clips
    }

    struct Normalize: Codable, Equatable {
        var targetLoudness = -16.0
        var loudnessRange = 11.0
        var truePeak = -1.5
    }

    struct Visualizer: Codable, Equatable {
        enum Style: String, Codable { case waveform, staticImage }
        enum Canvas: String, Codable, CaseIterable, Identifiable {
            case landscape, portrait, square
            var id: String { rawValue }
            var title: String { self == .landscape ? "Landscape · 16:9" : self == .portrait ? "Portrait · 9:16" : "Square · 1:1" }
            var size: (Int, Int) { self == .landscape ? (1920, 1080) : self == .portrait ? (1080, 1920) : (1080, 1080) }
        }
        var style: Style = .waveform
        var canvas: Canvas = .landscape
        var imagePath: String?
        var color = "6B5CFF"
        var background = "0B0B12"
    }

    struct Channels: Codable, Equatable {
        var channels = 1
        /// 0…2 (1 = unchanged).
        var leftVolume = 1.0
        var rightVolume = 1.0
    }

    struct Bleep: Codable, Equatable {
        var ranges: [[Double]] = []   // [start, end] seconds
    }

    struct Order: Codable, Equatable {
        var paths: [String] = []
    }

    struct OrganizePDF: Codable, Equatable {
        struct Page: Codable, Equatable, Identifiable {
            var id = UUID()
            var source: Int
            var rotation = 0
        }
        var pages: [Page] = []
        var equalWidths = false
    }

    struct SplitPDF: Codable, Equatable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            case everyPage, everyN, ranges
            var id: String { rawValue }
            var title: String { self == .everyPage ? "Every Page" : self == .everyN ? "Every N Pages" : "Custom Ranges" }
        }
        var mode: Mode = .everyPage
        var every = 2
        var ranges = "1-2, 3-"
    }
}

extension String {
    /// "FF8800" → components 0…1.
    var rgb: (r: Double, g: Double, b: Double) {
        let hex = filter(\.isHexDigit)
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return (0, 0, 0) }
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
}

extension JSONDecoder {
    /// Decodes `T`, taking any key the JSON leaves out from `defaults` (synthesized Decodable would fail instead).
    func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any] ?? [:]
        let given = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try decode(T.self, from: JSONSerialization.data(withJSONObject: base.merging(given) { $1 }))
    }
}

extension ToolOptions.Redaction {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
    }
}

extension ToolOptions.Annotation {
    init(kind: Kind) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var item = ToolOptions.Annotation(kind: try c.decode(Kind.self, forKey: .kind))
        item.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? item.id
        item.x = try c.decodeIfPresent(Double.self, forKey: .x) ?? item.x
        item.y = try c.decodeIfPresent(Double.self, forKey: .y) ?? item.y
        item.endX = try c.decodeIfPresent(Double.self, forKey: .endX) ?? item.endX
        item.endY = try c.decodeIfPresent(Double.self, forKey: .endY) ?? item.endY
        item.points = try c.decodeIfPresent([[Double]].self, forKey: .points) ?? item.points
        item.text = try c.decodeIfPresent(String.self, forKey: .text) ?? item.text
        item.number = try c.decodeIfPresent(Int.self, forKey: .number) ?? item.number
        item.color = try c.decodeIfPresent(String.self, forKey: .color) ?? item.color
        item.lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? item.lineWidth
        item.fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? item.fontSize
        item.font = try c.decodeIfPresent(String.self, forKey: .font) ?? item.font
        item.magnification = try c.decodeIfPresent(Double.self, forKey: .magnification) ?? item.magnification
        item.imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        self = item
    }
}

extension ToolOptions.OrganizePDF.Page {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try c.decode(Int.self, forKey: .source)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
    }
}
