import Foundation

/// One petal on the wheel.
struct WheelItem: Equatable, Identifiable {
    enum Action: Equatable {
        case convert(FileFormat)
        case tool(ToolKind)
        case fileAction(FileAction)
        case preset(Preset)
    }

    let action: Action
    var id: String {
        switch action {
        case .convert(let f): "convert." + f.rawValue
        case .tool(let t): "tool." + t.rawValue
        case .fileAction(let a): "action." + a.rawValue
        case .preset(let p): "preset." + p.id.uuidString
        }
    }

    var label: String {
        switch action {
        case .convert(let f): f.wheelLabel
        case .tool(let t): t.wheelLabel
        case .fileAction(let a): a.wheelLabel
        case .preset(let p): p.label.uppercased()
        }
    }

    /// Longer name shown in the center while hovering.
    var title: String {
        switch action {
        case .convert(let f): "Convert to \(f.title)"
        case .tool(let t): t.title
        case .fileAction(let a): a.title
        case .preset(let p): p.name
        }
    }

    var symbol: String? {
        switch action {
        case .convert: nil
        case .tool(let t): t.symbol
        case .fileAction(let a): a.symbol
        case .preset: "wand.and.stars"
        }
    }

    /// Presets shown after the format petals, at most this many.
    static let presetLimit = 6

    /// Builds the petals for a wheel and the idle center text.
    static func items(for mode: WheelMode, urls: [URL]) -> (items: [WheelItem], idle: String) {
        let formats = urls.map(FileFormat.detect)
        let folders = urls.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false }
        let count = urls.count
        switch mode {
        case .convert:
            if folders.allSatisfy({ $0 }) {
                return (ConversionMatrix.folderTargets.map { WheelItem(action: .convert($0)) }, count == 1 ? "FOLDER" : "\(count) FOLDERS")
            }
            guard !folders.contains(true), formats.allSatisfy({ $0 != nil }) else { return ([], "Unsupported file type") }
            let known = formats.compactMap { $0 }
            let targets = ConversionMatrix.outputs(for: known)
            let presets = AppSettings.shared.presets.filter { $0.showOnWheel && $0.applies(to: urls) }.prefix(presetLimit)
            let items = targets.map { WheelItem(action: .convert($0)) } + presets.map { WheelItem(action: .preset($0)) }
            let idle: String
            if Set(known).count == 1, let first = known.first { idle = count == 1 ? first.wheelLabel : "\(count) \(first.wheelLabel)" } else { idle = "\(count) FILES" }
            return (items, items.isEmpty ? "No conversions" : idle)
        case .tools:
            let tools = folders.contains(true) ? [] : ToolKind.available(for: formats)
            return (tools.map { WheelItem(action: .tool($0)) }, tools.isEmpty ? "No tools available" : "TOOLS")
        case .actions:
            return (FileAction.allCases.map { WheelItem(action: .fileAction($0)) }, "ACTIONS")
        }
    }
}
