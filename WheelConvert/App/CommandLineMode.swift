import AppKit

/// `WheelConvert --convert <file> <format>` converts one file and prints the saved paths.
enum CommandLineMode {
    static func start() {
        let args = CommandLine.arguments
        Task { @MainActor in
            do {
                if let i = args.firstIndex(of: "--outputs"), i + 1 < args.count {
                    let url = URL(fileURLWithPath: args[i + 1])
                    let formats = FileFormat.detect(url).map { ConversionMatrix.outputs(for: $0) } ?? []
                    print(formats.map(\.rawValue).joined(separator: " "))
                    exit(0)
                }
                if let i = args.firstIndex(of: "--convert"), i + 2 < args.count {
                    let source = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
                    guard let format = FileFormat(rawValue: args[i + 2]) else { throw WheelError("Unknown format \(args[i + 2])") }
                    var options = AppSettings.shared.options(for: format)
                    if let j = args.firstIndex(of: "--options"), j + 1 < args.count, let data = args[j + 1].data(using: .utf8) {
                        options = try JSONDecoder().decode(ConversionOptions.self, from: data)
                    }
                    let outputs = try await Converter.convert(source, to: format, options: options) { _ in }
                    outputs.forEach { print("OUT:\($0.path)") }
                    exit(0)
                }
                throw WheelError("usage: WheelConvert --convert <file> <format> [--options <json>]")
            } catch {
                FileHandle.standardError.write(Data("ERROR:\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}
