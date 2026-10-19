import Foundation
import Network

/// Lets AVPlayer preview files it can't open (MKV, WebM, AVI, WMV, OGG…) without converting the whole
/// file first. A loopback-only HTTP server offers an HLS playlist that covers the full duration, and
/// ffmpeg encodes its segments on demand, starting wherever the player asks and running a little
/// ahead of the playhead.
final class PreviewStream: @unchecked Sendable {
    static let segmentLength = 4.0
    /// Segments past the player's that the encoder prepares before it is paused.
    private static let lookahead = 8

    private let source: URL
    private let duration: Double
    private let video: Bool
    private let folder: URL
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "app.wheelconvert.preview-stream")
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    // Encoder state, only touched on `queue`. Each run writes its own file names, so a restarted
    // encoder never replaces a segment the player may be reading.
    private var producer: Process?
    private var run = 0
    private var position = 0
    private var paused = false
    private var segments: [Int: URL] = [:]
    private var lastRequested = 0
    private var stopped = false

    init(source: URL, duration: Double, video: Bool) {
        self.source = source
        self.duration = duration
        self.video = video
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WheelConvert-preview-\(UUID().uuidString)", isDirectory: true)
    }

    var segmentCount: Int { max(1, Int((duration / Self.segmentLength).rounded(.up))) }

    /// Starts the server and returns the playlist URL for AVPlayer.
    func start() async throws -> URL {
        guard duration > 0 else { throw WheelError("This file has no playable duration.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Cleared after the first outcome, so the continuation resumes exactly once.
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/index.m3u8") else { throw WheelError("The preview could not start.") }
        return url
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            stopProducer()
        }
        try? FileManager.default.removeItem(at: folder)
    }

    deinit { if !stopped { stop() } }

    // MARK: Playlist

    func playlist() -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(Self.segmentLength))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<segmentCount {
            let length = min(Self.segmentLength, duration - Double(index) * Self.segmentLength)
            text += String(format: "#EXTINF:%.3f,\n", max(0.001, length)) + String(format: "seg%05d.ts\n", index)
        }
        return text + "#EXT-X-ENDLIST\n"
    }

    // MARK: Encoder

    private func startProducer(at segment: Int) {
        stopProducer()
        run += 1
        position = segment
        let start = Double(segment) * Self.segmentLength
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error"]
        if FileFormat.detect(source) == .avi { args += ["-fflags", "+genpts"] }
        args += ["-ss", String(format: "%.3f", start), "-i", source.path]
        if video {
            // Keyframes on every segment boundary, so each segment starts exactly where the playlist says.
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(720,ih)',format=yuv420p",
                     "-c:v", "h264_videotoolbox", "-q:v", "55", "-allow_sw", "1",
                     "-force_key_frames", "expr:gte(t,n_forced*\(Int(Self.segmentLength)))"]
        } else {
            args += ["-map", "0:a:0", "-vn"]
        }
        args += ["-c:a", "aac_at", "-b:a", "160k", "-ac", "2", "-sn", "-dn",
                 "-output_ts_offset", String(format: "%.3f", start), "-muxdelay", "0", "-muxpreload", "0",
                 "-f", "hls", "-hls_time", "\(Int(Self.segmentLength))", "-hls_list_size", "0", "-hls_flags", "temp_file",
                 "-hls_segment_type", "mpegts", "-start_number", "\(segment)",
                 "-hls_segment_filename", folder.appendingPathComponent("r\(run)-seg%05d.ts").path,
                 folder.appendingPathComponent("r\(run).m3u8").path]
        let process = Process()
        process.executableURL = Bundled.ffmpeg
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            producer = process
            paused = false
        } catch {
            producer = nil
        }
    }

    private func stopProducer() {
        guard let process = producer else { return }
        producer = nil
        if process.isRunning {
            // A stopped process only acts on SIGTERM once it runs again.
            kill(process.processIdentifier, SIGCONT)
            process.terminate()
        }
    }

    private func file(_ index: Int, run: Int) -> URL { folder.appendingPathComponent(String(format: "r\(run)-seg%05d.ts", index)) }

    /// Records finished segments and keeps the encoder only a little ahead of the player.
    private func tick() {
        while position < segmentCount, FileManager.default.fileExists(atPath: file(position, run: run).path) {
            if segments[position] == nil { segments[position] = file(position, run: run) }
            position += 1
        }
        guard let process = producer, process.isRunning else { return }
        let ready = (lastRequested...(lastRequested + Self.lookahead)).allSatisfy { $0 >= segmentCount || segments[$0] != nil }
        if ready != paused {
            kill(process.processIdentifier, ready ? SIGSTOP : SIGCONT)
            paused = ready
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, request: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return send(connection, status: 405) }
        let head = parts[0] == "HEAD"
        let path = parts[1].split(separator: "/")
        guard path.count == 2, path[0] == token else { return send(connection, status: 404) }
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.flatMap { Self.byteRange($0) }
        if path[1] == "index.m3u8" {
            return send(connection, status: 200, type: "application/vnd.apple.mpegurl", body: Data(playlist().utf8), head: head)
        }
        guard path[1].hasPrefix("seg"), path[1].hasSuffix(".ts"), let index = Int(path[1].dropFirst(3).dropLast(3)), (0..<segmentCount).contains(index) else {
            return send(connection, status: 404)
        }
        lastRequested = index
        if segments[index] == nil {
            // Far from where the encoder is (a seek): restart it there. Nearby: it gets there soon.
            if producer?.isRunning != true || index < position || index > position + 2 { startProducer(at: index) }
            tick()
        }
        wait(for: index, deadline: Date().addingTimeInterval(30)) { [weak self] file in
            guard let self else { return connection.cancel() }
            guard let file, let data = try? Data(contentsOf: file) else { return self.send(connection, status: 404) }
            self.send(connection, status: 200, type: "video/mp2t", body: data, range: range, head: head)
        }
    }

    private func wait(for index: Int, deadline: Date, _ done: @escaping (URL?) -> Void) {
        tick()
        if let file = segments[index] { return done(file) }
        guard !stopped, Date() < deadline, producer?.isRunning == true || FileManager.default.fileExists(atPath: file(index, run: run).path) else { return done(nil) }
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.wait(for: index, deadline: deadline, done) ?? done(nil) }
    }

    static func byteRange(_ header: String) -> ClosedRange<Int>? {
        guard let spec = header.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int(bounds[0]) else { return nil }
        return lower...(Int(bounds[1]) ?? Int.max)
    }

    private func send(_ connection: NWConnection, status: Int, type: String = "text/plain", body: Data = Data(), range: ClosedRange<Int>? = nil, head: Bool = false) {
        var status = status, payload = body
        var extra = ""
        if let range, status == 200, !body.isEmpty {
            let upper = min(range.upperBound, body.count - 1)
            guard range.lowerBound <= upper else { return send(connection, status: 416) }
            payload = body.subdata(in: range.lowerBound..<(upper + 1))
            extra = "Content-Range: bytes \(range.lowerBound)-\(upper)/\(body.count)\r\n"
            status = 206
        }
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nAccept-Ranges: bytes\r\n\(extra)Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !head { response.append(payload) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
