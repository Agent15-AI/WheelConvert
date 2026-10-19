import AVKit
import AppKit
import SwiftUI

// MARK: - Layout

/// Standard tool window body: content, then a footer with Cancel and the primary action.
struct ToolFrame<Content: View>: View {
    let primary: String
    var canApply = true
    var note: String?
    /// Restores the tool's default settings and forgets the remembered ones (see `ToolMemory`).
    var reset: (() -> Void)?
    let cancel: () -> Void
    let apply: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: 10) {
                if let reset {
                    Button("Reset", action: reset).help("Restore this tool’s default settings")
                }
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(primary, action: apply).keyboardShortcut(.defaultAction).disabled(!canApply)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

/// Slider with a title and value read-out; double-click the title to reset.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var neutral: Double = 0
    var valueWidth: CGFloat = 48

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 104, alignment: .leading).lineLimit(1)
                .onTapGesture(count: 2) { value = neutral }
                .help("Double-click to reset")
            if let step {
                Slider(value: $value, in: range, step: step).accessibilityLabel(title)
            } else {
                Slider(value: $value, in: range).accessibilityLabel(title)
            }
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize().frame(minWidth: valueWidth, alignment: .trailing)
        }
        .font(.callout)
    }
}

// MARK: - Time

enum TimeText {
    static func format(_ seconds: Double, millis: Bool = true) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, seconds)
        let h = Int(total) / 3600, m = Int(total) / 60 % 60, s = total.truncatingRemainder(dividingBy: 60)
        let sec = millis ? String(format: "%06.3f", s) : String(format: "%02d", Int(s))
        return h > 0 ? String(format: "%d:%02d:", h, m) + sec : String(format: "%d:", m) + sec
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

/// Editable "m:ss.mmm" field.
struct TimeField: View {
    let label: String
    @Binding var seconds: Double
    var range: ClosedRange<Double>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .monospacedDigit()
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel("\(label) time in seconds")
        }
        .onAppear { text = TimeText.format(seconds) }
        .onChange(of: seconds) { value in if !focused { text = TimeText.format(value) } }
        .onChange(of: focused) { isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        if let value = TimeText.parse(text) { seconds = min(max(value, range.lowerBound), range.upperBound) }
        text = TimeText.format(seconds)
    }
}

// MARK: - Playback

/// AVPlayerView without controls; the tool drives playback.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Loads media for previewing. Files AVFoundation can't play are streamed through `PreviewStream`,
/// which encodes only the part around the playhead, so even hour-long videos start right away.
@MainActor
final class MediaPreview: ObservableObject {
    @Published var info: MediaInfo?
    @Published var player: AVPlayer?
    @Published var time: Double = 0
    @Published var isPlaying = false
    @Published var thumbnails: [CGImage] = []
    @Published var waveform: [[Float]] = []
    /// A still of the scrub position, shown while a streamed preview fetches that part.
    @Published var scrubFrame: CGImage?
    @Published var error: String?
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var stopAt: Double?
    private var extras: Task<Void, Never>?
    private var scrubTask: Task<Void, Never>?
    private var seekGeneration = 0
    nonisolated(unsafe) private var previewFile: URL?
    nonisolated(unsafe) private var stream: PreviewStream?
    let url: URL

    init(url: URL) { self.url = url }

    deinit {
        // Closing the window without Cancel still removes preview files; the player stops as it's released.
        stream?.stop()
        if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
    }

    var duration: Double { info?.duration ?? 0 }

    /// Returns once the file's facts and (when `playback`) a player are ready; thumbnails and the
    /// waveform keep loading afterwards.
    /// - Parameter playback: false for tools that only show still frames; skips building a player.
    func load(video: Bool, thumbnails count: Int = 0, waveformBins: Int = 0, stereo: Bool = false, playback: Bool = true) async {
        do {
            let info = try await MediaInfo.probe(url)
            self.info = info
            loadExtras(info, thumbnails: count, waveformBins: waveformBins, stereo: stereo)
            guard playback else { return }
            let asset = AVURLAsset(url: url)
            var playable = (try? await asset.load(.isPlayable)) ?? false
            if playable, video, info.hasVideo { playable = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty }
            var source = url
            if !playable {
                let stream = PreviewStream(source: url, duration: info.duration, video: video && info.hasVideo)
                do {
                    source = try await stream.start()
                    self.stream = stream
                } catch {
                    stream.stop()
                    source = try await MediaTools.previewCopy(url, video: video && info.hasVideo)
                    previewFile = source
                }
            }
            let player = AVPlayer(url: source)
            player.actionAtItemEnd = .pause
            // Don't ask the encoder for minutes ahead. (Turning off automaticallyWaitsToMinimizeStalling
            // stalls HLS at time zero, so it stays on.)
            if stream != nil { player.currentItem?.preferredForwardBufferDuration = 16 }
            statusObserver = player.currentItem?.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in self?.error = "This file can’t be previewed." }
            }
            self.player = player
            // Weak captures: the player retains this block, so a strong one would keep it (and its audio) alive.
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self, weak player] time in
                MainActor.assumeIsolated {
                    guard let self, let player else { return }
                    self.time = time.seconds
                    self.isPlaying = player.rate != 0
                    if let stop = self.stopAt, time.seconds >= stop { player.pause(); self.stopAt = nil }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadExtras(_ info: MediaInfo, thumbnails count: Int, waveformBins: Int, stereo: Bool) {
        let url = url
        extras = Task { [weak self] in
            if count > 0, info.hasVideo {
                let images = (try? await MediaTools.thumbnails(url, count: count, duration: info.duration)) ?? []
                self?.thumbnails = images
            }
            if waveformBins > 0, info.hasAudio {
                let wave = (try? await MediaTools.waveform(url, bins: waveformBins, stereo: stereo)) ?? []
                self?.waveform = wave
            }
        }
    }

    func seek(_ seconds: Double) {
        time = min(max(0, seconds), duration)
        seekGeneration += 1
        let generation = seekGeneration
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.scrubTask?.cancel()
                self.scrubFrame = nil
            }
        }
        guard stream != nil, info?.hasVideo == true else { return }
        // A streamed preview may need a moment to encode a far-off spot; a still frame bridges it.
        scrubTask?.cancel()
        let url = url, time = time
        scrubTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, let image = try? await MediaTools.frame(url, at: time), !Task.isCancelled else { return }
            guard let self, self.seekGeneration == generation else { return }
            self.scrubFrame = image
        }
    }

    func toggle(range: ClosedRange<Double>? = nil) {
        guard let player else { return }
        if player.rate != 0 { player.pause(); isPlaying = false; return }
        if let range {
            if time < range.lowerBound || time >= range.upperBound - 0.02 { seek(range.lowerBound) }
            stopAt = range.upperBound
        }
        player.play()
        isPlaying = true
    }

    func step(frames: Int) {
        let fps = max(1, info?.frameRate ?? 30)
        player?.pause()
        seek(time + Double(frames) / fps)
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        extras?.cancel()
        scrubTask?.cancel()
        stream?.stop()
        stream = nil
        if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
    }
}

// MARK: - Timeline

/// Thumbnail strip or waveform with a playhead, an optional selected range, and markers.
struct Timeline: View {
    let duration: Double
    var thumbnails: [CGImage] = []
    var waveform: [Float] = []
    @Binding var playhead: Double
    var range: Binding<ClosedRange<Double>>? = nil
    var markers: [Double] = []
    var spans: [ClosedRange<Double>] = []
    var spanColor: Color = .orange
    var onScrub: (Double) -> Void = { _ in }
    var height: CGFloat = 64

    @State private var dragging: Handle?
    enum Handle { case start, end, playhead }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let x = { (t: Double) in CGFloat(duration > 0 ? t / duration : 0) * width }
            let t = { (x: CGFloat) in min(max(0, Double(x / width) * duration), duration) }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                if !thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(thumbnails.count), height: height).clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if !waveform.isEmpty {
                    WaveformShape(samples: waveform).fill(Color(nsColor: Brand.accent).opacity(0.75))
                }
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    Rectangle().fill(spanColor.opacity(0.35))
                        .frame(width: max(2, x(span.upperBound) - x(span.lowerBound)), height: height)
                        .offset(x: x(span.lowerBound))
                }
                if let range {
                    let r = range.wrappedValue
                    // Dim the parts that will be removed.
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, x(r.lowerBound)), height: height)
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, width - x(r.upperBound)), height: height).offset(x: x(r.upperBound))
                    RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Brand.accent), lineWidth: 3)
                        .frame(width: max(6, x(r.upperBound) - x(r.lowerBound)), height: height).offset(x: x(r.lowerBound))
                    handle.offset(x: x(r.lowerBound) - 5)
                    handle.offset(x: x(r.upperBound) - 5)
                }
                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    Rectangle().fill(Color.yellow).frame(width: 2, height: height).offset(x: x(marker) - 1)
                }
                Rectangle().fill(Color.white).frame(width: 2, height: height + 8).offset(x: x(playhead) - 1, y: -4)
                    .shadow(radius: 1)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let time = t(value.location.x)
                if dragging == nil {
                    if let range {
                        let r = range.wrappedValue
                        if abs(value.startLocation.x - x(r.lowerBound)) < 10 { dragging = .start }
                        else if abs(value.startLocation.x - x(r.upperBound)) < 10 { dragging = .end }
                        else { dragging = .playhead }
                    } else {
                        dragging = .playhead
                    }
                }
                switch dragging {
                case .start: if let range { range.wrappedValue = min(time, range.wrappedValue.upperBound - 0.05)...range.wrappedValue.upperBound }
                case .end: if let range { range.wrappedValue = range.wrappedValue.lowerBound...max(time, range.wrappedValue.lowerBound + 0.05) }
                default: break
                }
                playhead = time
                onScrub(time)
            }.onEnded { _ in dragging = nil })
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue(TimeText.format(playhead))
            .accessibilityAdjustableAction { direction in
                let delta = duration / 100
                playhead = min(max(0, playhead + (direction == .increment ? delta : -delta)), duration)
                onScrub(playhead)
            }
        }
        .frame(height: height)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: Brand.accent))
            .frame(width: 10, height: height)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: height * 0.4))
    }
}

struct WaveformShape: Shape {
    let samples: [Float]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let step = rect.width / CGFloat(samples.count)
        for (i, value) in samples.enumerated() {
            let h = max(1, CGFloat(value) * rect.height * 0.92)
            path.addRect(CGRect(x: CGFloat(i) * step, y: rect.midY - h / 2, width: max(1, step * 0.8), height: h))
        }
        return path
    }
}

/// Play/pause, frame stepping and the current time.
struct TransportBar: View {
    @ObservedObject var preview: MediaPreview
    var range: ClosedRange<Double>? = nil
    var showsFrameStep = true

    var body: some View {
        HStack(spacing: 10) {
            Button { preview.toggle(range: range) } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(preview.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(preview.isPlaying ? "Pause" : "Play")
            if showsFrameStep {
                Button { preview.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame").accessibilityLabel("Previous frame")
                Button { preview.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame").accessibilityLabel("Next frame")
            }
            Text("\(TimeText.format(preview.time)) / \(TimeText.format(preview.duration))").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Rectangles over a picture

/// Edits normalized rectangles drawn over an image (crop, redaction).
struct RectEditor: View {
    let image: CGImage
    @Binding var rects: [CGRect]
    @Binding var selection: Int?
    var single = false
    var aspect: Double? = nil
    var allowsCreate = true
    var tint: Color = .white
    var dimOutside = false

    @State private var drag: (index: Int, mode: Mode, start: CGRect)?
    enum Mode { case move, create, resize(Corner) }
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let imageSize = CGSize(width: image.width, height: image.height)
            let fit = min(geo.size.width / imageSize.width, geo.size.height / imageSize.height)
            let shown = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            let toView = { (r: CGRect) in CGRect(x: origin.x + r.minX * shown.width, y: origin.y + r.minY * shown.height, width: r.width * shown.width, height: r.height * shown.height) }
            let toUnit = { (p: CGPoint) in CGPoint(x: min(max(0, (p.x - origin.x) / shown.width), 1), y: min(max(0, (p.y - origin.y) / shown.height), 1)) }
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: shown.width, height: shown.height).offset(x: origin.x, y: origin.y)
                if dimOutside, let first = rects.first {
                    Path { p in
                        p.addRect(CGRect(origin: origin, size: shown))
                        p.addRect(toView(first))
                    }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                }
                ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                    let view = toView(rect)
                    Rectangle()
                        .fill(dimOutside ? Color.clear : tint.opacity(selection == index ? 0.35 : 0.22))
                        .overlay(Rectangle().stroke(selection == index ? Color(nsColor: Brand.accent) : tint, lineWidth: selection == index ? 2 : 1))
                        .frame(width: view.width, height: view.height)
                        .offset(x: view.minX, y: view.minY)
                        .accessibilityElement()
                        .accessibilityLabel("Rectangle \(index + 1)")
                    if selection == index {
                        ForEach([Corner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                            Circle().fill(Color.white).overlay(Circle().stroke(Color(nsColor: Brand.accent), lineWidth: 2))
                                .frame(width: 12, height: 12)
                                .offset(x: (corner == .topLeft || corner == .bottomLeft ? view.minX : view.maxX) - 6,
                                        y: (corner == .topLeft || corner == .topRight ? view.minY : view.maxY) - 6)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local).onChanged { value in
                let p0 = toUnit(value.startLocation), p1 = toUnit(value.location)
                if drag == nil {
                    // Corner handle of the selection, then any rectangle body, else draw a new one.
                    if let s = selection, s < rects.count {
                        let v = toView(rects[s])
                        let corners: [(Corner, CGPoint)] = [(.topLeft, CGPoint(x: v.minX, y: v.minY)), (.topRight, CGPoint(x: v.maxX, y: v.minY)),
                                                            (.bottomLeft, CGPoint(x: v.minX, y: v.maxY)), (.bottomRight, CGPoint(x: v.maxX, y: v.maxY))]
                        if let hit = corners.first(where: { hypot($0.1.x - value.startLocation.x, $0.1.y - value.startLocation.y) < 12 }) {
                            drag = (s, .resize(hit.0), rects[s])
                        }
                    }
                    if drag == nil, let hit = rects.indices.last(where: { toView(rects[$0]).contains(value.startLocation) }) {
                        selection = hit
                        drag = (hit, .move, rects[hit])
                    }
                    if drag == nil, allowsCreate {
                        if single && !rects.isEmpty { rects = [] }
                        rects.append(CGRect(origin: p0, size: .zero))
                        selection = rects.count - 1
                        drag = (rects.count - 1, .create, rects[rects.count - 1])
                    }
                }
                guard let drag, drag.index < rects.count else { return }
                var rect: CGRect
                var anchor: CGPoint?  // the corner that stays put while sizing
                switch drag.mode {
                case .move:
                    rect = drag.start.offsetBy(dx: p1.x - p0.x, dy: p1.y - p0.y)
                    rect.origin.x = min(max(0, rect.minX), 1 - rect.width)
                    rect.origin.y = min(max(0, rect.minY), 1 - rect.height)
                case .create:
                    anchor = p0
                    rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                case .resize(let corner):
                    let s = drag.start
                    let fixed: CGPoint = switch corner {
                    case .topLeft: CGPoint(x: s.maxX, y: s.maxY)
                    case .topRight: CGPoint(x: s.minX, y: s.maxY)
                    case .bottomLeft: CGPoint(x: s.maxX, y: s.minY)
                    case .bottomRight: CGPoint(x: s.minX, y: s.minY)
                    }
                    anchor = fixed
                    rect = CGRect(x: min(fixed.x, p1.x), y: min(fixed.y, p1.y), width: abs(p1.x - fixed.x), height: abs(p1.y - fixed.y))
                }
                if let aspect, aspect > 0, let anchor {
                    // Aspect is in pixels; convert to unit space for this image. Shrinking one side keeps
                    // the anchored corner where it is, so the box never leaves the image.
                    let unitAspect = CGFloat(aspect) * imageSize.height / imageSize.width
                    if rect.width / max(rect.height, 0.0001) > unitAspect { rect.size.width = rect.height * unitAspect } else { rect.size.height = rect.width / unitAspect }
                    rect.origin.x = p1.x < anchor.x ? anchor.x - rect.width : anchor.x
                    rect.origin.y = p1.y < anchor.y ? anchor.y - rect.height : anchor.y
                }
                rects[drag.index] = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }.onEnded { _ in
                if let drag, drag.index < rects.count, rects[drag.index].width < 0.01 || rects[drag.index].height < 0.01, case .create = drag.mode {
                    rects.remove(at: drag.index)
                    selection = nil
                }
                drag = nil
            })
        }
    }
}

// MARK: - Ordering files

/// Reorderable list of files with thumbnails.
struct OrderList: View {
    @Binding var urls: [URL]

    var body: some View {
        List {
            ForEach(urls, id: \.self) { url in
                HStack(spacing: 10) {
                    FileThumbnail(url: url, size: 40)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            .onMove { urls.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

/// Finder-style thumbnail (Quick Look) of any file.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 48
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await Thumbnails.image(for: url, size: size * 2) }
    }
}

enum Thumbnails {
    static func image(for url: URL, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

import QuickLookThumbnailing
