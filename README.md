# WheelConvert

A free macOS menu bar app that converts and edits files while you drag them. Start dragging a file in
Finder, press a modifier key, and a wheel appears under the pointer: drop on a petal to convert, open a
tool, or run a file action. Everything runs locally.

- **⇧ Shift** — Convert (images, video, audio, PDF, documents, slides, spreadsheets, subtitles, archives)
- **⌘ Command** — File tools (compress, crop, trim, redact, merge, split, metadata, …)
- **⌃ Control** — File actions (AirDrop, Float, Copy, Move, Copy Path, Terminal)

Keys are configurable in Settings. Results are saved next to the original (or in Downloads when that
folder is read-only) and never overwrite an existing file.

Requirements: macOS 13 or later on Apple silicon.

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

## Testing

```bash
python3 -I scripts/test-conversions.py   # every conversion in the matrix, outputs validated
python3 -I scripts/test-tools.py         # every tool through the CLI
zsh scripts/run-logic-tests.sh           # unit tests (drag state machine, naming, parsers) without an XCTest host
python3 -I scripts/test-malformed.py     # empty, random and truncated inputs must fail cleanly, never crash or hang
```

The app binary also has developer modes used by these scripts:
`--convert <file> <format> [--options <json>]`, `--tool <tool> <files…> [--options <json>]`,
`--outputs <file>`, and `--snapshot <view> <out.png> [files…]` for offscreen UI renders.

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
