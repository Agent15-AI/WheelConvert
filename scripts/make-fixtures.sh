#!/bin/zsh
# Creates the test fixtures in build/fixtures, skipping any that already exist. The test scripts run it
# first; it needs the vendor builds, scripts/build.sh (some fixtures are made by WheelConvert itself)
# and a JDK for the Office files (brew install openjdk@21). Downloaded samples are fetched by
# test-conversions.py.
set -euo pipefail
ROOT=${0:A:h:h}
F=$ROOT/build/fixtures
FF=$ROOT/Vendor/build/bin/ffmpeg
APP=$ROOT/build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert
[[ -x $APP ]] || { echo "Run scripts/build.sh first"; exit 1; }
mkdir -p $F
cd $F
have() { [[ -e $1 ]] }
ff() { $FF -v error -y "$@" }
# Converts with WheelConvert and renames the result.
convert() { local out=$($APP --convert "$1" "$2" | sed -n 's/^OUT://p' | head -1); [[ -n $out ]] && mv "$out" "$3" }

# Pictures: a 640×480 test card with an embedded date, in every image format.
have sample.png || ff -f lavfi -i testsrc2=s=640x480 -frames:v 1 sample.png
have sample.jpg || { sips -s format jpeg -s formatOptions 92 sample.png --out sample.jpg >/dev/null
                     $ROOT/Vendor/build/ExifTool/exiftool -q -overwrite_original -Make=WheelConvert -Model=Fixture -DateTimeOriginal="2024:05:01 10:00:00" sample.jpg 2>/dev/null || true; }
for ext in tiff bmp heic; do have sample.$ext || sips -s format $ext sample.png --out sample.$ext >/dev/null; done
have sample.webp || ff -i sample.png -c:v libwebp -quality 80 sample.webp
have sample.avif || convert sample.png avif sample.avif
have sample.svg || cat > sample.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200"><rect width="320" height="200" fill="#2EA8FF"/><circle cx="160" cy="100" r="60" fill="#FFCC00"/><text x="160" y="190" text-anchor="middle" font-size="18" fill="#fff">WheelConvert</text></svg>
SVG

# Video and audio: three seconds of test card and tone, in each container's usual codecs.
SRC=(-f lavfi -i testsrc2=s=640x480:r=30:d=3 -f lavfi -i sine=f=440:d=3 -ac 2)
have sample.mp4 || ff $SRC -c:v h264_videotoolbox -b:v 2M -c:a aac_at -pix_fmt yuv420p sample.mp4
have sample.mov || ff $SRC -c:v h264_videotoolbox -b:v 3M -c:a aac_at -pix_fmt yuv420p sample.mov
have sample.mkv || ff $SRC -c:v h264_videotoolbox -b:v 2M -c:a aac_at -pix_fmt yuv420p sample.mkv
have sample.webm || ff $SRC -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -c:a libvorbis sample.webm
have sample.avi || ff $SRC -c:v mpeg4 -q:v 4 -vtag XVID -c:a libmp3lame -b:a 128k sample.avi
have sample.wmv || ff $SRC -c:v wmv2 -q:v 4 -c:a wmav2 -b:a 128k sample.wmv
have sample.gif || ff -f lavfi -i testsrc2=s=320x240:r=10:d=3 sample.gif
AUDIO=(-f lavfi -i "sine=f=440:d=5" -f lavfi -i "sine=f=660:d=5" -filter_complex "[0][1]amerge=inputs=2[a]" -map "[a]")
have sample.wav || ff $AUDIO -c:a pcm_s16le sample.wav
have sample.mp3 || ff $AUDIO -c:a libmp3lame -b:a 128k sample.mp3
have sample.m4a || ff $AUDIO -c:a aac_at -b:a 128k sample.m4a
have sample.flac || ff $AUDIO -c:a flac sample.flac
have sample.ogg || ff $AUDIO -c:a libvorbis sample.ogg
have sample.opus || ff -f lavfi -i "sine=f=440:d=5" -ac 1 -c:a libopus sample.opus
have sample.aiff || ff $AUDIO -c:a pcm_s16be sample.aiff
have sample.wma || ff $AUDIO -c:a wmav2 -b:a 128k sample.wma

# Documents: one text in each format, made with TextEdit's converter, WheelConvert and plain files.
have sample.md || cat > sample.md <<'MD'
# Quarterly Report

An introduction with **bold**, *italic* and a [link](https://example.com).

## Highlights

- Revenue grew in every region
- Two new products shipped
  - One for photos
1. First step
2. Second step

| Region | Sales |
|---|---|
| North | 120 |
| South | 95 |

> A quotation worth keeping.

```swift
print("Hello")
```

![Test card](sample.png)
MD
have sample.txt || printf 'Plain text notes\n\nGrüße aus Köln — a line with accents.\nA second line.\n' > sample.txt
have doc.html || cat > doc.html <<'HTML'
<html><head><meta charset="utf-8"><title>Sample Document</title></head><body><h1>Sample Document</h1>
<p>First paragraph with <b>bold</b> and <i>italic</i> text.</p><p>Second paragraph, with accents: café, Grüße.</p>
<ul><li>One</li><li>Two</li></ul><table border="1"><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>
HTML
have sample-textutil.docx || textutil -convert docx doc.html -output sample-textutil.docx
have sample.rtf || textutil -convert rtf doc.html -output sample.rtf
have sample.rtfd || textutil -convert rtfd doc.html -output sample.rtfd
have sample.docx || convert sample.md docx sample.docx
have sample.epub || convert sample.md epub sample.epub
have sample.pages || convert sample.docx pages sample.pages
if ! have sample.pdf; then
  printf '# Sample PDF\n\nA one-page document with **bold** text and a [link](https://example.com).\n\n- First item\n- Second item\n' > one.md
  convert one.md pdf sample.pdf; rm -f one.md
fi
have sample-docx.pdf || convert sample-textutil.docx pdf sample-docx.pdf
have sample.textClipping || python3 -I -c "
import plistlib, sys
text = 'A text clipping from Finder.'
plistlib.dump({'UTI-Data': {'public.utf8-plain-text': text.encode(), 'public.utf16-plain-text': text.encode('utf-16')}}, open('sample.textClipping', 'wb'))"

# Slides and spreadsheets: Apache POI (scripts/fixtures/GenOffice.java), then ODS and PDFs from those.
if ! have sample.pptx || ! have sample.xlsx; then
  JDK=/opt/homebrew/opt/openjdk@21/bin
  [[ -x $JDK/javac ]] || { echo "Office fixtures need a JDK: brew install openjdk@21"; exit 1; }
  CP=$(print -l $ROOT/Vendor/build/java/lib/*.jar | grep -v /WheelConvertOffice.jar | tr '\n' ':')
  CLASSES=$(mktemp -d)
  $JDK/javac -nowarn -cp $CP -d $CLASSES $ROOT/scripts/fixtures/GenOffice.java 2>/dev/null
  $JDK/java -cp "$CLASSES:$CP" GenOffice $F
  rm -rf $CLASSES
fi
have sample.ods || convert sample.xlsx ods sample.ods
if ! have sample-multi.pdf; then
  # Three pages of text: a title, bullets and an answer on the last page.
  python3 -I -c "
filler = ['Paragraph %d of the sample document, long enough to fill the page with ordinary sentences about nothing in particular.' % i for i in range(1, 35)]
parts = ['# WheelConvert Test', '', '- First bullet', '- Second bullet', ''] + filler[:17] + ['', '## Page two', ''] + filler[17:] + ['', '## The answer', '', 'The answer is 42.']
open('multi.md', 'w').write('\\n\\n'.join(p for p in parts if p) + '\\n')"
  convert multi.md pdf sample-multi.pdf; rm -f multi.md
fi
have sample.csv || printf 'Region,Sales,Notes\nNorth,120,"Includes, commas"\nSouth,95,Steady\n' > sample.csv
have sample.tsv || printf 'Region\tSales\nNorth\t120\nSouth\t95\n' > sample.tsv

# A PDF of photos (for PDF compression).
if ! have sample-images.pdf; then
  # Grain makes the test card photo-like, so it is stored as JPEG and has room to shrink.
  ff -f lavfi -i testsrc2=s=2400x1600 -vf noise=alls=40:allf=t -frames:v 1 photo.png
  sips -s format jpeg -s formatOptions 98 photo.png --out photo.jpg >/dev/null
  out=$($APP --tool createPDF $F/photo.jpg | sed -n 's/^OUT://p' | head -1)
  mv "$out" sample-images.pdf; rm -f photo.png photo.jpg
fi

# Subtitles and archives.
have sample.srt || printf '1\n00:00:00,500 --> 00:00:02,000\nHello there.\n\n2\n00:00:02,500 --> 00:00:04,000\nSecond line, with <i>italics</i>.\n' > sample.srt
have sample.vtt || printf 'WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nHello there.\n\n00:00:02.500 --> 00:00:04.000\nSecond line.\n' > sample.vtt
if ! have tree; then
  mkdir -p tree/sub && printf 'Top file\n' > tree/a.txt && printf 'Nested file\n' > tree/sub/b.txt && cp sample.png tree/sub/
fi
have sample.zip || (ditto -c -k --keepParent tree sample.zip)
have sample.tar || /usr/bin/tar -cf sample.tar tree
have sample.tar.gz || /usr/bin/tar -czf sample.tar.gz tree
have sample.7z || /usr/bin/tar -c --format 7zip -f sample.7z tree
have single.txt.gz || { printf 'A single compressed file.\n' > single.txt && gzip -9 single.txt; }
rm -f doc.html
echo "Fixtures ready in $F"
