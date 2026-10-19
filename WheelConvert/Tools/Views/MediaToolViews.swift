import AVKit
import SwiftUI

/// Video surface or waveform header shared by media tools.
struct MediaStage: View {
    @ObservedObject var preview: MediaPreview
    var isAudio: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(isAudio ? 0.05 : 0.9)
            if let error = preview.error {
                Text(error).foregroundStyle(.secondary).padding()
            } else if isAudio {
                if let wave = preview.waveform.first {
                    WaveformShape(samples: wave).fill(Color(nsColor: Brand.accent).opacity(0.85)).padding(20)
                        .accessibilityLabel("Waveform")
                } else {
                    ProgressView("Loading waveform…")
                }
            } else if let player = preview.player {
                PlayerSurface(player: player)
            } else {
                ProgressView("Loading video…").colorScheme(.dark)
            }
        }
    }
}

// MARK: - Trim

struct TrimView: View {
    let urls: [URL]
    let isAudio: Bool
    let close: () -> Void
    let apply: (ToolOptions.Trim) -> Void
    @StateObject private var preview: MediaPreview
    @State private var range: ClosedRange<Double> = 0...1
    @State private var autoSilence = false
    @State private var threshold = -45.0
    @State private var detecting = false
    @State private var shortest: Double?

    init(urls: [URL], isAudio: Bool, close: @escaping () -> Void, apply: @escaping (ToolOptions.Trim) -> Void) {
        self.urls = urls
        self.isAudio = isAudio
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: urls[0]))
    }

    private var duration: Double { shortest ?? preview.duration }

    var body: some View {
        ToolFrame(primary: urls.count == 1 ? "Save Trimmed Copy" : "Trim \(urls.count) Files", canApply: duration > 0 && range.upperBound - range.lowerBound >= 0.05,
                  note: urls.count > 1 ? "Range applies to all files, up to the shortest file’s duration." : "Keeps \(TimeText.format(range.upperBound - range.lowerBound)).",
                  cancel: { preview.stop(); close() }, apply: {
                      preview.stop()
                      apply(.init(start: range.lowerBound, end: range.upperBound, autoTrimSilence: autoSilence, silenceThreshold: threshold))
                  }) {
            VStack(spacing: 10) {
                MediaStage(preview: preview, isAudio: isAudio)
                VStack(spacing: 8) {
                    Timeline(duration: duration, thumbnails: preview.thumbnails, waveform: isAudio ? (preview.waveform.first ?? []) : [],
                             playhead: $preview.time, range: $range, onScrub: { preview.seek($0) })
                    TransportBar(preview: preview, range: range, showsFrameStep: !isAudio)
                    HStack {
                        TimeField(label: "Start", seconds: Binding(get: { range.lowerBound }, set: { range = min($0, range.upperBound - 0.05)...range.upperBound }), range: 0...max(0.05, duration))
                        TimeField(label: "End", seconds: Binding(get: { range.upperBound }, set: { range = range.lowerBound...max($0, range.lowerBound + 0.05) }), range: 0...max(0.05, duration))
                        Button("Set Start to Playhead") { range = min(preview.time, range.upperBound - 0.05)...range.upperBound }
                        Button("Set End to Playhead") { range = range.lowerBound...max(preview.time, range.lowerBound + 0.05) }
                        Spacer()
                    }
                    if isAudio {
                        HStack {
                            Toggle("Trim silent ends automatically", isOn: $autoSilence)
                            if autoSilence {
                                LabeledSlider(title: "Silence threshold", value: $threshold, range: -80 ... -10, step: 1, format: { "\(Int($0)) dB" }, neutral: -45).frame(width: 300)
                                Button("Preview") { detectSilence() }.disabled(detecting)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .task {
            await preview.load(video: !isAudio, thumbnails: isAudio ? 0 : 14, waveformBins: isAudio ? 900 : 0)
            if urls.count > 1 {
                var minimum = preview.duration
                for url in urls.dropFirst() { if let info = try? await MediaInfo.probe(url) { minimum = min(minimum, info.duration) } }
                shortest = minimum
            }
            range = 0...max(0.05, duration)
        }
        .onDisappear { preview.stop() }
    }

    private func detectSilence() {
        detecting = true
        Task {
            if let ends = try? await MediaTools.silentEnds(urls[0], threshold: threshold, duration: preview.duration) { range = ends.start...ends.end }
            detecting = false
        }
    }
}

// MARK: - Crop video

struct CropVideoView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.VideoCrop) -> Void
    @StateObject private var preview: MediaPreview
    @State private var frame: CGImage?
    @State private var rects: [CGRect] = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)]
    @State private var selection: Int? = 0
    @State private var aspect: Double? = nil
    @State private var frameTime = 0.0

    init(url: URL, close: @escaping () -> Void, apply: @escaping (ToolOptions.VideoCrop) -> Void) {
        self.url = url
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: url))
    }

    private var rect: CGRect { rects.first ?? CGRect(x: 0, y: 0, width: 1, height: 1) }

    var body: some View {
        ToolFrame(primary: "Save Cropped Video", canApply: rect.width > 0.01 && rect.height > 0.01, note: "The original audio is kept.", cancel: { preview.stop(); close() }, apply: {
            preview.stop()
            apply(.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        }) {
            VStack(spacing: 10) {
                if let frame {
                    RectEditor(image: frame, rects: $rects, selection: $selection, single: true, aspect: aspect, dimOutside: true).padding(12)
                        .accessibilityLabel("Crop selection. Drag to reposition.")
                } else {
                    ProgressView("Loading video…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Text("Preview frame")
                    Slider(value: $frameTime, in: 0...max(0.01, preview.duration)).accessibilityLabel("Preview frame time")
                    Picker("Aspect", selection: Binding(get: { aspect ?? 0 }, set: { aspect = $0 == 0 ? nil : $0 })) {
                        Text("Free").tag(0.0); Text("Square").tag(1.0); Text("16:9").tag(16.0 / 9); Text("9:16").tag(9.0 / 16); Text("4:3").tag(4.0 / 3); Text("4:5").tag(0.8)
                    }
                    .frame(width: 150)
                    if let info = preview.info {
                        Text("\(Int(rect.width * Double(info.displayWidth)) / 2 * 2) × \(Int(rect.height * Double(info.displayHeight)) / 2 * 2) px").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .task {
            await preview.load(video: true, playback: false)
            frame = try? await MediaTools.frame(url, at: 0)
        }
        .task(id: frameTime) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, preview.info != nil else { return }
            if let image = try? await MediaTools.frame(url, at: frameTime) { frame = image }
        }
    }
}

// MARK: - Speed

struct SpeedView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Speed) -> Void
    @StateObject private var preview: MediaPreview
    @State private var options = ToolOptions.Speed()

    init(url: URL, close: @escaping () -> Void, apply: @escaping (ToolOptions.Speed) -> Void) {
        self.url = url
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: url))
    }

    var body: some View {
        ToolFrame(primary: "Save at \(label)", canApply: options.factor != 1, note: preview.duration > 0 ? "New length: \(TimeText.format(preview.duration / options.factor, millis: false))" : nil,
                  cancel: { preview.stop(); close() }, apply: { preview.stop(); apply(options) }) {
            VStack(spacing: 12) {
                MediaStage(preview: preview, isAudio: false).frame(minHeight: 200)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4], id: \.self) { value in
                            if options.factor == value {
                                Button(Self.format(value)) { options.factor = value }.buttonStyle(.borderedProminent)
                            } else {
                                Button(Self.format(value)) { options.factor = value }.buttonStyle(.bordered)
                            }
                        }
                    }
                    LabeledSlider(title: "Speed", value: $options.factor, range: 0.25...4, step: 0.05, format: Self.format, neutral: 1)
                    Toggle("Preserve audio pitch", isOn: $options.preservePitch)
                    HStack {
                        Button(preview.isPlaying ? "Pause Preview" : "Play Preview") {
                            if preview.isPlaying { preview.player?.pause() } else { preview.player?.rate = Float(options.factor) }
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        Text("Preview plays at the chosen speed.").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
            }
        }
        .task { await preview.load(video: true) }
        .onChange(of: options.factor) { value in if preview.isPlaying { preview.player?.rate = Float(value) } }
        .onChange(of: options.preservePitch) { value in preview.player?.currentItem?.audioTimePitchAlgorithm = value ? .spectral : .varispeed }
    }

    private var label: String { Self.format(options.factor) }
    static func format(_ value: Double) -> String { value == value.rounded() ? "\(Int(value))×" : String(format: "%g×", (value * 100).rounded() / 100) }
}

// MARK: - Frames

struct SnapshotsView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Snapshots) -> Void
    @StateObject private var preview: MediaPreview
    @State private var times: [Double] = []

    init(url: URL, close: @escaping () -> Void, apply: @escaping (ToolOptions.Snapshots) -> Void) {
        self.url = url
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: url))
    }

    var body: some View {
        ToolFrame(primary: times.count <= 1 ? "Save Frame" : "Save \(times.count) Frames", canApply: !times.isEmpty, note: "Full-resolution PNGs.",
                  cancel: { preview.stop(); close() }, apply: { preview.stop(); apply(.init(times: times)) }) {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    MediaStage(preview: preview, isAudio: false)
                    Timeline(duration: preview.duration, thumbnails: preview.thumbnails, playhead: $preview.time, markers: times, onScrub: { preview.seek($0) })
                        .padding(.horizontal, 12)
                    HStack {
                        TransportBar(preview: preview)
                        Button("Add Frame") { add(preview.time) }.keyboardShortcut(.return, modifiers: [])
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
                VStack(alignment: .leading) {
                    Text("Frames").font(.headline)
                    if times.isEmpty { Text("Add a frame to save.").foregroundStyle(.secondary) }
                    List {
                        ForEach(times, id: \.self) { time in
                            HStack {
                                Button(TimeText.format(time)) { preview.seek(time) }.buttonStyle(.link).help("Preview frame at \(TimeText.format(time))")
                                Spacer()
                                Button { times.removeAll { $0 == time } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                    .accessibilityLabel("Remove frame at \(TimeText.format(time))")
                            }
                        }
                    }
                }
                .padding(12)
                .frame(width: 220)
            }
        }
        .task { await preview.load(video: true, thumbnails: 14) }
    }

    private func add(_ time: Double) {
        // The playhead can rest at the very end, where there is no frame left to grab.
        let lastFrame = max(0, preview.duration - 1 / max(1, preview.info?.frameRate ?? 30))
        let rounded = (min(time, lastFrame) * 1000).rounded() / 1000
        if !times.contains(where: { abs($0 - rounded) < 0.001 }) { times.append(rounded); times.sort() }
    }
}

// MARK: - Split

struct SplitVideoView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Split) -> Void
    @StateObject private var preview: MediaPreview
    @State private var points: [Double] = []
    @State private var removed: Set<Int> = []
    @State private var parts = 2

    init(url: URL, close: @escaping () -> Void, apply: @escaping (ToolOptions.Split) -> Void) {
        self.url = url
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: url))
    }

    private var clips: [(Double, Double)] { MediaTools.clips(points: points, duration: preview.duration) }

    var body: some View {
        ToolFrame(primary: !removed.isEmpty ? "Export One Video" : clips.count >= 2 ? "Export \(clips.count) Clips" : "Export Clips", canApply: clips.count >= 2 && removed.count < clips.count,
                  note: clips.count < 2 ? "Add split points at the playhead or split evenly." : removed.isEmpty ? "Every clip is saved in one folder. Remove clips to join the rest instead." : "Removed clips are cut; the rest are joined.",
                  cancel: { preview.stop(); close() }, apply: {
                      preview.stop()
                      apply(.init(points: points, removed: Array(removed), export: removed.isEmpty ? .clips : .merged))
                  }) {
            VStack(spacing: 8) {
                MediaStage(preview: preview, isAudio: false)
                Timeline(duration: preview.duration, thumbnails: preview.thumbnails, playhead: $preview.time, markers: points,
                         spans: clips.enumerated().filter { removed.contains($0.offset) }.map { $0.element.0...$0.element.1 }, spanColor: .red,
                         onScrub: { preview.seek($0) })
                    .padding(.horizontal, 12)
                HStack {
                    TransportBar(preview: preview)
                    Button("Split at Playhead") { addPoint(preview.time) }.keyboardShortcut("b", modifiers: .command)
                    Stepper("Equal parts: \(parts)", value: $parts, in: 2...50)
                    Button("Split Evenly") {
                        points = (1..<parts).map { preview.duration * Double($0) / Double(parts) }
                        removed = []
                    }
                    Button("Clear") { points = []; removed = [] }.disabled(points.isEmpty)
                }
                .padding(.horizontal, 12)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                            Toggle(isOn: Binding(get: { !removed.contains(index) }, set: { keep in if keep { removed.remove(index) } else { removed.insert(index) } })) {
                                Text("Clip \(index + 1) · \(TimeText.format(clip.1 - clip.0, millis: false))")
                            }
                            .toggleStyle(.button)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .task { await preview.load(video: true, thumbnails: 14) }
    }

    private func addPoint(_ time: Double) {
        guard time > 0.05, time < preview.duration - 0.05, !points.contains(where: { abs($0 - time) < 0.05 }) else { return }
        points.append(time)
        points.sort()
        removed = []
    }
}

// MARK: - Redact video

struct RedactVideoView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Redact) -> Void
    @StateObject private var preview: MediaPreview
    @State private var frame: CGImage?
    @State private var rects: [CGRect] = []
    @State private var ranges: [ClosedRange<Double>?] = []
    @State private var selection: Int?
    @State private var style: ToolOptions.Redact.Style = .solid

    init(url: URL, close: @escaping () -> Void, apply: @escaping (ToolOptions.Redact) -> Void) {
        self.url = url
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: url))
    }

    var body: some View {
        ToolFrame(primary: "Save Redacted Copy", canApply: !rects.isEmpty, note: rects.isEmpty ? "Drag on the video to cover an area." : style == .blur ? "Blur softens details. Use Solid for sensitive information." : nil,
                  cancel: { preview.stop(); close() }, apply: {
                      preview.stop()
                      let regions = rects.indices.map { i -> ToolOptions.Redaction in
                          let r = rects[i]
                          let range = i < ranges.count ? ranges[i] : nil
                          return .init(x: r.minX, y: r.minY, width: r.width, height: r.height, start: range?.lowerBound, end: range?.upperBound)
                      }
                      apply(.init(regions: regions, style: style))
                  }) {
            VStack(spacing: 8) {
                if let frame {
                    RectEditor(image: frame, rects: $rects, selection: $selection, tint: .black).padding(12)
                        .accessibilityLabel("Redaction preview. Draw rectangles to cover areas.")
                        .onChange(of: rects.count) { count in
                            while ranges.count < count { ranges.append(nil) }
                            if ranges.count > count { ranges.removeLast(ranges.count - count) }
                        }
                        .background(DeleteKeyCatcher { delete() })
                } else {
                    ProgressView("Loading video…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Timeline(duration: preview.duration, thumbnails: preview.thumbnails, playhead: $preview.time,
                         range: selectedRange, spans: ranges.compactMap { $0 }, spanColor: .black, onScrub: { preview.seek($0) })
                    .padding(.horizontal, 12)
                HStack {
                    Text(TimeText.format(preview.time)).monospacedDigit().foregroundStyle(.secondary)
                    if let selection {
                        Button(ranges[safe: selection].flatMap { $0 } == nil ? "Limit to a Time Range" : "Show for Entire Video") {
                            if ranges[selection] == nil { ranges[selection] = max(0, preview.time)...min(preview.duration, preview.time + 2) } else { ranges[selection] = nil }
                        }
                        Button("Delete Redaction") { delete() }
                    }
                    Spacer()
                    Picker("Style", selection: $style) { ForEach(ToolOptions.Redact.Style.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 150)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .task {
            await preview.load(video: true, thumbnails: 14, playback: false)
            frame = try? await MediaTools.frame(url, at: 0)
        }
        .task(id: Int(preview.time * 4)) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, preview.info != nil else { return }
            if let image = try? await MediaTools.frame(url, at: preview.time) { frame = image }
        }
    }

    private var selectedRange: Binding<ClosedRange<Double>>? {
        guard let selection, selection < ranges.count, ranges[selection] != nil else { return nil }
        return Binding(get: { ranges[selection] ?? 0...1 }, set: { ranges[selection] = $0 })
    }

    private func delete() {
        guard let s = selection, s < rects.count else { return }
        rects.remove(at: s)
        if s < ranges.count { ranges.remove(at: s) }
        selection = nil
    }
}

// MARK: - Normalize

struct NormalizeView: View {
    let urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Normalize) -> Void
    @State private var options = ToolOptions.Normalize()
    @State private var measured: String?

    var body: some View {
        ToolFrame(primary: urls.count == 1 ? "Save Normalized Copy" : "Normalize \(urls.count) Files", note: urls.count > 1 ? "Settings apply to every selected file." : nil,
                  cancel: close, apply: { apply(options) }) {
            Form {
                Picker("Preset", selection: Binding(get: { options.targetLoudness }, set: { options.targetLoudness = $0 })) {
                    Text("Podcast & voice (−16 LUFS)").tag(-16.0)
                    Text("Streaming music (−14 LUFS)").tag(-14.0)
                    Text("Broadcast (−23 LUFS)").tag(-23.0)
                    if ![-16.0, -14, -23].contains(options.targetLoudness) { Text("Custom").tag(options.targetLoudness) }
                }
                LabeledSlider(title: "Target loudness", value: $options.targetLoudness, range: -40 ... -5, step: 0.5, format: { String(format: "%.1f LUFS", $0) }, neutral: -16, valueWidth: 84)
                LabeledSlider(title: "Loudness range", value: $options.loudnessRange, range: 1...50, step: 0.5, format: { String(format: "%.1f LU", $0) }, neutral: 11, valueWidth: 84)
                LabeledSlider(title: "True peak", value: $options.truePeak, range: -9...0, step: 0.1, format: { String(format: "%.1f dBTP", $0) }, neutral: -1.5, valueWidth: 84)
                Text("−16 LUFS is a balanced default for spoken audio and music. The true peak limit helps prevent clipping after encoding.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Current loudness", value: measured ?? "Measuring…")
            }
            .formStyle(.grouped)
        }
        .task {
            guard let log = try? await FFmpeg.analyze(["-i", urls[0].path, "-map", "0:a:0", "-af", "loudnorm=print_format=json", "-f", "null", "-"]),
                  let open = log.lastIndex(of: "{"), let close = log.lastIndex(of: "}"),
                  let json = try? JSONSerialization.jsonObject(with: Data(log[open...close].utf8)) as? [String: String],
                  let input = json["input_i"], let peak = json["input_tp"] else { measured = "Unavailable"; return }
            measured = "\(input) LUFS, peak \(peak) dBTP"
        }
    }
}

// MARK: - Visualizer

struct VisualizerView: View {
    static let sampleWave: [Float] = (0..<80).map { (i: Int) -> Float in
        let x = Double(i)
        return Float(0.25 + 0.7 * abs(sin(x * 0.37)) * abs(cos(x * 0.11)))
    }
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Visualizer) -> Void
    @State private var options = ToolOptions.Visualizer()
    @State private var color = Color(hex: "6B5CFF")
    @State private var background = Color(hex: "0B0B12")

    var body: some View {
        ToolFrame(primary: "Create Visualization", canApply: options.style == .waveform || options.imagePath != nil, note: "Saves an MP4 next to the audio.", cancel: close, apply: { apply(options) }) {
            HStack(spacing: 0) {
                ZStack {
                    background
                    if options.style == .staticImage, let path = options.imagePath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        WaveformShape(samples: Self.sampleWave)
                            .fill(color).frame(height: 120).padding(.horizontal, 20)
                    }
                }
                .aspectRatio(CGFloat(options.canvas.size.0) / CGFloat(options.canvas.size.1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Waveform visualization preview")
                Divider()
                Form {
                    Picker("Visualization style", selection: $options.style) {
                        Text("Waveform").tag(ToolOptions.Visualizer.Style.waveform)
                        Text("Still image").tag(ToolOptions.Visualizer.Style.staticImage)
                    }
                    .pickerStyle(.radioGroup)
                    Picker("Canvas", selection: $options.canvas) { ForEach(ToolOptions.Visualizer.Canvas.allCases) { Text($0.title).tag($0) } }
                    if options.style == .waveform {
                        ColorPicker("Waveform", selection: $color, supportsOpacity: false).onChange(of: color) { options.color = $0.hexString }
                    } else {
                        Button(options.imagePath == nil ? "Choose a Static Image…" : "Change Image…") { if let url = chooseImage() { options.imagePath = url.path } }
                    }
                    ColorPicker("Background", selection: $background, supportsOpacity: false).onChange(of: background) { options.background = $0.hexString }
                }
                .formStyle(.grouped)
                .frame(width: 280)
            }
        }
    }
}

// MARK: - Channels

struct ChannelsView: View {
    let urls: [URL]
    let close: () -> Void
    let apply: (ToolOptions.Channels) -> Void
    @StateObject private var preview: MediaPreview
    @State private var options = ToolOptions.Channels()

    init(urls: [URL], close: @escaping () -> Void, apply: @escaping (ToolOptions.Channels) -> Void) {
        self.urls = urls
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: urls[0]))
    }

    var body: some View {
        ToolFrame(primary: options.channels == 1 ? "Save Mono Copy" : "Save Stereo Copy", canApply: preview.info?.hasAudio ?? true,
                  note: preview.info.map { "Source: \($0.audioChannels == 1 ? "mono" : "\($0.audioChannels) channels")" }, cancel: { preview.stop(); close() }, apply: { preview.stop(); apply(options) }) {
            Form {
                Picker("Output", selection: $options.channels) {
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Left volume", value: Binding(get: { options.leftVolume * 100 }, set: { options.leftVolume = $0 / 100 }), range: 0...200, step: 1, format: { "\(Int($0))%" }, neutral: 100)
                waveform(0)
                LabeledSlider(title: "Right volume", value: Binding(get: { options.rightVolume * 100 }, set: { options.rightVolume = $0 / 100 }), range: 0...200, step: 1, format: { "\(Int($0))%" }, neutral: 100)
                waveform(1)
                HStack {
                    Button(preview.isPlaying ? "Stop Preview" : "Play Original") { preview.toggle() }
                    Text(TimeText.format(preview.time)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task { await preview.load(video: false, waveformBins: 500, stereo: true) }
        .onChange(of: options) { _ in applyPreviewVolume() }
    }

    @ViewBuilder private func waveform(_ channel: Int) -> some View {
        if channel < preview.waveform.count {
            WaveformShape(samples: preview.waveform[channel].map { $0 * Float(channel == 0 ? options.leftVolume : options.rightVolume) / 2 })
                .fill(Color(nsColor: Brand.accent).opacity(0.8)).frame(height: 44)
                .accessibilityLabel("\(channel == 0 ? "Left" : "Right") channel waveform")
        }
    }

    private func applyPreviewVolume() {
        preview.player?.volume = Float(max(options.leftVolume, options.rightVolume) / 2)
    }
}

// MARK: - Bleep

struct BleepView: View {
    let url: URL
    let close: () -> Void
    let apply: (ToolOptions.Bleep) -> Void
    @StateObject private var preview: MediaPreview
    @State private var ranges: [ClosedRange<Double>] = []
    @State private var selection: Int?

    init(url: URL, close: @escaping () -> Void, apply: @escaping (ToolOptions.Bleep) -> Void) {
        self.url = url
        self.close = close
        self.apply = apply
        _preview = StateObject(wrappedValue: MediaPreview(url: url))
    }

    var body: some View {
        ToolFrame(primary: "Save Bleeped Copy", canApply: !ranges.isEmpty, note: "Each range is replaced with a 1 kHz tone.", cancel: { preview.stop(); close() }, apply: {
            preview.stop()
            apply(.init(ranges: ranges.map { [$0.lowerBound, $0.upperBound] }))
        }) {
            VStack(spacing: 10) {
                Timeline(duration: preview.duration, waveform: preview.waveform.first ?? [], playhead: $preview.time,
                         range: selectedBinding, spans: ranges, spanColor: .red, onScrub: { preview.seek($0) }, height: 200)
                    .padding(.horizontal, 16).padding(.top, 16)
                HStack {
                    TransportBar(preview: preview, showsFrameStep: false)
                    Button("Add Bleep at Playhead") {
                        let start = preview.time, end = min(preview.duration, preview.time + 0.6)
                        guard end > start else { return }
                        ranges.append(start...end)
                        selection = ranges.count - 1
                    }
                    Button("Bleep Entire Audio") { ranges = [0...preview.duration]; selection = 0 }
                    Button("Delete") { if let s = selection { ranges.remove(at: s); selection = nil } }.disabled(selection == nil)
                }
                .padding(.horizontal, 16)
                List(selection: $selection) {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                        Text("Bleep \(index + 1): \(TimeText.format(range.lowerBound)) – \(TimeText.format(range.upperBound))").tag(index)
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if ranges.isEmpty {
                        Text("Move the playhead to the word, then click Add Bleep at Playhead. Drag the selected range’s edges to adjust it.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .task { await preview.load(video: false, waveformBins: 1200) }
    }

    private var selectedBinding: Binding<ClosedRange<Double>>? {
        guard let selection, selection < ranges.count else { return nil }
        return Binding(get: { ranges[min(selection, ranges.count - 1)] }, set: { if selection < ranges.count { ranges[selection] = $0 } })
    }
}
