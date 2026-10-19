# Third-party software in WheelConvert

WheelConvert is free. It bundles the open-source components below; their full license texts are in
`WheelConvert.app/Contents/Resources/Licenses` (and `Office/runtime/legal` for the Java runtime).

## Media (separate executables: `Tools/ffmpeg`, `Tools/ffprobe`)

| Component | Version | License |
|---|---|---|
| FFmpeg | 9.0.1 | LGPL 2.1 or later (built without `--enable-gpl` or `--enable-nonfree`) |
| LAME (MP3 encoder) | 3.100 | LGPL 2 or later |
| libvpx (VP8/VP9) | 1.17.0 | BSD 3-Clause |
| Opus | 1.6.1 | BSD 3-Clause |
| libogg / libvorbis | 1.3.6 / 1.3.7 | BSD 3-Clause |
| libwebp | 1.6.0 | BSD 3-Clause (also linked into the app for WebP encoding) |

FFmpeg and its codec libraries run as standalone programs that WheelConvert launches; they are not linked
into the app. The exact FFmpeg and LAME source archives used for each build are attached to its GitHub
release, and `scripts/build-ffmpeg.sh` rebuilds them with the recorded configure flags (`ffmpeg -version`
prints them). You may rebuild and replace `Tools/ffmpeg` and `Tools/ffprobe` with your own LGPL-compatible
builds.

## Metadata

| Component | Version | License |
|---|---|---|
| ExifTool by Phil Harvey | 13.59 | Same terms as Perl (Artistic License or GPL) |

ExifTool runs as an unmodified script on macOS's `/usr/bin/perl`.

## Office documents (Java helper under `Office/`)

| Component | Version | License |
|---|---|---|
| Apache POI (poi, poi-ooxml, poi-ooxml-lite, poi-scratchpad) | 5.5.1 | Apache 2.0 |
| Apache PDFBox, FontBox, PDFBox-IO | 3.0.8 | Apache 2.0 |
| pdfbox-graphics2d (de.rototor) | 3.0.5 | Apache 2.0 |
| Apache XMLBeans | 5.3.0 | Apache 2.0 |
| Apache Commons (Codec, Collections, Compress, IO, Lang, Logging, Math) | see jar names | Apache 2.0 |
| Apache Log4j API | 2.24.3 | Apache 2.0 |
| SparseBitSet | 1.3 | Apache 2.0 |
| curvesapi | 1.08 | BSD 3-Clause |
| OpenJDK runtime (jlink image) | 21.0.12 | GPL 2 with the Classpath Exception; source: https://github.com/openjdk/jdk21u |

Apache NOTICE files for these libraries are included under `Licenses/Java`.

## JavaScript (bundled into `JS/*.js`)

| Component | Version | License |
|---|---|---|
| docx-preview | 0.4.1 | Apache 2.0 |
| cupertino-files | 0.4.0 | MIT |
| JSZip | 3.10.2 | MIT (dual-licensed MIT or GPL 3; used under MIT) |
| pako | 3.0.2 | MIT and Zlib |
| lie, immediate, setimmediate, readable-stream, core-util-is, inherits, isarray, process-nextick-args, safe-buffer, string_decoder, util-deprecate | — | MIT / ISC |

## Apple frameworks

ImageIO, Core Image, Vision, PDFKit, WebKit, AVFoundation, VideoToolbox and AudioToolbox are part of macOS.
