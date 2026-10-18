import Foundation

/// Which output formats each input format converts to, in wheel order.
enum ConversionMatrix {
    static let imageTargets: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
    static let videoTargets: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
    static let audioTargets: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff]
    static let documentTargets: [FileFormat] = [.pdf, .docx, .pages, .md, .txt, .epub, .html]
    static let spreadsheetTargets: [FileFormat] = [.xlsx, .ods, .csv, .tsv, .pdf]
    static let archiveTargets: [FileFormat] = [.zip, .tar, .gzip]

    static func outputs(for input: FileFormat) -> [FileFormat] {
        let targets: [FileFormat]
        switch input.category {
        case .images: targets = imageTargets
        case .video: targets = input == .gif ? [.mp4, .mov, .mkv, .webm, .avi, .wmv] : videoTargets
        case .audio: targets = audioTargets
        case .pdf: targets = [.docx, .pages, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md]
        case .documents: targets = input == .html ? [] : documentTargets
        case .slides: targets = [.pdf, .jpg, .png]
        case .spreadsheets: targets = spreadsheetTargets
        case .subtitles: targets = [.srt, .vtt, .txt]
        case .archives: targets = archiveTargets
        }
        return targets.filter { $0 != input }
    }

    /// Targets every selected file can reach, ordered like the first file's wheel.
    static func outputs(for inputs: [FileFormat]) -> [FileFormat] {
        guard let first = inputs.first else { return [] }
        var common = outputs(for: first)
        for format in inputs.dropFirst() {
            let allowed = Set(outputs(for: format))
            common.removeAll { !allowed.contains($0) }
        }
        return common
    }

    /// Folders become archives.
    static let folderTargets: [FileFormat] = archiveTargets

    /// All conversions, for the settings compatibility table and tests.
    static var allPairs: [(FileFormat, FileFormat)] {
        FileFormat.allCases.flatMap { input in outputs(for: input).map { (input, $0) } }
    }
}
