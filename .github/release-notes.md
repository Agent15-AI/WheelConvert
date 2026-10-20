## Install

**Homebrew** (opens with no extra steps):

```
brew tap Agent15-AI/wheelconvert https://github.com/Agent15-AI/WheelConvert
brew install --cask wheelconvert
```

**Disk image:** download `WheelConvert-x.y.z.dmg` below, open it, and drag WheelConvert to Applications.
WheelConvert isn't notarized by Apple, so the first time you open it macOS says it can't verify the
developer. Either:

- open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to WheelConvert; or
- run `xattr -dr com.apple.quarantine /Applications/WheelConvert.app` in Terminal once.

WheelConvert 1.1 and later update themselves: they check automatically, and **Check for Updates…** in the
menu bar menu checks right away.

Requires macOS 13 or later on an Apple silicon Mac. The FFmpeg and LAME source archives are attached as
their LGPL license asks.
