import Foundation

/// The file tools (second wheel).
enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case compress, removeMetadata
    case editImage, annotateImage, frameImage, cropImage, redactImage, createPDF, createCollage, readQRCode, extractText
    case trimVideo, cropVideo, changeVideoSpeed, muteVideo, extractAudio, joinVideos, videoSnapshots, splitVideo, redactVideo
    case normalizeAudio, audioToVideo, trimAudio, audioChannels, redactAudio
    case mergePDF, organizePDF, splitPDF
    case extractArchive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: "Compress"
        case .removeMetadata: "Edit Metadata"
        case .editImage: "Edit Photo"
        case .annotateImage: "Annotate"
        case .frameImage: "Add Background"
        case .cropImage: "Crop"
        case .redactImage: "Redact"
        case .createPDF: "Create PDF"
        case .createCollage: "Make Collage"
        case .readQRCode: "Read QR Code"
        case .extractText: "Extract Text"
        case .trimVideo: "Trim Video"
        case .cropVideo: "Crop Video"
        case .changeVideoSpeed: "Change Speed"
        case .muteVideo: "Mute"
        case .extractAudio: "Extract Audio"
        case .joinVideos: "Join Videos"
        case .videoSnapshots: "Save Frames"
        case .splitVideo: "Split Video"
        case .redactVideo: "Redact Video"
        case .normalizeAudio: "Normalize Volume"
        case .audioToVideo: "Audio Visualizer"
        case .trimAudio: "Trim Audio"
        case .audioChannels: "Audio Channels"
        case .redactAudio: "Bleep Audio"
        case .mergePDF: "Merge PDFs"
        case .organizePDF: "Organize Pages"
        case .splitPDF: "Split PDF"
        case .extractArchive: "Extract"
        }
    }

    var wheelLabel: String {
        switch self {
        case .compress: "COMPRESS"
        case .removeMetadata: "METADATA"
        case .editImage: "EDIT"
        case .annotateImage: "ANNOTATE"
        case .frameImage: "ADD BG"
        case .cropImage, .cropVideo: "CROP"
        case .redactImage, .redactVideo: "REDACT"
        case .createPDF: "PDF"
        case .createCollage: "COLLAGE"
        case .readQRCode: "QR CODE"
        case .extractText: "TEXT"
        case .trimVideo, .trimAudio: "TRIM"
        case .changeVideoSpeed: "SPEED"
        case .muteVideo: "MUTE"
        case .extractAudio: "AUDIO"
        case .joinVideos: "JOIN"
        case .videoSnapshots: "FRAMES"
        case .splitVideo, .splitPDF: "SPLIT"
        case .normalizeAudio: "NORMALIZE"
        case .audioToVideo: "VISUALIZE"
        case .audioChannels: "CHANNELS"
        case .redactAudio: "BLEEP"
        case .mergePDF: "MERGE"
        case .organizePDF: "ORGANIZE"
        case .extractArchive: "EXTRACT"
        }
    }

    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: "info.circle"
        case .editImage: "slider.horizontal.3"
        case .annotateImage: "pencil.tip.crop.circle"
        case .frameImage: "photo.on.rectangle.angled"
        case .cropImage, .cropVideo: "crop"
        case .redactImage, .redactVideo: "eye.slash"
        case .createPDF: "doc.richtext"
        case .createCollage: "rectangle.3.group"
        case .readQRCode: "qrcode.viewfinder"
        case .extractText: "text.viewfinder"
        case .trimVideo, .trimAudio: "timeline.selection"
        case .changeVideoSpeed: "gauge.with.dots.needle.67percent"
        case .muteVideo: "speaker.slash.fill"
        case .extractAudio: "music.note"
        case .joinVideos: "rectangle.stack.badge.plus"
        case .videoSnapshots: "camera"
        case .splitVideo: "rectangle.split.2x1"
        case .normalizeAudio: "waveform.badge.magnifyingglass"
        case .audioToVideo: "waveform.and.magnifyingglass"
        case .audioChannels: "headphones"
        case .redactAudio: "waveform.badge.minus"
        case .mergePDF: "doc.on.doc"
        case .organizePDF: "square.grid.2x2"
        case .splitPDF: "scissors"
        case .extractArchive: "archivebox"
        }
    }

    /// Status shown in the progress window while the tool runs.
    var progressTitle: String {
        switch self {
        case .compress: "Compressing"
        case .removeMetadata: "Saving metadata"
        case .editImage: "Saving edited photo"
        case .annotateImage: "Annotating photo"
        case .frameImage: "Adding background"
        case .cropImage: "Cropping"
        case .redactImage, .redactVideo: "Redacting"
        case .createPDF: "Creating PDF"
        case .createCollage: "Creating collage"
        case .readQRCode: "Reading QR codes"
        case .extractText: "Extracting text"
        case .trimVideo, .trimAudio: "Trimming"
        case .cropVideo: "Cropping video"
        case .changeVideoSpeed: "Changing speed"
        case .muteVideo: "Muting"
        case .extractAudio: "Extracting audio"
        case .joinVideos: "Joining videos"
        case .videoSnapshots: "Saving frames"
        case .splitVideo: "Splitting video"
        case .normalizeAudio: "Normalizing volume"
        case .audioToVideo: "Creating visualization"
        case .audioChannels: "Converting channels"
        case .redactAudio: "Bleeping audio"
        case .mergePDF: "Merging PDFs"
        case .organizePDF: "Organizing pages"
        case .splitPDF: "Splitting PDF"
        case .extractArchive: "Extracting archive"
        }
    }

    /// Tools that run straight from the wheel without an options window.
    var runsImmediately: Bool { [.muteVideo, .extractAudio, .extractArchive, .readQRCode, .extractText].contains(self) }

    static let rasterImages: Set<FileFormat> = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp]
    static let editableVideo: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif]

    /// Tools that apply to every selected file, in wheel order.
    static func available(for formats: [FileFormat?]) -> [ToolKind] {
        guard !formats.isEmpty else { return [] }
        let known = formats.compactMap { $0 }
        guard known.count == formats.count else { return [] }
        let count = known.count, single = count == 1, many = count > 1
        let categories = Set(known.map(\.category))
        guard categories.count == 1, let category = categories.first else { return [] }
        switch category {
        case .images:
            guard known.allSatisfy(rasterImages.contains) else { return [] }
            var tools: [ToolKind] = [.compress, .removeMetadata]
            if single { tools += [.editImage, .annotateImage] }
            tools += [.frameImage, .cropImage]
            if single { tools.append(.redactImage) }
            tools += [.readQRCode, .extractText]
            if many { tools += [.createPDF, .createCollage] }
            return tools
        case .video:
            let gif = known.contains(.gif)
            var tools: [ToolKind] = [.compress]
            if !gif { tools.append(.removeMetadata) }
            if single { tools += [.trimVideo, .cropVideo, .changeVideoSpeed] }
            if !gif { tools += [.muteVideo, .extractAudio] }
            if single { tools += [.videoSnapshots, .splitVideo] }
            if single && !gif { tools.append(.redactVideo) }
            if many && !gif { tools.append(.joinVideos) }
            return tools
        case .audio:
            var tools: [ToolKind] = [.compress, .removeMetadata, .normalizeAudio, .trimAudio, .audioChannels]
            if single { tools += [.audioToVideo, .redactAudio] }
            return tools
        case .pdf:
            var tools: [ToolKind] = [.compress, .removeMetadata]
            if single { tools += [.organizePDF, .splitPDF] }
            tools += [.readQRCode, .extractText]
            if many { tools.append(.mergePDF) }
            return tools
        case .archives:
            return [.extractArchive]
        default:
            return []
        }
    }
}

/// The file actions (third wheel). They work for any files and folders.
enum FileAction: String, CaseIterable, Codable, Identifiable {
    case airDrop, float, copy, move, copyPath, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }

    var wheelLabel: String { title.uppercased() }

    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .float: "square.stack"
        case .copy: "doc.on.clipboard"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }

    var detail: String {
        switch self {
        case .airDrop: "Share files and folders with AirDrop"
        case .float: "Keep files in a floating shelf"
        case .copy: "Copy files and folders"
        case .move: "Move files and folders to a chosen folder"
        case .copyPath: "Copy file and folder paths"
        case .terminal: "Open terminal in folder"
        }
    }
}
