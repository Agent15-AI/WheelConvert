import Foundation

/// Audio and video conversions through ffmpeg. Streams are copied untouched whenever the
/// target container accepts them, which is lossless and near-instant; otherwise they are
/// encoded with hardware VideoToolbox/AudioToolbox encoders where available.
enum MediaConverter {
    static func convert(_ source: URL, from input: FileFormat, to target: FileFormat, options: ConversionOptions,
                        destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = try await MediaInfo.probe(source)
        guard info.duration > 0 || target == .gif || input == .gif else {
            throw WheelError("This file has no playable duration.")
        }
        // AVI often lacks presentation timestamps, which stream copies into MP4/MOV/MKV need.
        var args = input == .avi ? ["-fflags", "+genpts", "-i", source.path] : ["-i", source.path]
        switch target.category {
        case .audio:
            guard info.hasAudio else { throw WheelError("This file has no audio track.") }
            args += audioArguments(target, info: info, options: options)
        case .video where target == .gif:
            guard info.hasVideo else { throw WheelError("This file has no playable video track.") }
            args += gifArguments(info: info, options: options)
        case .video:
            guard info.hasVideo else { throw WheelError("This file has no playable video track.") }
            args += videoArguments(from: input, to: target, info: info, options: options)
        default:
            throw WheelError("Conversion from \(input.title) to \(target.title) is unavailable.")
        }
        if !options.preserveMetadata { args += ["-map_metadata", "-1", "-map_chapters", "-1"] }
        args.append(destination.path)
        try await FFmpeg.run(args, duration: info.duration, progress: progress)
        try await verify(destination, expectVideo: target.category == .video, expectAudio: target.category == .audio)
    }

    // MARK: Audio

    static let lossyAudioCodecs: Set<String> = ["mp3", "mp2", "aac", "vorbis", "opus", "wmav1", "wmav2", "ac3", "eac3", "amr_nb", "amr_wb"]

    /// Bits per sample that "Match Source" resolves to; lossy sources decode to float but carry ~16 bits.
    static func matchedDepth(_ info: MediaInfo) -> ConversionOptions.SampleDepth {
        if lossyAudioCodecs.contains(info.audioCodec) { return .bit16 }
        if info.isFloatAudio { return .float32 }
        switch info.sourceSampleBits {
        case 24: return .bit24
        case 32: return .bit32
        default: return .bit16
        }
    }

    static func audioArguments(_ target: FileFormat, info: MediaInfo, options: ConversionOptions) -> [String] {
        var args: [String] = []
        let keepsCover = info.hasCoverArt && [.mp3, .m4a, .flac].contains(target) && options.preserveMetadata
        args += ["-map", "0:a:0"]
        if keepsCover { args += ["-map", "0:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"] } else { args += ["-vn", "-sn", "-dn"] }
        let bitrate = "\(options.audioBitrate)k"
        var depth = options.audioSampleDepth == .matchSource ? matchedDepth(info) : options.audioSampleDepth
        switch target {
        case .mp3:
            args += ["-c:a", "libmp3lame", "-b:a", bitrate]
            if keepsCover { args += ["-id3v2_version", "3"] }
        case .m4a:
            args += ["-c:a", "aac_at", "-b:a", bitrate]
        case .ogg:
            args += ["-c:a", "libvorbis", "-b:a", bitrate]
        case .opus:
            args += ["-c:a", "libopus", "-b:a", bitrate, "-vbr", "on", "-ar", "48000"]
        case .wav:
            let codec = ["bit16": "pcm_s16le", "bit24": "pcm_s24le", "bit32": "pcm_s32le", "float32": "pcm_f32le"][depth.rawValue]!
            args += ["-c:a", codec]
        case .aiff:
            if depth == .float32 { depth = .bit32 } // AIFF stores integer PCM
            let codec = ["bit16": "pcm_s16be", "bit24": "pcm_s24be", "bit32": "pcm_s32be"][depth.rawValue]!
            args += ["-c:a", codec]
        case .flac:
            // FLAC is integer-only and ffmpeg's encoder tops out at 24 bits.
            let bits = depth == .bit16 ? 16 : 24
            args += ["-c:a", "flac", "-compression_level", "\(options.compression == .fast ? 2 : options.compression == .balanced ? 5 : 8)"]
            args += bits == 16 ? ["-sample_fmt", "s16"] : ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
        default:
            break
        }
        return args
    }

    // MARK: Video

    static func canCopyVideo(_ codec: String, into target: FileFormat) -> Bool {
        switch target {
        case .mp4, .mov: ["h264", "hevc", "mpeg4", "prores", "av1"].contains(codec) && !(target == .mp4 && codec == "prores")
        case .mkv: !["gif", "rawvideo"].contains(codec)
        case .webm: ["vp8", "vp9", "av1"].contains(codec)
        default: false
        }
    }

    static func canCopyAudio(_ codec: String, into target: FileFormat) -> Bool {
        switch target {
        case .mp4: ["aac", "mp3", "alac", "ac3", "eac3"].contains(codec)
        case .mov: ["aac", "mp3", "alac", "ac3", "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be"].contains(codec)
        case .mkv: !codec.isEmpty
        case .webm: ["opus", "vorbis"].contains(codec)
        default: false
        }
    }

    /// `scale` filter that caps the height (0 = keep) and keeps both sides even for the encoders.
    static func scaleFilter(maxHeight: Int, sourceHeight: Int) -> String {
        if maxHeight > 0 && sourceHeight > maxHeight {
            return "scale=-2:\(maxHeight):flags=lanczos"
        }
        return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    static func videoArguments(from input: FileFormat, to target: FileFormat, info: MediaInfo, options: ConversionOptions) -> [String] {
        var args: [String] = []
        let needsResize = options.videoMaxHeight > 0 && info.displayHeight > options.videoMaxHeight
        let copyVideo = input != .gif && !needsResize && canCopyVideo(info.videoCodec, into: target)
        let copyAudio = info.hasAudio && canCopyAudio(info.audioCodec, into: target)

        args += ["-map", "0:v:0"]
        if info.hasAudio { args += ["-map", "0:a?"] }
        // ponytail: subtitle tracks are dropped; their codecs rarely survive a container change intact.

        if copyVideo {
            args += ["-c:v", "copy"]
            if [.mp4, .mov].contains(target) && info.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
        } else {
            let filter = scaleFilter(maxHeight: options.videoMaxHeight, sourceHeight: info.displayHeight)
            args += ["-vf", filter + ",format=yuv420p"]
            switch target {
            case .mp4, .mov, .mkv:
                let q = options.quality == .high ? 72 : options.quality == .balanced ? 62 : 48
                args += ["-c:v", "h264_videotoolbox", "-q:v", "\(q)", "-allow_sw", "1", "-profile:v", "high"]
                if target != .mkv { args += ["-tag:v", "avc1"] }
            case .webm:
                let crf = options.quality == .high ? 28 : options.quality == .balanced ? 33 : 40
                args += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(crf)", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-tile-columns", "2"]
            case .avi:
                let q = options.quality == .high ? 2 : options.quality == .balanced ? 4 : 7
                args += ["-c:v", "mpeg4", "-q:v", "\(q)", "-vtag", "XVID"]
            case .wmv:
                let q = options.quality == .high ? 2 : options.quality == .balanced ? 4 : 7
                args += ["-c:v", "wmv2", "-q:v", "\(q)"]
            default:
                break
            }
            if info.frameRate > 120 || info.frameRate == 0 { args += ["-r", "30"] }
        }

        if info.hasAudio {
            if copyAudio {
                args += ["-c:a", "copy"]
            } else {
                let bitrate = "\(options.audioBitrate)k"
                switch target {
                case .mp4, .mov, .mkv: args += ["-c:a", "aac_at", "-b:a", bitrate]
                case .webm: args += ["-c:a", "libopus", "-b:a", bitrate, "-ar", "48000"]
                case .avi: args += ["-c:a", "libmp3lame", "-b:a", bitrate]
                case .wmv: args += ["-c:a", "wmav2", "-b:a", bitrate]
                default: break
                }
            }
        }
        if [.mp4, .mov].contains(target) { args += ["-movflags", "+faststart+use_metadata_tags"] }
        return args
    }

    static func gifArguments(info: MediaInfo, options: ConversionOptions) -> [String] {
        let width = options.gifMaxWidth > 0 ? "'min(\(options.gifMaxWidth),iw)'" : "iw"
        let fps = max(1, min(options.gifFrameRate, 50))
        let filter = "[0:v:0]fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle[gif]"
        return ["-filter_complex", filter, "-map", "[gif]", "-loop", "0"]
    }

    /// Confirms the written file decodes and carries the expected streams.
    static func verify(_ url: URL, expectVideo: Bool, expectAudio: Bool) async throws {
        let info = try? await MediaInfo.probe(url)
        guard let info, (!expectVideo || info.hasVideo), (!expectAudio || info.hasAudio) else {
            throw WheelError("The converted file could not be verified.")
        }
    }
}
