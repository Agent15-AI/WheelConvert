import Foundation

/// Stream facts from ffprobe, used to pick encoders and validate results.
struct MediaInfo: Equatable {
    var duration: Double = 0
    var formatName = ""
    var bitRate = 0
    var hasVideo = false
    var hasAudio = false
    var videoCodec = ""
    var width = 0
    var height = 0
    var rotation = 0
    var frameRate: Double = 0
    var frameCount = 0
    var pixelFormat = ""
    var videoBitRate = 0
    var audioCodec = ""
    var audioChannels = 0
    var audioSampleRate = 0
    var audioBitRate = 0
    var audioBitsPerSample = 0
    var audioSampleFormat = ""
    var hasCoverArt = false
    var subtitleCodecs: [String] = []
    var tags: [String: String] = [:]

    /// Display size after applying rotation metadata.
    var displayWidth: Int { abs(rotation) % 180 == 90 ? height : width }
    var displayHeight: Int { abs(rotation) % 180 == 90 ? width : height }

    /// Bit depth of the source audio, for "match source" sample depth.
    var sourceSampleBits: Int {
        if audioBitsPerSample > 0 { return audioBitsPerSample }
        switch audioSampleFormat {
        case "s16", "s16p", "u8", "u8p": return 16
        case "s32", "s32p": return audioCodec.hasPrefix("pcm_s24") ? 24 : 32
        case "flt", "fltp", "dbl", "dblp": return 32
        default: return 16
        }
    }

    var isFloatAudio: Bool { audioSampleFormat.hasPrefix("flt") || audioSampleFormat.hasPrefix("dbl") || audioCodec.hasPrefix("pcm_f") }

    static func probe(_ url: URL) async throws -> MediaInfo {
        let output = try await ProcessRunner.run(Bundled.ffprobe, [
            "-v", "error", "-hide_banner", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard output.status == 0,
              let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            throw WheelError("The source file could not be read.")
        }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> MediaInfo {
        var info = MediaInfo()
        let format = json["format"] as? [String: Any] ?? [:]
        info.duration = number(format["duration"]) ?? 0
        info.formatName = format["format_name"] as? String ?? ""
        info.bitRate = Int(number(format["bit_rate"]) ?? 0)
        if let tags = format["tags"] as? [String: Any] {
            for (key, value) in tags { info.tags[key.lowercased()] = "\(value)" }
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            if type == "video" {
                if (disposition["attached_pic"] as? Int) == 1 {
                    info.hasCoverArt = true
                    continue
                }
                guard !info.hasVideo else { continue }
                info.hasVideo = true
                info.videoCodec = stream["codec_name"] as? String ?? ""
                info.width = stream["width"] as? Int ?? 0
                info.height = stream["height"] as? Int ?? 0
                info.pixelFormat = stream["pix_fmt"] as? String ?? ""
                info.videoBitRate = Int(number(stream["bit_rate"]) ?? 0)
                info.frameCount = Int(number(stream["nb_frames"]) ?? 0)
                info.frameRate = rate(stream["avg_frame_rate"] as? String) ?? rate(stream["r_frame_rate"] as? String) ?? 0
                if let rotate = (stream["tags"] as? [String: Any])?["rotate"], let value = Int("\(rotate)") {
                    info.rotation = value
                }
                for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
                    if let rotation = number(side["rotation"]) { info.rotation = Int(rotation) }
                }
                if info.duration == 0 { info.duration = number(stream["duration"]) ?? 0 }
            } else if type == "audio", !info.hasAudio {
                info.hasAudio = true
                info.audioCodec = stream["codec_name"] as? String ?? ""
                info.audioChannels = stream["channels"] as? Int ?? 0
                info.audioSampleRate = Int(number(stream["sample_rate"]) ?? 0)
                info.audioBitRate = Int(number(stream["bit_rate"]) ?? 0)
                info.audioSampleFormat = stream["sample_fmt"] as? String ?? ""
                info.audioBitsPerSample = Int(number(stream["bits_per_raw_sample"]) ?? 0)
                if info.audioBitsPerSample == 0 { info.audioBitsPerSample = stream["bits_per_sample"] as? Int ?? 0 }
                if info.duration == 0 { info.duration = number(stream["duration"]) ?? 0 }
            } else if type == "subtitle" {
                info.subtitleCodecs.append(stream["codec_name"] as? String ?? "")
            }
        }
        return info
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func rate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}
