# WheelConvert

A free macOS menu bar app that converts and edits files while you drag them. Start dragging a file in
Finder (or, for Smart Actions, a picture, some text or a link from any app), press a modifier key, and a wheel
appears under the pointer: drop on a petal to convert, open a tool, or run an action. Everything runs locally.

- **⇧ Shift** — Convert (images including camera RAW, video, audio, PDF, documents, slides, spreadsheets, subtitles, archives)
- **⌘ Command** — File tools (compress, crop, trim, redact, merge, split, metadata, extract text, extract audio, …)
- **⌃ Control** — File actions (AirDrop, Float, Copy, Move, Copy Path, Terminal)
- **⌥ Option** — Smart actions: petals that fit whatever you drag, from files or from other apps (below)

### Smart actions (⌥)

The smart wheel looks at what is being dragged and shows only the petals that work for it, on this Mac:

| Dragged | Petals |
|---|---|
| Pictures (files, or images dragged out of Safari, Chrome and other apps) | Remove Background (transparent PNG, macOS 14+), Extract Text, Read QR Code, Copy Colors (the main colors as hex), Strip location and metadata, Resize (longest edge 512–3840 px, never enlarges) |
| Selected text | Make QR Code (up to 2,331 bytes), Copy as Plain Text, Copy as Markdown (when the text carried formatting), Copy as Quote, Count Words, Translate, Summarize, Speak, Save as a .txt file (.md when formatted) |
| Links | Copy Clean Link (removes `utm_*`, `fbclid`, `gclid` and other click trackers), Make QR Code, Save Link File (.webloc), Open in Private Window |
| Any files and folders | Copy SHA-256, Copy MD5, Verify Checksum (paste the expected value; MD5, SHA-1, SHA-256 and SHA-512 are recognized), Show in Finder, Copy Path, Make Zip to Share (one archive, without .DS_Store and other Mac-only files) |

Nothing leaves the Mac: no petal makes a network call. Translate appears only on macOS 26 and only for languages
already downloaded in System Settings → General → Language & Region → Translation Languages, and translates into
your Mac's language. Summarize appears only on macOS 26 with Apple Intelligence's on-device model available, for text
of 40 words to 8,000 characters (it never uses Private Cloud Compute). Open in Private Window appears only when the
default browser takes a private-window launch option (Chrome, Brave, Edge, Vivaldi, Opera, Firefox); Safari has none.
Hashes and checksums are copied to the clipboard; results of text, links and dragged-in pictures are saved where
Settings → Save results says, which is Downloads when "next to the original" has no original folder.

Limits: pictures that apps offer only as a promised file (the Photos app, for instance) aren't read; drag the photo
to Finder first. Saving a web page from a link isn't offered, because it would need to download the page.
How each content type was confirmed to be detectable is in [docs/WHEEL-OF-ANYTHING-DECISIONS.md](docs/WHEEL-OF-ANYTHING-DECISIONS.md).

### Custom petals

Settings → Custom adds your own petals to the smart wheel: a name, an SF Symbol or emoji, what they work with
(pictures, text, links, files — optionally only some extensions) and what they do:

- **Run a Shortcut** by name, with the item as its input (text and links arrive as a text file);
- **Run a shell script** (zsh): files arrive as `"$1"`, `"$2"`… (`"$@"` for all), text and links on standard input;
- **Open with an app** you choose;
- **Open a URL** such as `things:///add?title={text}`, with `{path}`, `{text}` or `{url}` replaced by the item.

What a script prints or a Shortcut returns is saved like any other result, with the progress panel, Cancel and the
recent-results menu. Security model: petals only ever come from what you type in Settings — WheelConvert never
imports them and never runs anything found in a dropped file, link or the clipboard. Before a petal's first run, and
after every change to it, a dialog shows exactly what will run. Items are passed as arguments, standard input or
encoded URL parts, never pasted into a command, so file names with quotes, `$()`, backticks or newlines can't inject
anything. Scripts get a plain login environment, a time limit (2 minutes unless you change it) and at most 10 MB of
kept output. More detail in [docs/WHEEL-OF-ANYTHING-DECISIONS.md](docs/WHEEL-OF-ANYTHING-DECISIONS.md).

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

Without dragging, right-click files in Finder and choose **Convert with WheelConvert**, **WheelConvert Tools**,
**WheelConvert File Actions** or **WheelConvert Smart Actions** (which also works on selected text and links in other
apps); the wheel opens at the pointer and a click picks a petal (Escape or a click
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
`--watch <folder> <preset> <seconds>`, `--intent convert|compress|preset <argument> <files…>` (the Shortcuts actions),
`--smart-items <input>` (the smart wheel's petals), `--smart <action[:argument]> <input>` and `--custom <petal.json> <input>`
(a custom petal defined in that file, run without the approval dialog), where the input is files,
`text:<file>`, `html:<file>` or `link:<address>`; copied text is printed as `COPY:<json>` instead of touching the clipboard,
and `WHEELCONVERT_RESULTS=<folder>` sets where scripted results go.

`scripts/e2e/update-test.sh` builds two ad-hoc signed copies with a throwaway key and checks that Sparkle
updates the older one from a local appcast (it briefly adds a second WheelConvert icon to the menu bar).

`scripts/e2e/DragDriver.swift` performs a real drag with a modifier tap and drops on a petal; the dragged item can
be a file, `text:<words>` or `link:<address>`, and the key `option` opens the smart wheel. It moves the mouse and
presses keys, so run it only while you're not using the Mac (and not while the screen is locked).

## Layout

- `WheelConvert/Drag` — polling drag monitor and the testable `DragTracker` state machine
- `WheelConvert/Wheel` — the wheel panel and view
- `WheelConvert/Smart` — what a drag carries (`DragContent`) and the smart wheel's petals
- `WheelConvert/Converters` — conversion engine (ImageIO, ffmpeg, WebKit printing, structured documents)
- `WheelConvert/Tools` — file tools and their windows
- `WheelConvert/Jobs` — job queue and progress panels
- `java/` — Office helper (slides, spreadsheets, PDF → PPTX/XLSX)
- `js/` — Pages and DOCX rendering bridges

Third-party components and licenses: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
