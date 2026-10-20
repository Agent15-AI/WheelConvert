cask "wheelconvert" do
  version "1.0.0"
  sha256 "cc5aeee191ba31d16748bed01c35eca1c8b8230c58cac46bbcd49dde6b0b74db"

  url "https://github.com/Agent15-AI/WheelConvert/releases/download/v#{version}/WheelConvert-#{version}.dmg"
  name "WheelConvert"
  desc "Convert and edit files while you drag them"
  homepage "https://github.com/Agent15-AI/WheelConvert"

  depends_on arch: :arm64
  depends_on macos: :ventura

  # WheelConvert updates itself with Sparkle (Check for Updates… in its menu).
  auto_updates true

  app "WheelConvert.app"

  # The app isn't notarized (no paid Apple Developer account), so clear the download quarantine;
  # otherwise Gatekeeper blocks the app and the helper tools bundled inside it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/WheelConvert.app"], must_succeed: false
  end

  uninstall quit: "app.wheelconvert.WheelConvert"

  zap trash: [
    "~/Library/Application Support/WheelConvert",
    "~/Library/Preferences/app.wheelconvert.WheelConvert.plist",
  ]
end
