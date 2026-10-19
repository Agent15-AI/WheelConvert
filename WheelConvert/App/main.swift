import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
if ["--convert", "--tool", "--outputs", "--snapshot"].contains(where: CommandLine.arguments.contains) {
    // Headless mode for scripted testing: WheelConvert --convert <file> <format>
    app.setActivationPolicy(.prohibited)
    CommandLineMode.start()
} else {
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
}
app.run()
