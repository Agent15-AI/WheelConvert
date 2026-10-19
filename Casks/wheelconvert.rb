cask "wheelconvert" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Agent15-AI/WheelConvert/releases/download/v#{version}/WheelConvert-#{version}.dmg"
  name "WheelConvert"
  desc "Convert and edit files while you drag them"
  homepage "https://github.com/Agent15-AI/WheelConvert"

  depends_on arch: :arm64
  depends_on macos: :ventura

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
