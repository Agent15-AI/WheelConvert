# WheelConvert

A free macOS menu bar app that converts and edits files while you drag them. Start dragging a file in
Finder, press a modifier key, and a wheel appears under the pointer: drop on a petal to convert, open a
tool, or run a file action. Everything runs locally.

- **⇧ Shift** — Convert (images including camera RAW, video, audio, PDF, documents, slides, spreadsheets, subtitles, archives)
- **⌘ Command** — File tools (compress, crop, trim, redact, merge, split, metadata, extract text, extract audio, …)
- **⌃ Control** — File actions (AirDrop, Float, Copy, Move, Copy Path, Terminal)

Kindle books (MOBI and AZW3, DRM-free only) convert like any document, and the **Kindle** target makes an EPUB
tuned for Send to Kindle: pictures resized to Kindle screens, a cover, and a table of contents Kindle can read.
Documents and PDFs also convert to **MOBI**, the classic Kindle format, for copying onto a Kindle over USB or
reading in other e-book apps (Amazon's Send to Kindle no longer accepts MOBI files, so use the Kindle target there).

Presets are saved recipes, such as "Instagram 1080 px JPG" or "Email-size MP4 (under 25 MB)": a target format
with its options, or a tool with its settings. Matching presets appear as extra petals on the Convert wheel.
Manage them in Settings → Presets. Settings → Watch Folders runs a preset on every new file dropped into a
chosen folder, once the file has finished copying; WheelConvert's own results are never processed again.

The Shortcuts app gets three WheelConvert actions — **Convert File**, **Compress File** and **Apply Preset** —
which take files and return the saved results, so conversions can be automated.

Without dragging, right-click files in Finder and choose **Convert with WheelConvert**, **WheelConvert Tools**
or **WheelConvert File Actions**; the wheel opens at the pointer and a click picks a petal (Escape or a click
elsewhere cancels). These are macOS Services, so they may sit under Quick Actions or Services when many are installed.

Keys are configurable in Settings. Results are saved next to the original (or in Downloads when that
folder is read-only) and never overwrite an existing file. Settings → General → Save results can instead
ask for a folder each time or always use one chosen folder. The menu bar menu lists recent results.

WheelConvert speaks English, German, French, Spanish, Japanese and Simplified Chinese, following the
language set for it in System Settings → General → Language & Region.

Requirements: macOS 13 or later on Apple silicon.

## Install

**Homebrew:**

```bash
brew tap Agent15-AI/wheelconvert https://github.com/Agent15-AI/WheelConvert
```

```bash
brew install --cask wheelconvert
```

**Or download** `WheelConvert-x.y.z.dmg` from [Releases](https://github.com/Agent15-AI/WheelConvert/releases/latest),
open it and drag WheelConvert to Applications. WheelConvert isn't notarized by Apple, so the first launch
says macOS can't verify the developer. Open **System Settings → Privacy & Security** and click **Open Anyway**
next to WheelConvert, or run this once:

```bash
xattr -dr com.apple.quarantine /Applications/WheelConvert.app
```

Then open WheelConvert. It lives in the menu bar; the welcome window walks through the shortcuts.

## Releasing

Push a version tag and GitHub Actions builds everything from source, publishes the release (disk image,
checksum, signed Sparkle `appcast.xml`, and the LGPL source archives) and updates `Casks/wheelconvert.rb` on `main`:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

To build the same release locally instead: `scripts/release.sh 1.1.0` writes it to `dist/`.

### Update signing keys (once)

WheelConvert updates itself with [Sparkle](https://sparkle-project.org). Every update is signed with an
EdDSA key; the app carries the public half and refuses updates the private half didn't sign. This is
what lets updates work without a paid Apple Developer ID (the app stays ad-hoc signed).

1. Build once so Sparkle's tools are downloaded: `scripts/build.sh`.
2. Create the key pair. The private key goes into your login keychain; the command prints the public key:
   ```bash
   build/DD/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
3. Put the public key in `project.yml` (`SPARKLE_PUBLIC_KEY: <key>`) and commit it. It is public; it belongs in the repo.
4. Give the private key to GitHub Actions as a secret. This exports it into a folder only you can read,
   uploads it and deletes the copy:
   ```bash
   KEYDIR=$(mktemp -d) && build/DD/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x "$KEYDIR/key" && gh secret set SPARKLE_PRIVATE_KEY --repo Agent15-AI/WheelConvert < "$KEYDIR/key"; rm -rf "$KEYDIR"
   ```
5. Keep a backup of the private key (it stays in your keychain as "Private key for signing Sparkle updates";
   a password manager is a good second copy). If it's lost, installed copies can't accept updates signed
   with a new key, and people would have to download the next version by hand.

The release fails early, with a message, if the public key or the secret is missing, and it checks that
the secret's signature verifies with the public key before publishing anything. Builds without a public
key (local development) never check for updates.

## Building

Tools: Xcode (built with 27.1), Homebrew `xcodegen` and `pkg-config`, Node.js, and JDK 21
(`brew install openjdk@21`, or set `JAVA_HOME`). The vendor steps download sources over the network; every download is checked against a pinned or published checksum.

```bash
scripts/build-ffmpeg.sh        # static FFmpeg/ffprobe with LAME, libvpx, Opus, Vorbis, libwebp → Vendor/build
scripts/build-java.sh          # Apache POI/PDFBox jars, the WheelConvertOffice helper, a jlink'd runtime
scripts/build-exiftool.sh      # ExifTool (Perl)
(cd js && npm ci && npm run build)   # docx-preview and cupertino-files bundles
scripts/collect-licenses.sh    # third-party license texts → Vendor/build/licenses
scripts/build.sh               # xcodegen + Debug build → build/DD/Build/Products/Debug/WheelConvert.app
```

`scripts/build.sh` passes extra arguments to `xcodebuild`, e.g. `CONFIG=Release scripts/build.sh`.
The Xcode build embeds and signs the vendor tools (`scripts/embed-vendor.sh`).

User-facing text lives in String Catalogs (`WheelConvert/Resources/Localizable.xcstrings`, plus
`ServicesMenu.xcstrings` for the Finder menu items). After changing text in the code, run `scripts/build.sh` and then
`scripts/sync-strings.sh`, which adds new strings to the catalog as Xcode does, and translate them in Xcode's catalog
editor. `scripts/test-tools.py` fails while any string lacks a translation or has mismatched placeholders.
To see the app in another language: `WheelConvert -AppleLanguages '(de)' --snapshot settings out.png`.

## Testing

The suites make their sample files first with `scripts/make-fixtures.sh` (in `build/fixtures`; it needs
`scripts/build.sh` and, for the Office samples, `brew install openjdk@21`).

```bash
python3 -I scripts/test-conversions.py   # every conversion in the matrix, outputs validated (fetches two CC0 raw samples once)
python3 -I scripts/test-tools.py         # every tool through the CLI, plus preview start-up times on hour-long videos
zsh scripts/run-logic-tests.sh           # unit tests (drag state machine, naming, parsers) without an XCTest host
python3 -I scripts/test-malformed.py     # empty, random and truncated inputs must fail cleanly, never crash or hang
```

The app binary also has developer modes used by these scripts:
`--convert <file> <format> [--options <json>]`, `--tool <tool> <files…> [--options <json>]`,
`--outputs <file>`, `--snapshot <view> <out.png> [files…]` for offscreen UI renders, and
`--preview-check <file> [seconds]`, which times how quickly a tool preview starts playing (and plays again after a seek),
`--batch <format> <files…>` (the parallel job queue), `--preset <name> <files…>`,
`--watch <folder> <preset> <seconds>` and `--intent convert|compress|preset <argument> <files…>` (the Shortcuts actions).

`scripts/e2e/update-test.sh` builds two ad-hoc signed copies with a throwaway key and checks that Sparkle
updates the older one from a local appcast (it briefly adds a second WheelConvert icon to the menu bar).

`scripts/e2e/DragDriver.swift` performs a real drag with a modifier tap and drops on a petal. It moves the
mouse and presses keys, so run it only while you're not using the Mac.

## Layout

- `WheelConvert/Drag` — polling drag monitor and the testable `DragTracker` state machine
- `WheelConvert/Wheel` — the wheel panel and view
- `WheelConvert/Converters` — conversion engine (ImageIO, ffmpeg, WebKit printing, structured documents)
- `WheelConvert/Tools` — file tools and their windows
- `WheelConvert/Jobs` — job queue and progress panels
- `java/` — Office helper (slides, spreadsheets, PDF → PPTX/XLSX)
- `js/` — Pages and DOCX rendering bridges

Third-party components and licenses: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
