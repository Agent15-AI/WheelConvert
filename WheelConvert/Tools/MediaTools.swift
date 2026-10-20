import CoreGraphics
import Foundation
import ImageIO

/// Audio and video tools built on ffmpeg. Results keep the source's container unless noted.
enum MediaTools {
    // MARK: Encoders

    /// Video encoder arguments for a container (plus container flags), without audio.
    static func videoCodecArgs(_ container: FileFormat, quality: Int = 72, hevc: Bool = false) -> [String] {
        switch container {
        case .webm:
            let crf = max(18, min(48, 60 - quality / 2))
            return ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(crf)", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
        case .avi:
            return ["-c:v", "mpeg4", "-q:v", "\(max(2, (100 - quality) / 12))", "-vtag", "XVID", "-pix_fmt", "yuv420p"]
        case .wmv:
            return ["-c:v", "wmv2", "-q:v", "\(max(2, (100 - quality) / 12))", "-pix_fmt", "yuv420p"]
        default:
            var args = ["-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox", "-q:v", "\(quality)", "-allow_sw", "1", "-pix_fmt", "yuv420p"]
            if container != .mkv { args += ["-tag:v", hevc ? "hvc1" : "avc1", "-movflags", "+faststart"] }
            return args
        }
    }

    /// The audio codec each video container expects.
    static func containerAudioArgs(_ container: FileFormat, bitrate: Int = 192) -> [String] {
        switch container {
        case .webm: ["-c:a", "libopus", "-b:a", "\(min(bitrate, 192))k", "-ar", "48000"]
        case .avi: ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case .wmv: ["-c:a", "wmav2", "-b:a", "\(bitrate)k"]
        default: ["-c:a", "aac_at", "-b:a", "\(bitrate)k"]
        }
    }

    /// Video + audio encoder arguments for re-encoding into a container at high quality.
    static func videoEncoder(_ container: FileFormat, quality: Int = 72, audioBitrate: Int = 192, hevc: Bool = false) -> [String] {
        videoCodecArgs(container, quality: quality, hevc: hevc) + containerAudioArgs(container, bitrate: audioBitrate)
    }

    /// Copies the audio when the container accepts it as is, otherwise encodes it.
    static func audioArgs(for container: FileFormat, info: MediaInfo) -> [String] {
        guard info.hasAudio else { return ["-an"] }
        return MediaConverter.canCopyAudio(info.audioCodec, into: container) ? ["-c:a", "copy"] : containerAudioArgs(container)
    }

    /// Audio encoder that keeps a file's format at transparent quality.
    static func audioEncoder(_ format: FileFormat, info: MediaInfo, bitrate: Int? = nil) -> [String] {
        let rate = bitrate ?? max(192, min(320, info.audioBitRate / 1000))
        switch format {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "\(rate)k"]
        case .m4a: return ["-c:a", "aac_at", "-b:a", "\(min(rate, 320))k"]
        case .ogg: return ["-c:a", "libvorbis", "-b:a", "\(min(rate, 320))k"]
        case .opus: return ["-c:a", "libopus", "-b:a", "\(min(rate, 256))k", "-ar", "48000"]
        case .flac: return ["-c:a", "flac", "-compression_level", "8"] + (MediaConverter.matchedDepth(info) == .bit16 ? ["-sample_fmt", "s16"] : ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"])
        case .wav: return ["-c:a", ["bit16": "pcm_s16le", "bit24": "pcm_s24le", "bit32": "pcm_s32le", "float32": "pcm_f32le"][MediaConverter.matchedDepth(info).rawValue]!]
        case .aiff:
            let depth = MediaConverter.matchedDepth(info)
            return ["-c:a", depth == .bit24 ? "pcm_s24be" : depth == .bit16 ? "pcm_s16be" : "pcm_s32be"]
        case .wma: return ["-c:a", "wmav2", "-b:a", "\(min(rate, 256))k"]
        default: return ["-c:a", "aac_at", "-b:a", "\(rate)k"]
        }
    }

    static func output(_ source: URL, suffix: String, format: FileFormat? = nil) -> URL {
        OutputNaming.tool(source, suffix: suffix, extension: format?.fileExtension)
    }

    static func format(_ url: URL) throws -> FileFormat {
        guard let format = FileFormat.detect(url) else { throw WheelError("This file type is not supported.") }
        return format
    }

    /// Runs ffmpeg into a temporary file beside the destination; only a finished file appears.
    static func render(_ args: [String], to destination: URL, duration: Double, progress: @escaping (Double) -> Void) async throws -> URL {
        try await AtomicOutput.write(to: destination) { temp in
            try await FFmpeg.run(args + [temp.path], duration: duration, progress: progress)
        }
    }

    // MARK: Compress

    static func compressVideo(_ source: URL, options: ToolOptions.Compress, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        guard info.hasVideo else { throw WheelError("This file has no playable video track.") }
        let original = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let target: Int64? = switch options.mode {
        case .preset: nil
        case .fileSize: options.targetBytes
        case .percentage: original * Int64(100 - min(99, max(1, options.reduction))) / 100
        }
        if let target, target >= original { throw WheelError("Target size cannot exceed the original file size.") }
        let container: FileFormat = options.videoFormat.flatMap { [.mp4, .mov, .mkv, .webm].contains($0) && format != .gif ? $0 : nil }
            ?? ([.mp4, .mov, .mkv, .webm, .gif].contains(format) ? format : .mp4)
        let destination = output(source, suffix: "Compressed", format: container)

        if container == .gif {
            let width = options.strength == .light ? 640 : options.strength == .balanced ? 480 : 360
            let colors = options.strength == .light ? 256 : options.strength == .balanced ? 128 : 64
            let filter = "[0:v]fps=\(options.strength == .strong ? 10 : 15),scale='min(\(width),iw)':-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=\(colors):stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle[g]"
            let url = try await render(["-i", source.path, "-filter_complex", filter, "-map", "[g]", "-loop", "0"], to: destination, duration: info.duration, progress: progress)
            return try ensureSmaller(url, than: original, target: target)
        }

        let scale = MediaConverter.scaleFilter(maxHeight: options.strength == .strong ? 1080 : 0, sourceHeight: info.displayHeight) + ",format=yuv420p"
        var audio = options.strength == .light ? 160 : options.strength == .balanced ? 128 : 96
        guard let target else {
            // Presets aim at a share of the source's video bitrate, so already-small files still shrink.
            let sourceKbps = Double(info.videoBitRate > 0 ? info.videoBitRate : max(0, info.bitRate - info.audioBitRate)) / 1000
            let share = options.strength == .light ? 0.65 : options.strength == .balanced ? 0.45 : 0.28
            let hevc = [.mp4, .mov, .mkv].contains(container)
            var args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-vf", scale]
            if sourceKbps > 50 {
                let rate = "\(max(80, Int(sourceKbps * share)))k"
                if container == .webm {
                    args += ["-c:v", "libvpx-vp9", "-b:v", rate, "-crf", "34", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
                } else {
                    args += ["-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox", "-b:v", rate, "-allow_sw", "1", "-pix_fmt", "yuv420p"]
                    if container != .mkv { args += ["-tag:v", hevc ? "hvc1" : "avc1", "-movflags", "+faststart"] }
                }
                args += info.hasAudio ? containerAudioArgs(container, bitrate: audio) : ["-an"]
            } else {
                let quality = options.strength == .light ? 62 : options.strength == .balanced ? 52 : 40
                args += videoEncoder(container, quality: quality, audioBitrate: audio, hevc: hevc)
            }
            let url = try await render(args, to: destination, duration: info.duration, progress: progress)
            return try ensureSmaller(url, than: original, target: nil)
        }
        guard info.duration > 0 else { throw WheelError("This file has no playable duration.") }
        let totalKbps = Double(target) * 8 / 1000 / info.duration * 0.96
        if !info.hasAudio { audio = 0 } else if totalKbps < 400 { audio = 64 }
        var videoKbps = totalKbps - Double(audio)
        guard videoKbps >= 60 else { throw WheelError("The target is too small for this duration. Choose a larger size.") }
        var smallest = Int64.max
        for _ in 0..<3 {
            var args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-vf", scale]
            let rate = "\(Int(videoKbps))k"
            if container == .webm {
                args += ["-c:v", "libvpx-vp9", "-b:v", rate, "-maxrate", rate, "-minrate", rate, "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "\(max(audio, 32))k", "-ar", "48000"]
            } else {
                args += ["-c:v", "h264_videotoolbox", "-b:v", rate, "-maxrate", rate, "-bufsize", "\(Int(videoKbps * 2))k", "-allow_sw", "1"]
                if container != .mkv { args += ["-tag:v", "avc1", "-movflags", "+faststart"] }
                if info.hasAudio { args += ["-c:a", "aac_at", "-b:a", "\(audio)k"] }
            }
            if !info.hasAudio { args.append("-an") }
            let url = try await render(args, to: destination, duration: info.duration, progress: progress)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            smallest = min(smallest, size)
            if size <= target { return url }
            try? FileManager.default.removeItem(at: url)
            videoKbps *= Double(target) / Double(max(size, 1)) * 0.94
            guard videoKbps >= 60 else { break }
        }
        throw WheelError("The encoder could not fit this video within the target. Smallest attempt was \(ByteCountFormatter.string(fromByteCount: smallest, countStyle: .file)). Choose a larger size.")
    }

    static func compressAudio(_ source: URL, options: ToolOptions.Compress, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        let original = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Lossless and legacy formats become AAC; lossy formats stay in their format at a lower bitrate.
        let outputFormat: FileFormat = [.mp3, .m4a, .ogg, .opus].contains(format) ? format : .m4a
        var bitrate: Int
        switch options.mode {
        case .preset:
            bitrate = outputFormat == .opus ? [96, 64, 48][strengthIndex(options.strength)] : [192, 128, 96][strengthIndex(options.strength)]
        case .fileSize, .percentage:
            let target = options.mode == .fileSize ? options.targetBytes : original * Int64(100 - min(99, max(1, options.reduction))) / 100
            guard target < original else { throw WheelError("Target size cannot exceed the original file size.") }
            guard info.duration > 0 else { throw WheelError("This file has no playable duration.") }
            bitrate = Int(Double(target) * 8 / 1000 / info.duration * 0.95)
            guard bitrate >= 24 else { throw WheelError("The target is too small for this duration. Choose a larger size.") }
            bitrate = min(bitrate, 320)
        }
        let args = ["-i", source.path, "-map", "0:a:0", "-vn"] + audioEncoder(outputFormat, info: info, bitrate: bitrate)
        let url = try await render(args, to: output(source, suffix: "Compressed", format: outputFormat), duration: info.duration, progress: progress)
        let target: Int64? = options.mode == .fileSize ? options.targetBytes : nil
        return try ensureSmaller(url, than: original, target: target)
    }

    static func strengthIndex(_ strength: CompressionStrength) -> Int { strength == .light ? 0 : strength == .balanced ? 1 : 2 }

    static func ensureSmaller(_ url: URL, than original: Int64, target: Int64?) throws -> URL {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size >= original || (target.map { size > $0 } ?? false) {
            try? FileManager.default.removeItem(at: url)
            throw WheelError("Compressed output would exceed the original or target file size.")
        }
        return url
    }

    // MARK: Trim

    static func trim(_ source: URL, options: ToolOptions.Trim, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        var start = max(0, options.start)
        var end = options.end > 0 ? min(options.end, info.duration) : info.duration
        if options.autoTrimSilence, format.category == .audio {
            let silence = try await silentEnds(source, threshold: options.silenceThreshold, duration: info.duration)
            start = max(start, silence.start)
            end = min(end, silence.end)
        }
        guard end - start >= 0.05 else { throw WheelError("Set a start and end within the file.") }
        var args = ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", end - start), "-i", source.path]
        if format.category == .audio {
            // Lossy audio is copied (no generation loss, frame-accurate); lossless is re-encoded exactly.
            let copy = MediaConverter.lossyAudioCodecs.contains(info.audioCodec) && format != .wma
            args += ["-map", "0:a:0", "-vn"] + (copy ? ["-c:a", "copy"] : audioEncoder(format, info: info))
        } else if format == .gif {
            args += ["-filter_complex", "[0:v]split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a[g]", "-map", "[g]", "-loop", "0"]
        } else {
            args += ["-map", "0:v:0", "-map", "0:a?", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"] + videoEncoder(format, quality: 75)
        }
        return try await render(args, to: output(source, suffix: "Trimmed"), duration: end - start, progress: progress)
    }

    /// Leading and trailing silence bounds from silencedetect.
    static func silentEnds(_ source: URL, threshold: Double, duration: Double) async throws -> (start: Double, end: Double) {
        guard (-80 ... -10).contains(threshold) else { throw WheelError("Choose a silence threshold between −80 and −10 dB.") }
        let log = try await FFmpeg.analyze(["-i", source.path, "-af", "silencedetect=noise=\(Int(threshold))dB:d=0.25", "-f", "null", "-"])
        var starts: [Double] = [], ends: [Double] = []
        for line in log.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: #"silence_start: ([0-9.eE+-]+)"#, options: .regularExpression) { starts.append(Double(line[r].split(separator: " ").last ?? "") ?? 0) }
            if let r = line.range(of: #"silence_end: ([0-9.eE+-]+)"#, options: .regularExpression) { ends.append(Double(line[r].split(separator: " ")[1]) ?? 0) }
        }
        var start = 0.0, end = duration
        if let first = starts.first, first <= 0.05, let firstEnd = ends.first { start = max(0, firstEnd - 0.05) }
        if let last = starts.last, ends.count < starts.count || (ends.last.map { $0 >= duration - 0.1 } ?? false), last > start { end = min(duration, last + 0.05) }
        guard end - start >= 0.05 else { throw WheelError("The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming.") }
        return (start, end)
    }

    // MARK: Crop / speed / mute

    static func crop(_ source: URL, options: ToolOptions.VideoCrop, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        let w = Double(info.displayWidth), h = Double(info.displayHeight)
        let cw = Int(options.width * w) / 2 * 2, ch = Int(options.height * h) / 2 * 2
        let cx = Int(options.x * w) / 2 * 2, cy = Int(options.y * h) / 2 * 2
        guard cw >= 2, ch >= 2, cx + cw <= Int(w) + 1, cy + ch <= Int(h) + 1 else { throw WheelError("Keep the crop inside the video frame.") }
        let args: [String]
        if format == .gif {
            args = ["-i", source.path, "-filter_complex", "[0:v]crop=\(cw):\(ch):\(cx):\(cy),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse[g]", "-map", "[g]", "-loop", "0"]
        } else {
            args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-vf", "crop=\(cw):\(ch):\(cx):\(cy),format=yuv420p"]
                + videoCodecArgs(format, quality: 75) + audioArgs(for: format, info: info)
        }
        return try await render(args, to: output(source, suffix: "Cropped"), duration: info.duration, progress: progress)
    }

    static func atempoChain(_ factor: Double) -> String {
        var remaining = factor
        var parts: [String] = []
        while remaining > 2 { parts.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { parts.append("atempo=0.5"); remaining /= 0.5 }
        parts.append(String(format: "atempo=%.4f", remaining))
        return parts.joined(separator: ",")
    }

    static func speed(_ source: URL, options: ToolOptions.Speed, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        let factor = options.factor
        guard (0.25...4).contains(factor) else { throw WheelError("Choose a speed between 0.25× and 4×.") }
        let label = factor == factor.rounded() ? "\(Int(factor))×" : String(format: "%.2g×", factor)
        var args = ["-i", source.path]
        if format == .gif {
            args += ["-filter_complex", "[0:v]setpts=PTS/\(factor),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse[g]", "-map", "[g]", "-loop", "0"]
        } else {
            var filter = "[0:v]setpts=(PTS-STARTPTS)/\(factor),format=yuv420p[v]"
            if info.hasAudio {
                let audio = options.preservePitch ? atempoChain(factor)
                    : "asetrate=\(max(8000, info.audioSampleRate))*\(factor),aresample=\(max(8000, info.audioSampleRate))"
                filter += ";[0:a:0]asetpts=PTS-STARTPTS,\(audio)[a]"
            }
            args += ["-filter_complex", filter, "-map", "[v]"] + (info.hasAudio ? ["-map", "[a]"] : []) + videoEncoder(format, quality: 72)
        }
        return try await render(args, to: output(source, suffix: "\(label) Speed"), duration: info.duration / factor, progress: progress)
    }

    static func mute(_ source: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        return try await render(["-i", source.path, "-map", "0", "-map", "-0:a", "-c", "copy"], to: output(source, suffix: "Muted"), duration: info.duration, progress: progress)
    }

    /// The container each audio codec can be copied into untouched.
    static let audioCopyFormats: [String: FileFormat] = ["aac": .m4a, "alac": .m4a, "mp3": .mp3, "opus": .opus, "vorbis": .ogg, "flac": .flac]

    /// A video's sound as an audio file: the track copied as it is when an audio format holds its codec
    /// (no quality loss, near-instant), otherwise encoded to AAC.
    static func extractAudio(_ source: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        let format: FileFormat, codec: [String]
        if let copy = audioCopyFormats[info.audioCodec] {
            (format, codec) = (copy, ["-c:a", "copy"])
        } else if info.audioCodec.hasPrefix("pcm_") {
            (format, codec) = (.wav, audioEncoder(.wav, info: info))
        } else {
            (format, codec) = (.m4a, ["-c:a", "aac_at", "-b:a", "256k"])
        }
        let args = ["-i", source.path, "-map", "0:a:0", "-vn", "-sn", "-dn"] + codec
        return try await render(args, to: output(source, suffix: "Audio", format: format), duration: info.duration, progress: progress)
    }

    // MARK: Join

    static func join(_ sources: [URL], progress: @escaping (Double) -> Void) async throws -> URL {
        guard sources.count >= 2 else { throw WheelError("Select at least two videos to join.") }
        var infos: [MediaInfo] = []
        for url in sources {
            let info = try await MediaInfo.probe(url)
            guard info.hasVideo else { throw WheelError("Every selected file must contain a video track.") }
            infos.append(info)
        }
        // The first clip sets the canvas.
        let width = max(2, infos[0].displayWidth / 2 * 2), height = max(2, infos[0].displayHeight / 2 * 2)
        var args: [String] = []
        for url in sources { args += ["-i", url.path] }
        var filter = ""
        var inputs = ""
        for (i, info) in infos.enumerated() {
            filter += "[\(i):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p,setpts=PTS-STARTPTS[v\(i)];"
            if info.hasAudio {
                filter += "[\(i):a:0]aformat=sample_rates=48000:channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(i)];"
            } else {
                filter += "anullsrc=r=48000:cl=stereo,atrim=duration=\(String(format: "%.3f", max(0.04, info.duration)))[a\(i)];"
            }
            inputs += "[v\(i)][a\(i)]"
        }
        filter += "\(inputs)concat=n=\(sources.count):v=1:a=1[v][a]"
        args += ["-filter_complex", filter, "-map", "[v]", "-map", "[a]"] + videoEncoder(.mp4, quality: 72)
        let destination = OutputNaming.unique(in: Publisher.destinationDirectory(for: sources[0]), base: "Joined Video", extension: "mp4")
        return try await render(args, to: destination, duration: infos.map(\.duration).reduce(0, +), progress: progress)
    }

    // MARK: Frames and splitting

    static func snapshots(_ source: URL, options: ToolOptions.Snapshots, progress: @escaping (Double) -> Void) async throws -> URL {
        let info = try await MediaInfo.probe(source)
        let times = options.times.filter { $0 >= 0 && $0 <= info.duration + 0.001 }.sorted()
        guard !times.isEmpty else { throw WheelError("Select at least one frame within the video.") }
        return try await Publisher.publish(for: source) { staging in
            var files: [URL] = []
            for (i, time) in times.enumerated() {
                let name = String(format: "Frame %03d - %.3fs.png", i + 1, time)
                let file = staging.url.appendingPathComponent(name)
                try await FFmpeg.run(["-ss", String(format: "%.3f", time), "-i", source.path, "-frames:v", "1", "-update", "1", file.path], duration: 0) { _ in }
                guard FileManager.default.fileExists(atPath: file.path) else { throw WheelError("No frame is available at this time. Choose an earlier frame.") }
                files.append(file)
                progress(Double(i + 1) / Double(times.count))
            }
            if files.count == 1 {
                let renamed = staging.url.appendingPathComponent("\(OutputNaming.baseName(of: source)) \(String(format: "%.3fs", times[0])).png")
                try FileManager.default.moveItem(at: files[0], to: renamed)
                files = [renamed]
            }
            return files
        }
    }

    static func clips(points: [Double], duration: Double) -> [(Double, Double)] {
        let cuts = ([0] + points.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted() + [duration])
        return zip(cuts, cuts.dropFirst()).map { ($0, $1) }.filter { $0.1 - $0.0 >= 0.05 }
    }

    static func split(_ source: URL, options: ToolOptions.Split, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        let parts = clips(points: options.points, duration: info.duration)
        guard parts.count >= 2 else { throw WheelError("Add split points inside the video, at least 0.05 seconds from either end.") }
        let encode: [String] = format == .gif ? [] : ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"] + videoEncoder(format, quality: 75)
        if options.export == .merged {
            let kept = parts.enumerated().filter { !options.removed.contains($0.offset) }.map(\.element)
            guard !kept.isEmpty else { throw WheelError("Keep at least one clip.") }
            guard kept.count < parts.count else { throw WheelError("Remove a clip to join the rest into one video, or export separate clips.") }
            var filter = ""
            var inputs = ""
            for (i, part) in kept.enumerated() {
                let range = "start=\(String(format: "%.3f", part.0)):end=\(String(format: "%.3f", part.1))"
                filter += "[0:v:0]trim=\(range),setpts=PTS-STARTPTS[v\(i)];"
                if info.hasAudio { filter += "[0:a:0]atrim=\(range),asetpts=PTS-STARTPTS[a\(i)];" }
                inputs += "[v\(i)]" + (info.hasAudio ? "[a\(i)]" : "")
            }
            filter += "\(inputs)concat=n=\(kept.count):v=1:a=\(info.hasAudio ? 1 : 0)[v]" + (info.hasAudio ? "[a]" : "")
            if format == .gif { filter = filter.replacingOccurrences(of: "[v]", with: "[vc]") + ";[vc]split[x][y];[x]palettegen[p];[y][p]paletteuse[v]" }
            var args = ["-i", source.path, "-filter_complex", filter, "-map", "[v]"] + (info.hasAudio ? ["-map", "[a]"] : [])
            args += format == .gif ? ["-loop", "0"] : videoEncoder(format, quality: 75)
            return try await render(args, to: output(source, suffix: "Edited"), duration: kept.map { $0.1 - $0.0 }.reduce(0, +), progress: progress)
        }
        let total = parts.map { $0.1 - $0.0 }.reduce(0, +)
        return try await Publisher.publish(for: source) { staging in
            var files: [URL] = []
            var done = 0.0
            for (i, part) in parts.enumerated() {
                let file = staging.url.appendingPathComponent("\(OutputNaming.sanitize(OutputNaming.baseName(of: source))) Part \(i + 1).\(format.fileExtension)")
                var args = ["-ss", String(format: "%.3f", part.0), "-t", String(format: "%.3f", part.1 - part.0), "-i", source.path]
                if format == .gif {
                    args += ["-filter_complex", "[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse[g]", "-map", "[g]", "-loop", "0"]
                } else {
                    args += ["-map", "0:v:0", "-map", "0:a?"] + encode
                }
                let done0 = done
                try await FFmpeg.run(args + [file.path], duration: part.1 - part.0) { progress((done0 + $0 * (part.1 - part.0)) / total) }
                done += part.1 - part.0
                files.append(file)
            }
            return files
        }
    }

    // MARK: Redact video

    static func redact(_ source: URL, options: ToolOptions.Redact, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        guard !options.regions.isEmpty else { throw WheelError("Draw a rectangle over the area to hide.") }
        let w = Double(info.displayWidth), h = Double(info.displayHeight)
        var filter = "[0:v:0]format=yuv420p[v0];"
        var current = "v0"
        let color = options.color.filter(\.isHexDigit)
        for (i, region) in options.regions.enumerated() {
            // Clamped into the frame: crop fails on any rectangle that reaches past an edge.
            let x = min(max(0, Int(region.x * w)), Int(w) - 2), y = min(max(0, Int(region.y * h)), Int(h) - 2)
            let rw = max(2, min(Int(region.width * w), Int(w) - x) / 2 * 2), rh = max(2, min(Int(region.height * h), Int(h) - y) / 2 * 2)
            var enable = ""
            if let start = region.start, let end = region.end, end > start {
                enable = ":enable='between(t,\(String(format: "%.3f", start)),\(String(format: "%.3f", end)))'"
            }
            let next = "v\(i + 1)"
            if options.style == .solid {
                filter += "[\(current)]drawbox=x=\(x):y=\(y):w=\(rw):h=\(rh):color=0x\(color.isEmpty ? "000000" : color)@1:t=fill\(enable)[\(next)];"
            } else {
                // Pixelate first so the detail is gone, then soften the blocks (LGPL filters only).
                let block = max(6, min(rw, rh) / 8)
                let sigma = max(6, min(rw, rh) / 8)
                filter += "[\(current)]split[m\(i)][c\(i)];[c\(i)]crop=\(rw):\(rh):\(x):\(y),pixelize=w=\(block):h=\(block),gblur=sigma=\(sigma):steps=3[b\(i)];"
                filter += "[m\(i)][b\(i)]overlay=\(x):\(y)\(enable)[\(next)];"
            }
            current = next
        }
        filter.removeLast()
        let args = ["-i", source.path, "-filter_complex", filter, "-map", "[\(current)]", "-map", "0:a?"]
            + videoCodecArgs(format, quality: 75) + audioArgs(for: format, info: info)
        return try await render(args, to: output(source, suffix: "Redacted"), duration: info.duration, progress: progress)
    }

    // MARK: Audio tools

    static func normalize(_ source: URL, options: ToolOptions.Normalize, progress: @escaping (Double) -> Void) async throws -> URL {
        guard (-70 ... -5).contains(options.targetLoudness), (1...50).contains(options.loudnessRange), (-9...0).contains(options.truePeak) else {
            throw WheelError("Choose a target from −70 to −5 LUFS, a loudness range from 1 to 50 LU, and a true peak from −9 to 0 dBTP.")
        }
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        let base = "loudnorm=I=\(options.targetLoudness):LRA=\(options.loudnessRange):TP=\(options.truePeak)"
        // Pass 1 measures; pass 2 applies the measured values for an accurate, linear result.
        let log = try await FFmpeg.analyze(["-i", source.path, "-map", "0:a:0", "-af", base + ":print_format=json", "-f", "null", "-"])
        progress(0.4)
        var filter = base
        if let open = log.lastIndex(of: "{"), let close = log.lastIndex(of: "}"), open < close,
           let json = try? JSONSerialization.jsonObject(with: Data(log[open...close].utf8)) as? [String: String] {
            let keys = ["input_i": "measured_I", "input_lra": "measured_LRA", "input_tp": "measured_TP", "input_thresh": "measured_thresh", "target_offset": "offset"]
            for (key, name) in keys {
                if let value = json[key], Double(value)?.isFinite == true { filter += ":\(name)=\(value)" }
            }
            filter += ":linear=true"
        }
        let rate = max(44_100, info.audioSampleRate)
        var args = ["-i", source.path]
        if format.category == .video {
            args += ["-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-af", filter + ",aresample=\(rate)"] + containerAudioArgs(format)
        } else {
            args += ["-map", "0:a:0", "-vn", "-af", filter + ",aresample=\(rate)"] + audioEncoder(format, info: info)
        }
        return try await render(args, to: output(source, suffix: "Normalized"), duration: info.duration) { progress(0.4 + $0 * 0.6) }
    }

    static func visualize(_ source: URL, options: ToolOptions.Visualizer, progress: @escaping (Double) -> Void) async throws -> URL {
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        let (w, h) = options.canvas.size
        let color = options.color.filter(\.isHexDigit), background = options.background.filter(\.isHexDigit)
        var args: [String]
        switch options.style {
        case .waveform:
            let waveHeight = h / 2 / 2 * 2
            args = ["-f", "lavfi", "-i", "color=c=0x\(background):s=\(w)x\(h):r=30", "-i", source.path, "-filter_complex",
                    "[1:a:0]aformat=channel_layouts=mono,showwaves=s=\(w)x\(waveHeight):mode=cline:rate=30:colors=0x\(color):scale=sqrt,format=yuva420p[wave];[0:v][wave]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]",
                    "-map", "[v]", "-map", "1:a:0"]
        case .staticImage:
            guard let path = options.imagePath, FileManager.default.fileExists(atPath: path) else { throw WheelError("Choose an image for the visualization.") }
            args = ["-loop", "1", "-framerate", "30", "-i", path, "-i", source.path, "-filter_complex",
                    "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=0x\(background),setsar=1,format=yuv420p[v]",
                    "-map", "[v]", "-map", "1:a:0", "-shortest"]
        }
        args += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1", "-tag:v", "avc1", "-c:a", "aac_at", "-b:a", "192k", "-movflags", "+faststart", "-t", String(format: "%.3f", info.duration)]
        return try await render(args, to: output(source, suffix: "Visualizer", format: .mp4), duration: info.duration, progress: progress)
    }

    static func channels(_ source: URL, options: ToolOptions.Channels, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        let l = max(0, min(2, options.leftVolume)), r = max(0, min(2, options.rightVolume))
        let pan: String
        if options.channels == 1 {
            pan = info.audioChannels >= 2 ? "pan=mono|c0=\(0.5 * l)*c0+\(0.5 * r)*c1" : "pan=mono|c0=\(l)*c0"
        } else {
            pan = info.audioChannels >= 2 ? "pan=stereo|c0=\(l)*c0|c1=\(r)*c1" : "pan=stereo|c0=\(l)*c0|c1=\(r)*c0"
        }
        var args = ["-i", source.path]
        if format.category == .video {
            args += ["-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-af", pan] + containerAudioArgs(format)
        } else {
            args += ["-map", "0:a:0", "-vn", "-af", pan] + audioEncoder(format, info: info)
        }
        return try await render(args, to: output(source, suffix: options.channels == 1 ? "Mono" : "Stereo"), duration: info.duration, progress: progress)
    }

    static func bleepFilter(_ ranges: [[Double]]) -> String {
        let condition = ranges.map { "between(t,\(String(format: "%.3f", $0[0])),\(String(format: "%.3f", $0[1])))" }.joined(separator: "+")
        return "asetpts=PTS-STARTPTS,aeval=exprs='if(gt(\(condition),0),0.18*sin(2*PI*1000*t),val(ch))':c=same"
    }

    static func bleep(_ source: URL, options: ToolOptions.Bleep, progress: @escaping (Double) -> Void) async throws -> URL {
        let format = try format(source)
        let info = try await MediaInfo.probe(source)
        guard info.hasAudio else { throw WheelError("This file has no audio track.") }
        let ranges = options.ranges.filter { $0.count == 2 && $0[1] > $0[0] && $0[0] < info.duration }
        guard !ranges.isEmpty else { throw WheelError("Add at least one bleep range.") }
        let args = ["-i", source.path, "-map", "0:a:0", "-vn", "-af", bleepFilter(ranges)] + audioEncoder(format, info: info)
        return try await render(args, to: output(source, suffix: "Bleeped"), duration: info.duration, progress: progress)
    }

    // MARK: Previews for the tool windows

    /// Peak envelope with `bins` points per channel, values 0…1.
    static func waveform(_ source: URL, bins: Int, stereo: Bool = false) async throws -> [[Float]] {
        let channels = stereo ? 2 : 1
        let output = try await ProcessRunner.run(Bundled.ffmpeg, ["-v", "error", "-i", source.path, "-map", "0:a:0", "-ac", "\(channels)", "-ar", "2000", "-f", "f32le", "-"])
        guard output.status == 0, !output.stdout.isEmpty else { throw WheelError("Could not read the audio waveform.") }
        let samples: [Float] = output.stdout.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = samples.count / channels
        guard frames > 0 else { throw WheelError("This file has no playable audio.") }
        var result = Array(repeating: [Float](repeating: 0, count: bins), count: channels)
        for frame in 0..<frames {
            let bin = min(bins - 1, frame * bins / frames)
            for c in 0..<channels {
                let value = abs(samples[frame * channels + c])
                if value > result[c][bin] { result[c][bin] = value }
            }
        }
        let peak = max(0.0001, result.flatMap { $0 }.max() ?? 1)
        return result.map { $0.map { min(1, $0 / peak) } }
    }

    /// Evenly spaced thumbnails. Seeking to each one decodes a few frames instead of the whole video,
    /// and four run at once, so long files fill the strip quickly.
    static func thumbnails(_ source: URL, count: Int, height: Int = 90, duration: Double) async throws -> [CGImage] {
        guard duration > 0, count > 0 else { return [] }
        var images = [CGImage?](repeating: nil, count: count)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for i in 0..<count {
                if i >= 4, let done = await group.next() { images[done.0] = done.1 }
                let time = (Double(i) + 0.5) * duration / Double(count)
                group.addTask { (i, try? await frame(source, at: time, maxHeight: height)) }
            }
            for await done in group { images[done.0] = done.1 }
        }
        try Task.checkCancellation()
        return images.compactMap { $0 }
    }

    static func frame(_ source: URL, at time: Double, maxHeight: Int = 720) async throws -> CGImage {
        let output = try await ProcessRunner.run(Bundled.ffmpeg, ["-v", "error", "-ss", String(format: "%.3f", max(0, time)), "-i", source.path, "-map", "0:v:0",
                                                                  "-frames:v", "1", "-vf", "scale=-2:'min(\(maxHeight),ih)'", "-f", "image2pipe", "-c:v", "png", "-"])
        guard let source = CGImageSourceCreateWithData(output.stdout as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WheelError("Could not decode the selected frame preview.")
        }
        return image
    }

    /// A playable copy of the whole file, for when `PreviewStream` can't start.
    static func previewCopy(_ source: URL, video: Bool) async throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WheelConvert-preview-\(UUID().uuidString).\(video ? "mp4" : "m4a")")
        let args = video
            ? ["-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-vf", "scale=-2:'min(720,ih)',format=yuv420p", "-c:v", "h264_videotoolbox", "-q:v", "55", "-allow_sw", "1", "-c:a", "aac_at", "-b:a", "160k", scratch.path]
            : ["-i", source.path, "-map", "0:a:0", "-vn", "-c:a", "aac_at", "-b:a", "192k", scratch.path]
        try await FFmpeg.run(args, duration: 0) { _ in }
        return scratch
    }
}
