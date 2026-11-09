"""Runs every file tool through WheelConvert's --tool mode and validates the results."""
import json, os, re, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert")
FFPROBE = os.path.join(ROOT, "Vendor/build/bin/ffprobe")
FIX = os.path.join(ROOT, "build/fixtures")
subprocess.run(["zsh", os.path.join(ROOT, "scripts/make-fixtures.sh")], check=True, stdout=subprocess.DEVNULL)
WORK = os.path.join(ROOT, "build/tool-test")
only = sys.argv[1:]

def probe(path):
    r = subprocess.run([FFPROBE, "-v", "error", "-show_format", "-show_streams", "-of", "json", path], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None

def size(path): return os.path.getsize(path)

CASES = [
    # (name, tool, fixtures, options, check)
    ("compress jpg preset", "compress", ["sample.jpg"], {"strength": "strong"}, "smaller"),
    ("compress jpg target", "compress", ["sample.jpg"], {"mode": "fileSize", "targetBytes": 12000}, "<=12000"),
    ("compress png", "compress", ["sample.png"], {"strength": "balanced"}, "smaller"),
    ("compress png target", "compress", ["sample.png"], {"mode": "fileSize", "targetBytes": 15000}, "<=15000"),
    ("compress png no dither", "compress", ["sample.png"], {"strength": "balanced", "dither": False}, "smaller"),
    ("compress png gradient", "compress", ["gradient.png"], {"strength": "strong"}, "smaller"),
    ("compress webp target", "compress", ["sample.webp"], {"mode": "percentage", "reduction": 40}, "smaller"),
    ("compress heic", "compress", ["sample.heic"], {"strength": "strong"}, "smaller"),
    ("compress resize", "compress", ["sample.tiff"], {"strength": "balanced", "maxDimension": 320}, "image"),
    ("compress video preset", "compress", ["sample.mp4"], {"strength": "strong"}, "media"),
    ("compress video target", "compress", ["sample.mov"], {"mode": "fileSize", "targetBytes": 200000}, "<=200000"),
    ("compress webm", "compress", ["sample.webm"], {"strength": "balanced"}, "media"),
    ("compress gif", "compress", ["sample.gif"], {"strength": "strong"}, "smaller"),
    ("compress wav→m4a", "compress", ["sample.wav"], {"strength": "balanced"}, "media"),
    ("compress mp3 target", "compress", ["sample.mp3"], {"mode": "fileSize", "targetBytes": 30000}, "<=30000"),
    ("compress pdf", "compress", ["sample-images.pdf"], {"strength": "balanced"}, "pdf-smaller"),
    ("metadata remove jpg", "removeMetadata", ["sample.jpg"], {"removeAll": True}, "image"),
    ("metadata edit jpg", "removeMetadata", ["sample.jpg"], {"changes": {"Artist": "WheelConvert Test", "Copyright": "CC0"}}, "image"),
    ("metadata remove mp4", "removeMetadata", ["sample.mp4"], {"removeAll": True}, "media"),
    ("metadata edit mp3", "removeMetadata", ["sample.mp3"], {"changes": {"title": "Test Title", "artist": "Tester"}}, "media"),
    ("metadata pdf", "removeMetadata", ["sample.pdf"], {"changes": {"Title": "New Title", "Author": "Me"}}, "pdf"),
    ("edit photo", "editImage", ["sample.jpg"], {"exposure": 20, "contrast": 30, "vibrance": 40, "grain": 30, "vignette": 40, "clarity": 30}, "image"),
    ("annotate", "annotateImage", ["sample.png"], {"items": [
        {"kind": "arrow", "x": 0.1, "y": 0.1, "endX": 0.5, "endY": 0.5},
        {"kind": "rectangle", "x": 0.6, "y": 0.2, "endX": 0.9, "endY": 0.5, "color": "34C759"},
        {"kind": "text", "x": 0.1, "y": 0.7, "endX": 0.6, "endY": 0.8, "text": "Hello"},
        {"kind": "number", "x": 0.8, "y": 0.8, "number": 3},
        {"kind": "magnifier", "x": 0.3, "y": 0.6, "endX": 0.38, "endY": 0.6},
        {"kind": "freehand", "points": [[0.2, 0.2], [0.25, 0.3], [0.3, 0.25]]},
        {"kind": "highlighter", "points": [[0.4, 0.9], [0.7, 0.9]], "color": "FFCC00"}]}, "image"),
    ("background gradient", "frameImage", ["sample.jpg"], {"kind": "gradient", "preset": "ocean", "ratio": "square"}, "image"),
    ("background transparent", "frameImage", ["sample.jpg"], {"kind": "transparent", "cornerRadius": 0.08}, "image"),
    ("crop", "cropImage", ["sample.png"], {"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5, "outputWidth": 300, "outputHeight": 200}, "image"),
    ("redact solid", "redactImage", ["sample.png"], {"regions": [{"x": 0.1, "y": 0.1, "width": 0.3, "height": 0.2}], "style": "solid"}, "image"),
    ("redact blur", "redactImage", ["sample.jpg"], {"regions": [{"x": 0.4, "y": 0.4, "width": 0.3, "height": 0.3}], "style": "blur"}, "image"),
    ("create pdf", "createPDF", ["sample.jpg", "sample.png", "sample.heic"], {}, "pdf"),
    ("collage grid", "createCollage", ["sample.jpg", "sample.png", "sample.heic", "sample.tiff", "sample.bmp"], {"layout": "grid", "cornerRadius": 0.05}, "image"),
    ("collage featured", "createCollage", ["sample.jpg", "sample.png", "sample.heic"], {"layout": "featured", "ratio": "landscape16x9"}, "image"),
    ("collage row", "createCollage", ["sample.jpg", "sample.png"], {"layout": "horizontal"}, "image"),
    ("trim video", "trimVideo", ["sample.mp4"], {"start": 0.5, "end": 2.0}, "duration:1.5"),
    ("trim webm", "trimVideo", ["sample.webm"], {"start": 0.5, "end": 2.0}, "duration:1.5"),
    ("trim gif", "trimVideo", ["sample.gif"], {"start": 0.2, "end": 1.2}, "media"),
    ("crop video", "cropVideo", ["sample.mkv"], {"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}, "media"),
    ("speed 2x", "changeVideoSpeed", ["sample.mp4"], {"factor": 2}, "duration:1.5"),
    ("speed 0.5 no pitch", "changeVideoSpeed", ["sample.avi"], {"factor": 0.5, "preservePitch": False}, "duration:6"),
    ("mute", "muteVideo", ["sample.mov"], {}, "noaudio"),
    ("join", "joinVideos", ["sample.mp4", "sample.webm", "sample.mkv"], {}, "duration:9"),
    ("extract audio aac", "extractAudio", ["sample.mp4"], {}, "audio:aac:m4a"),
    ("extract audio vorbis", "extractAudio", ["sample.webm"], {}, "audio:vorbis:ogg"),
    ("extract audio mp3", "extractAudio", ["sample.avi"], {}, "audio:mp3:mp3"),
    ("extract audio wma", "extractAudio", ["sample.wmv"], {}, "audio:aac:m4a"),
    ("snapshots", "videoSnapshots", ["sample.mp4"], {"times": [0.5, 1.5, 2.5]}, "folder"),
    ("split clips", "splitVideo", ["sample.mp4"], {"points": [1, 2]}, "folder"),
    ("split merged", "splitVideo", ["sample.mp4"], {"points": [1, 2], "removed": [1], "export": "merged"}, "duration:2"),
    ("redact video", "redactVideo", ["sample.mp4"], {"regions": [{"x": 0.1, "y": 0.1, "width": 0.3, "height": 0.3, "start": 0.5, "end": 2}], "style": "blur"}, "media"),
    ("redact video solid", "redactVideo", ["sample.wmv"], {"regions": [{"x": 0.5, "y": 0.5, "width": 0.3, "height": 0.3}]}, "media"),
    ("normalize", "normalizeAudio", ["sample.flac"], {}, "media"),
    ("normalize mp3", "normalizeAudio", ["sample.mp3"], {"targetLoudness": -14}, "media"),
    ("visualizer", "audioToVideo", ["sample.mp3"], {"canvas": "square"}, "media"),
    ("visualizer image", "audioToVideo", ["sample.m4a"], {"style": "staticImage", "imagePath": os.path.join(FIX, "sample.jpg")}, "media"),
    ("trim audio", "trimAudio", ["sample.wav"], {"start": 1, "end": 3}, "duration:2"),
    ("trim audio silence", "trimAudio", ["sample.ogg"], {"autoTrimSilence": True}, "media"),
    ("channels mono", "audioChannels", ["sample.wav"], {"channels": 1}, "channels:1"),
    ("channels stereo", "audioChannels", ["sample.opus"], {"channels": 2, "leftVolume": 0.5}, "channels:2"),
    ("bleep", "redactAudio", ["sample.m4a"], {"ranges": [[1, 2]]}, "media"),
    ("merge pdf", "mergePDF", ["sample.pdf", "sample-docx.pdf"], {}, "pdf"),
    ("organize pdf", "organizePDF", ["sample-multi.pdf"], {"pages": [{"source": 1, "rotation": 90}, {"source": 0}, {"source": 0}]}, "pdf"),
    ("organize equal widths", "organizePDF", ["sample-multi.pdf"], {"pages": [{"source": 0}, {"source": 1, "rotation": 90}], "equalWidths": True}, "pdf"),
    ("split pdf", "splitPDF", ["sample-multi.pdf"], {"mode": "everyPage"}, "folder"),
    ("split pdf ranges", "splitPDF", ["sample-multi.pdf"], {"mode": "ranges", "ranges": "1, 2-"}, "folder"),
    ("extract text image", "extractText", ["text.png"], {}, "text:Invoice 2048"),
    ("extract text scan", "extractText", ["scan.pdf"], {}, "text:Invoice 2048"),
    ("extract text pdf", "extractText", ["sample-docx.pdf"], {}, "text:Second paragraph"),
    ("extract zip", "extractArchive", ["sample.zip"], {}, "folder"),
    ("extract tgz", "extractArchive", ["sample.tar.gz"], {}, "folder"),
    ("extract 7z", "extractArchive", ["sample.7z"], {}, "folder"),
    ("extract gz", "extractArchive", ["single.txt.gz"], {}, "file:single.txt"),
]

# A smooth gradient, where PNG compression without dithering shows bands.
if not os.path.exists(os.path.join(FIX, "gradient.png")):
    subprocess.run([os.path.join(ROOT, "Vendor/build/bin/ffmpeg"), "-v", "error", "-f", "lavfi", "-i", "gradients=s=1200x800:c0=0x1a3399:c1=0xf28c4d:x0=0:y0=0:x1=1200:y1=260:nb_colors=2:d=1",
                    "-frames:v", "1", os.path.join(FIX, "gradient.png")], check=True)

# A picture of text and a scanned PDF of it (no text layer), made with the app's own conversions.
if not os.path.exists(os.path.join(FIX, "scan.pdf")):
    tmp = os.path.join(ROOT, "build/ocr-fixture"); shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
    with open(os.path.join(tmp, "text.md"), "w") as f: f.write("# Invoice 2048\n\nThe quick brown fox jumps over the lazy dog.\n")
    subprocess.run([APP, "--convert", os.path.join(tmp, "text.md"), "pdf"], capture_output=True, check=True)
    subprocess.run([APP, "--convert", os.path.join(tmp, "text.pdf"), "png", "--options", json.dumps({"pdfImageDPI": 150})], capture_output=True, check=True)
    shutil.copy2(os.path.join(tmp, "text.png"), os.path.join(FIX, "text.png"))
    r = subprocess.run([APP, "--tool", "createPDF", os.path.join(tmp, "text.png")], capture_output=True, text=True, check=True)
    shutil.copy2(next(l[4:] for l in r.stdout.splitlines() if l.startswith("OUT:")), os.path.join(FIX, "scan.pdf"))

shutil.rmtree(WORK, ignore_errors=True)
failures = []
for index, (name, tool, files, options, check) in enumerate(CASES):
    if only and not any(o in name for o in only): continue
    case = os.path.join(WORK, f"{index:02d}")
    os.makedirs(case)
    paths = []
    for f in files:
        shutil.copy2(os.path.join(FIX, f), os.path.join(case, f)); paths.append(os.path.join(case, f))
    t = time.time()
    r = subprocess.run([APP, "--tool", tool] + paths + ["--options", json.dumps(options)], capture_output=True, text=True, timeout=600)
    outs = [l[4:] for l in r.stdout.splitlines() if l.startswith("OUT:")]
    err = None
    if r.returncode != 0 or not outs:
        err = (r.stderr.strip().splitlines() or ["no output"])[-1]
    else:
        out = outs[0]
        if check == "smaller":
            if size(out) >= size(paths[0]): err = f"not smaller {size(out)} >= {size(paths[0])}"
        elif check.startswith("<="):
            if size(out) > int(check[2:]): err = f"too big {size(out)}"
        elif check == "image":
            s = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", out], capture_output=True, text=True)
            if "pixelWidth" not in s.stdout: err = "unreadable image"
        elif check in ("pdf", "pdf-smaller"):
            if check == "pdf-smaller" and size(out) >= size(paths[0]) * 0.8: err = f"not much smaller {size(out)} vs {size(paths[0])}"
            with open(out, "rb") as fh: data = fh.read()
            boxes = re.findall(rb"/MediaBox\s*\[([^\]]*)\]", data)
            if err: pass
            elif not data.startswith(b"%PDF-"): err = "not pdf"
            elif not boxes: err = "no MediaBox"
            elif any(len(b.split()) != 4 or float(b.split()[2]) - float(b.split()[0]) < 1 or float(b.split()[3]) - float(b.split()[1]) < 1 for b in boxes): err = "zero-size page"
        elif check == "folder":
            if not os.path.isdir(out) or not os.listdir(out): err = "no folder output"
        elif check.startswith("text:"):
            body = open(out, encoding="utf-8").read() if out.endswith(".txt") else ""
            if check[5:] not in body: err = f"text not found in {body[:120]!r}"
        elif check.startswith("file:"):
            if not os.path.isfile(out) or os.path.basename(out) != check[5:]: err = f"expected file {check[5:]}"
        else:
            p = probe(out)
            if not p: err = "ffprobe failed"
            elif check.startswith("duration:"):
                d = float(p["format"].get("duration", 0)); want = float(check.split(":")[1])
                if abs(d - want) > 0.35: err = f"duration {d:.2f} != {want}"
            elif check.startswith("audio:"):
                _, codec, ext = check.split(":")
                kinds = [(s["codec_type"], s.get("codec_name")) for s in p["streams"]]
                if kinds != [("audio", codec)] or not out.endswith("." + ext): err = f"streams {kinds} in {os.path.basename(out)}"
            elif check == "noaudio":
                if any(s["codec_type"] == "audio" for s in p["streams"]): err = "still has audio"
            elif check.startswith("channels:"):
                ch = [s.get("channels") for s in p["streams"] if s["codec_type"] == "audio"]
                if ch != [int(check.split(":")[1])]: err = f"channels {ch}"
        leftovers = [f for f in os.listdir(case) if f.startswith(".wheelconvert")]
        if leftovers: err = (err or "") + f" leftovers {leftovers}"
    status = "OK  " if not err else "FAIL"
    print(f"{status} {name:28} {time.time() - t:5.1f}s {os.path.basename(outs[0]) if outs else ''} {err or ''}")
    if err: failures.append((name, err))
# Tool previews of formats AVFoundation can't play must start fast, even for hour-long files.
FFMPEG = os.path.join(ROOT, "Vendor/build/bin/ffmpeg")
LONG = os.path.join(FIX, "long")
LONG_CODECS = {
    "mkv": ["-c:v", "h264_videotoolbox", "-b:v", "1M", "-g", "60", "-c:a", "aac_at", "-b:a", "96k"],
    "webm": ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-row-mt", "1", "-b:v", "1M", "-g", "120", "-c:a", "libopus", "-b:a", "96k"],
    "avi": ["-c:v", "mpeg4", "-q:v", "8", "-vtag", "XVID", "-g", "60", "-c:a", "libmp3lame", "-b:a", "96k"],
    "wmv": ["-c:v", "wmv2", "-q:v", "8", "-g", "60", "-c:a", "wmav2", "-b:a", "96k"],
}

def long_fixture(ext):
    """A one-hour 720p file: one minute encoded once, then joined 60 times without re-encoding."""
    path = os.path.join(LONG, f"long.{ext}")
    if os.path.exists(path): return path
    os.makedirs(LONG, exist_ok=True)
    clip = os.path.join(LONG, f"clip.{ext}")
    subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=60", "-f", "lavfi", "-i", "sine=f=440:r=44100:d=60"]
                   + LONG_CODECS[ext] + [clip], check=True)
    listing = os.path.join(LONG, f"list-{ext}.txt")
    with open(listing, "w") as f: f.write(f"file '{clip}'\n" * 60)
    subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", path], check=True)
    return path

PREVIEWS = [(f"preview long {ext}", lambda ext=ext: long_fixture(ext), 3000) for ext in LONG_CODECS]
PREVIEWS += [(f"preview {name}", lambda name=name: os.path.join(FIX, name), 1.5) for name in ["sample.mkv", "sample.webm", "sample.avi", "sample.wmv", "sample.ogg", "sample.opus", "sample.wma"]]
for name, fixture, seek in PREVIEWS:
    if only and not any(o in name for o in only): continue
    r = subprocess.run([APP, "--preview-check", fixture(), str(seek)], capture_output=True, text=True, timeout=120)
    times = dict(l.split(":", 1) for l in r.stdout.splitlines() if l.startswith(("PLAYING:", "SEEKED:")))
    err = None
    if r.returncode != 0 or len(times) != 2: err = (r.stderr.strip().splitlines() or ["no output"])[-1]
    # Includes a quarter second of playback; the target is "playing within about two seconds".
    elif float(times["PLAYING"]) > 2.5 or float(times["SEEKED"]) > 2.5: err = f"too slow {times}"
    print(f"{'OK  ' if not err else 'FAIL'} {name:28} start {times.get('PLAYING', '-')}s, seek {times.get('SEEKED', '-')}s {err or ''}")
    if err: failures.append((name, err))

# Default presets, run headless through the job queue (--preset).
def big_fixture(name):
    """Large inputs the presets act on: a 3000 px photo and a ~35 MB 1080p video."""
    path = os.path.join(FIX, name)
    if os.path.exists(path): return path
    if name == "big.mov":
        subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=30:d=30", "-f", "lavfi", "-i", "sine=d=30",
                        "-c:v", "h264_videotoolbox", "-b:v", "9M", "-c:a", "aac_at", path], check=True)
    else:
        png = os.path.join(FIX, "big.png")
        if not os.path.exists(png):
            subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=3000x2000:d=1", "-frames:v", "1", png], check=True)
        if name == "big.jpg": subprocess.run(["sips", "-s", "format", "jpeg", png, "--out", path], capture_output=True, check=True)
    return path

PRESET_CASES = [
    ("preset instagram", "Instagram 1080 px JPG", "big.jpg", "jpg", lambda out: width(out) == 1080),
    ("preset web", "Web-ready WebP (1600 px)", "big.png", "webp", lambda out: width(out) == 1600),
    ("preset email", "Email-size MP4 (under 25 MB)", "big.mov", "mp4", lambda out: size(out) <= 24_000_000),
    ("preset podcast", "Podcast MP3 (128 kbps)", "sample.wav", "mp3", lambda out: abs(int(probe(out)["format"]["bit_rate"]) - 128_000) < 12_000),
    ("preset print", "PDF pages for print (300 DPI PNG)", "sample.pdf", "png", lambda out: width(out) > 2000),
]

def width(path):
    m = re.search(r"pixelWidth: (\d+)", subprocess.run(["sips", "-g", "pixelWidth", path], capture_output=True, text=True).stdout)
    return int(m.group(1)) if m else 0

for name, preset, fixture, ext, check in PRESET_CASES:
    if only and not any(o in name for o in only): continue
    case = os.path.join(WORK, name.replace(" ", "-")); os.makedirs(case)
    src = os.path.join(case, fixture); shutil.copy2(big_fixture(fixture) if fixture.startswith("big") else os.path.join(FIX, fixture), src)
    t = time.time()
    r = subprocess.run([APP, "--preset", preset, src], capture_output=True, text=True, timeout=600)
    outs = [l[4:] for l in r.stdout.splitlines() if l.startswith("OUT:")]
    err = None
    if r.returncode != 0 or not outs: err = (r.stderr.strip().splitlines() or r.stdout.strip().splitlines() or ["no output"])[-1]
    elif not outs[0].endswith("." + ext): err = f"wrong format {outs[0]}"
    elif not check(outs[0]): err = f"check failed for {os.path.basename(outs[0])}"
    elif [f for f in os.listdir(case) if f.startswith(".wheelconvert")]: err = "leftover staging"
    print(f"{'OK  ' if not err else 'FAIL'} {name:28} {time.time() - t:5.1f}s {os.path.basename(outs[0]) if outs else ''} {err or ''}")
    if err: failures.append((name, err))

# Shortcuts actions (Convert File, Compress File, Apply Preset), run through --intent.
INTENT_CASES = [
    ("intent convert", ["convert", "png", "sample.jpg"], lambda outs: outs == ["OUT:sample.png"]),
    ("intent convert pages", ["convert", "jpg", "sample-multi.pdf"], lambda outs: len(outs) == 3 and all(o.endswith(".jpg") for o in outs)),
    ("intent compress", ["compress", "strong", "sample.mov"], lambda outs: outs == ["OUT:sample Compressed.mov"]),
    ("intent compress target", ["compress", "balanced:0.2", "sample.mov"], lambda outs: len(outs) == 1),
    ("intent preset", ["preset", "Podcast MP3 (128 kbps)", "sample.mov"], lambda outs: outs == ["OUT:sample.mp3"]),
    ("intent data input", ["convert", "webp", "data:sample.jpg"], lambda outs: len(outs) == 1 and outs[0].startswith("DATA:sample.webp\t")),
]
for name, (action, arg, *files), check in INTENT_CASES:
    if only and not any(o in name for o in only): continue
    case = os.path.join(WORK, name.replace(" ", "-")); os.makedirs(case)
    paths = []
    for f in files:
        bare = f.split(":", 1)[-1]
        shutil.copy2(os.path.join(FIX, bare), os.path.join(case, bare))
        paths.append(("data:" if f.startswith("data:") else "") + os.path.join(case, bare))
    r = subprocess.run([APP, "--intent", action, arg] + paths, capture_output=True, text=True, timeout=300)
    outs = [("OUT:" + os.path.basename(l[4:])) if l.startswith("OUT:") else l for l in r.stdout.splitlines() if l.startswith(("OUT:", "DATA:"))]
    err = None if r.returncode == 0 and check(outs) else f"{outs} {r.stderr.strip()[-200:]}"
    if not err and [f for f in os.listdir(case) if f.startswith(".wheelconvert")]: err = "leftover staging"
    print(f"{'OK  ' if not err else 'FAIL'} {name:28} {err or ''}")
    if err: failures.append((name, err))
r = subprocess.run([APP, "--intent", "compress", "balanced", os.path.join(FIX, "sample.pdf"), os.path.join(FIX, "sample.jpg")], capture_output=True, text=True)
err = None if r.returncode == 1 and "one kind at a time" in r.stderr else f"mixed kinds: {r.stderr.strip()}"
print(f"{'OK  ' if not err else 'FAIL'} {'intent mixed kinds error':28} {err or ''}")
if err: failures.append(("intent mixed kinds", err))

# Smart wheel petals through --smart. Clipboard text comes back as COPY:<json> lines (the real clipboard is never
# touched); results of text and links go to WHEELCONVERT_RESULTS. Every case also checks for leftover staging files.
def png_alpha(path):
    """Fraction of fully transparent pixels in an 8-bit RGBA PNG (decoded here, no dependencies)."""
    import struct, zlib
    data = open(path, "rb").read(); i = 8; idat = b""; w = h = ctype = None
    while i < len(data):
        n, kind = struct.unpack(">I4s", data[i:i + 8]); body = data[i + 8:i + 8 + n]; i += 12 + n
        if kind == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT": idat += body
    if ctype != 6: return None
    raw = zlib.decompress(idat); stride = w * 4; prev = bytearray(stride); clear = 0; pos = 0
    for _ in range(h):
        f = raw[pos]; row = bytearray(raw[pos + 1:pos + 1 + stride]); pos += 1 + stride
        for x in range(stride):
            a = row[x - 4] if x >= 4 else 0; b = prev[x]; c = prev[x - 4] if x >= 4 else 0
            if f == 1: row[x] = (row[x] + a) & 255
            elif f == 2: row[x] = (row[x] + b) & 255
            elif f == 3: row[x] = (row[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        clear += sum(1 for x in range(3, stride, 4) if row[x] == 0); prev = row
    return clear / (w * h)

def copied(lines): return [json.loads(l[5:]) for l in lines if l.startswith("COPY:")]
def items(*inputs): return subprocess.run([APP, "--smart-items", *inputs], capture_output=True, text=True).stdout.split()

SMART = os.path.join(WORK, "smart"); os.makedirs(SMART, exist_ok=True)
def sfile(name, data=b""):
    path = os.path.join(SMART, name)
    with open(path, "wb") as f: f.write(data if isinstance(data, bytes) else data.encode())
    return path
def sfix(name):
    dst = os.path.join(SMART, name); shutil.copy2(os.path.join(FIX, name), dst); return dst

weird = ["-rf.txt", "it's \"quoted\".txt", "new\nline.txt", "naïve 日本 🚀.txt", "$(touch pwned).txt", "`id` back.txt"]
for name in weird: sfile(name, name)
os.makedirs(os.path.join(SMART, "folder", "sub"), exist_ok=True); sfile("folder/sub/x.txt", "x"); sfile("folder/.DS_Store", "junk")
many = [sfile(f"many-{i:02d}.bin", str(i)) for i in range(60)]
cjk = sfile("cjk.txt", "東京 مرحبا שלום 👋🏽 Ünïcödé — mixed RTL and CJK")
huge = sfile("huge.txt", ("All work and no play makes a dull day. " * 130000))
empty_text = sfile("empty.txt", " \n\t ")
html = sfile("rich.html", "<p>Some <b>bold</b> and <a href=\"https://example.com\">a link</a></p><ul><li>One</li></ul>")
corrupt = sfile("corrupt.png", b"\x89PNG\r\n\x1a\nnot really a picture")
readonly = os.path.join(SMART, "readonly"); os.makedirs(readonly, exist_ok=True); sfile("readonly/r.txt", "read only"); os.chmod(readonly, 0o555)
gps = sfix("sample.jpg"); gps_jpg = os.path.join(SMART, "gps.jpg"); os.rename(gps, gps_jpg)
subprocess.run([os.path.join(ROOT, "Vendor/build/ExifTool/exiftool"), "-q", "-overwrite_original", "-GPSLatitude=1.29", "-GPSLatitudeRef=N", "-GPSLongitude=103.85", "-GPSLongitudeRef=E", gps_jpg], check=True)
pristine = {p: open(p, "rb").read() for p in [corrupt, gps_jpg, huge]}

def exif(path): return subprocess.run([os.path.join(ROOT, "Vendor/build/ExifTool/exiftool"), "-s", "-GPS:all", "-Make", path], capture_output=True, text=True).stdout
def unzip_names(path):
    import zipfile
    import unicodedata  # macOS hands file names over decomposed (NFD); compare what people see
    with zipfile.ZipFile(path) as z: return sorted(unicodedata.normalize("NFC", i.filename) for i in z.infolist() if i.flag_bits & 0x800 or i.filename.isascii())

URL_CASES = [("https://example.com/page?utm_source=news&id=7&fbclid=XYZ", "https://example.com/page?id=7"),
             ("https://www.example.org/a/b?gclid=1&UTM_MEDIUM=x&q=caf%C3%A9#top", "https://www.example.org/a/b?q=caf%C3%A9#top"),
             ("https://shop.example/item?utm_campaign=c&utm_content=d", "https://shop.example/item"),
             ("https://example.com/?keep=1", "https://example.com/?keep=1")]

SMART_CASES = [
    # (name, arguments, check(stdout lines, stderr) -> error or None)
    ("smart palette exact", ["palette", sfix("smart-palette.png")], lambda o, e: None if copied(o) == ["#FF0000\n#0000FF\n#00FF00"] else f"{copied(o)}"),
    ("smart qr decode", None, None),
    ("smart remove background", ["removeBackground", sfix("smart-subject.png")],
     lambda o, e: (lambda f: None if f is not None and 0.05 < f < 0.95 else f"transparent fraction {f}")(png_alpha(outs_of(o)[0])) if outs_of(o) else e),
    ("smart strip location", ["stripMetadata", gps_jpg], lambda o, e: None if outs_of(o) and "GPSLatitude" not in exif(outs_of(o)[0]) and "GPSLatitude" in exif(gps_jpg) else f"{outs_of(o)} {e}"),
    ("smart resize 1080", ["resize:1080", shutil.copy2(big_fixture("big.png"), os.path.join(SMART, "big.png")) and os.path.join(SMART, "big.png")],
     lambda o, e: None if outs_of(o) and max(width(outs_of(o)[0]), height(outs_of(o)[0])) == 1080 else f"{outs_of(o)} {e}"),
    ("smart resize never enlarges", ["resize:3840", sfix("sample.png")], lambda o, e: None if not outs_of(o) and "px or smaller" in "\n".join(o) else f"{o}"),
    ("smart sha256 known", ["sha256", sfix("hash-abc.txt")], lambda o, e: None if copied(o) == ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"] else f"{copied(o)}"),
    ("smart sha256 empty file", ["sha256", sfix("hash-empty.bin")], lambda o, e: None if copied(o) == ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"] else f"{copied(o)}"),
    ("smart md5 known", ["md5", sfix("hash-abc.txt")], lambda o, e: None if copied(o) == ["900150983cd24fb0d6963f7d28e17f72"] else f"{copied(o)}"),
    ("smart md5 many files", ["md5", *many], lambda o, e: None if len(re.findall(r"^[0-9a-f]{32}  many-", "".join(copied(o)), re.M)) == 60 else f"{o[:2]}"),
    ("smart hash odd names", ["sha256", *[os.path.join(SMART, n) for n in weird]],
     lambda o, e: None if len(re.findall(r"^[0-9a-f]{64}  ", "".join(copied(o)), re.M)) == len(weird) else f"{copied(o)}"),
    ("smart verify match", ["verifyChecksum:SHA256 (abc) = BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", sfix("hash-abc.txt")], lambda o, e: None if "MATCH" in o else f"{o} {e}"),
    ("smart verify mismatch", ["verifyChecksum:900150983cd24fb0d6963f7d28e17f73", sfix("hash-abc.txt")], lambda o, e: None if any(l.startswith("MISMATCH:900150983cd24fb0d6963f7d28e17f72") for l in o) else f"{o}"),
    ("smart zip odd names", ["zip", *[os.path.join(SMART, n) for n in weird]],
     lambda o, e: zip_check(o, e)),
    ("smart zip folder", ["zip", os.path.join(SMART, "folder")],
     lambda o, e: None if outs_of(o) and unzip_names(outs_of(o)[0]) == ["folder/", "folder/sub/", "folder/sub/x.txt"] else f"{outs_of(o) and unzip_names(outs_of(o)[0])} {e}"),
    ("smart zip read-only folder", ["zip", os.path.join(readonly, "r.txt")], lambda o, e: None if outs_of(o) and os.path.dirname(outs_of(o)[0]) == RESULTS else f"{o} {e}"),
    ("smart qr cjk round trip", ["makeQRCode", "text:" + cjk], lambda o, e: qr_check(o, open(cjk, encoding="utf-8").read())),
    ("smart qr link", ["makeQRCode", "link:https://example.com/a?b=c"], lambda o, e: qr_check(o, "https://example.com/a?b=c")),
    ("smart count cjk", ["countWords", "text:" + cjk], lambda o, e: None if [l for l in o if l.startswith("COUNT:")] else f"{o}"),
    ("smart count huge", ["countWords", "text:" + huge], lambda o, e: None if "COUNT:1170000 5070000 1" in o else f"{o}"),
    ("smart quote cjk", ["copyQuoted", "text:" + cjk], lambda o, e: None if copied(o) == ["> " + open(cjk, encoding="utf-8").read()] else f"{copied(o)}"),
    ("smart markdown", ["copyMarkdown", "html:" + html], lambda o, e: None if copied(o) == ["Some **bold** and [a link](https://example.com)\n\n- One"] else f"{copied(o)}"),
    ("smart save text cjk", ["saveText", "text:" + cjk], lambda o, e: None if outs_of(o) and outs_of(o)[0].endswith(".txt") and open(outs_of(o)[0], encoding="utf-8").read() == open(cjk, encoding="utf-8").read() + "\n" else f"{o}"),
    ("smart save huge text", ["saveText", "text:" + huge], lambda o, e: None if outs_of(o) and os.path.getsize(outs_of(o)[0]) == os.path.getsize(huge) + 1 else f"{o}"),
    ("smart save markdown", ["saveText", "html:" + html], lambda o, e: None if outs_of(o) and outs_of(o)[0].endswith(".md") else f"{o}"),
    ("smart save link", ["saveLink", "link:https://example.com/x?y=1"], lambda o, e: None if outs_of(o) and plist(outs_of(o)[0]).get("URL") == "https://example.com/x?y=1" else f"{o}"),
    ("smart speak muted", ["speak", "text:" + cjk], lambda o, e: None if "FAIL" not in "".join(o) and not e.strip() else f"{o} {e}"),
    ("smart corrupt palette", ["palette", corrupt], lambda o, e: None if "ERROR:" in e and not copied(o) else f"{o} {e}"),
    ("smart corrupt background", ["removeBackground", corrupt], lambda o, e: None if any(l.startswith("FAIL:") for l in o) and not outs_of(o) else f"{o} {e}"),
    ("smart corrupt resize", ["resize:512", corrupt], lambda o, e: None if any(l.startswith("FAIL:") for l in o) and not outs_of(o) else f"{o} {e}"),
] + [(f"smart clean link {i}", ["cleanLink", "link:" + src], lambda o, e, want=want: None if copied(o) == [want] else f"{copied(o)}") for i, (src, want) in enumerate(URL_CASES)]

RESULTS = os.path.join(SMART, "results"); os.makedirs(RESULTS, exist_ok=True)
def outs_of(lines): return [l[4:] for l in lines if l.startswith("OUT:")]
def height(path):
    m = re.search(r"pixelHeight: (\d+)", subprocess.run(["sips", "-g", "pixelHeight", path], capture_output=True, text=True).stdout)
    return int(m.group(1)) if m else 0
def plist(path):
    import plistlib
    return plistlib.load(open(path, "rb"))
def qr_check(lines, want):
    if not outs_of(lines): return f"no QR {lines}"
    r = subprocess.run([APP, "--tool", "readQRCode", outs_of(lines)[0]], capture_output=True, text=True)
    got = [l.split("\t", 1)[1] for l in r.stdout.splitlines() if l.startswith("CODE:")]
    return None if got == [want] else f"decoded {got!r}"
def zip_check(lines, err):
    if not outs_of(lines): return f"no zip {lines} {err}"
    names = unzip_names(outs_of(lines)[0])
    return None if names == sorted(weird) else f"zip names {names}"

for name, args, check in SMART_CASES:
    if only and not any(o in name for o in only): continue
    if args is None:  # the QR fixture decodes to its known text (made by make-fixtures.sh)
        r = subprocess.run([APP, "--tool", "readQRCode", os.path.join(FIX, "smart-qr.png")], capture_output=True, text=True)
        err = None if "CODE:smart-qr.png\tWheelConvert QR 42" in r.stdout else r.stdout + r.stderr
    else:
        t = time.time()
        r = subprocess.run([APP, "--smart", *args], capture_output=True, text=True, timeout=300, env={**os.environ, "WHEELCONVERT_RESULTS": RESULTS, "WHEELCONVERT_MUTE": "1"})
        lines = r.stdout.splitlines()
        err = f"exit {r.returncode}" if r.returncode not in (0, 1) else check(lines, r.stderr)
    for folder in [SMART, RESULTS]:
        if [f for f in os.listdir(folder) if f.startswith(".wheelconvert")]: err = (err or "") + " leftover staging"
    print(f"{'OK  ' if not err else 'FAIL'} {name:28} {err or ''}")
    if err: failures.append((name, err))

# Availability: only petals that work for the content (and on this macOS) appear.
AVAILABILITY = [
    ("smart items empty text", items("text:" + empty_text) == [], "no petals for whitespace"),
    ("smart items huge text", "smart.makeQRCode" not in items("text:" + huge) and "smart.summarize" not in items("text:" + huge) and "smart.saveText" in items("text:" + huge), "huge text: no QR or summary"),
    ("smart items folder", items(os.path.join(SMART, "folder")) == ["smart.reveal", "action.copyPath", "smart.zip"], "folder petals"),
    ("smart items 0-byte", items(sfix("hash-empty.bin"))[:3] == ["smart.sha256", "smart.md5", "smart.verifyChecksum"], "0-byte file petals"),
    ("smart items link", items("link:https://example.com")[:3] == ["smart.cleanLink", "smart.makeQRCode", "smart.saveLink"], "link petals"),
    ("smart items picture", "smart.palette" in items(sfix("smart-palette.png")) and "tool.extractText" in items(sfix("smart-palette.png")), "picture petals"),
]
for name, ok, what in AVAILABILITY:
    if only and not any(o in name for o in only): continue
    print(f"{'OK  ' if ok else 'FAIL'} {name:28} {'' if ok else what}")
    if not ok: failures.append((name, what))

# On-device language features run only where this Mac offers them (macOS 26, languages installed, Apple Intelligence on).
german = sfile("german.txt", "Guten Morgen. Das Wetter ist heute sehr schön und wir gehen später zusammen in den Park.")
story = sfile("story.txt", " ".join(["The committee met on Tuesday to review the budget for the new library. After a long discussion, members agreed to fund the building but postponed a decision on staffing until spring."] * 2))
for name, action, source in [("smart translate", "translate", german), ("smart summarize", "summarize", story)]:
    if only and not any(o in name for o in only): continue
    if f"smart.{action}" not in items("text:" + source):
        print(f"SKIP {name:28} not offered on this Mac"); continue
    r = subprocess.run([APP, "--smart", action, "text:" + source], capture_output=True, text=True, timeout=120)
    out = copied(r.stdout.splitlines())
    err = None if out and out[0].strip() and out[0] != open(source).read() else f"{out} {r.stderr.strip()[-200:]}"
    print(f"{'OK  ' if not err else 'FAIL'} {name:28} {(out[0][:60] if out else '') if not err else err}")
    if err: failures.append((name, err))
for path, data in pristine.items():
    if open(path, "rb").read() != data: failures.append(("smart originals untouched", path))
os.chmod(readonly, 0o755)

# Localization: every string is translated (or marked as not needing it) with the same placeholders,
# and the app answers in the language it's asked for.
if not only or any("locali" in o for o in only):
    catalog = json.load(open(os.path.join(ROOT, "WheelConvert/Resources/Localizable.xcstrings")))["strings"]
    spec = re.compile(r"%(?:\d+\$)?(lld|@|lf|d)")
    gaps = []
    for key, entry in catalog.items():
        if entry.get("shouldTranslate") is False: continue
        locs = entry.get("localizations", {})
        source = locs.get("en", {}).get("stringUnit", {}).get("value", key)
        for lang in ["de", "fr", "es", "ja", "zh-Hans"]:
            value = locs.get(lang, {}).get("stringUnit", {}).get("value")
            if value is None or sorted(spec.findall(value)) != sorted(spec.findall(source)): gaps.append(f"{lang}: {key[:40]}")
    r = subprocess.run([APP, "-AppleLanguages", "(de)", "--intent", "compress", "balanced", os.path.join(FIX, "sample.pdf"), os.path.join(FIX, "sample.jpg")],
                       capture_output=True, text=True)
    err = f"{len(gaps)} untranslated or mismatched: {gaps[:5]}" if gaps else None
    if not err and "jeweils einer Art auf einmal" not in r.stderr: err = f"German error message missing: {r.stderr.strip()}"
    print(f"{'OK  ' if not err else 'FAIL'} {'localization':28} {len(catalog)} strings {err or ''}")
    if err: failures.append(("localization", err))

# Watch folder: new files run through a preset once complete; hidden, partial and own results are skipped.
if not only or any("watch" in o for o in only):
    folder = os.path.join(WORK, "watch"); os.makedirs(folder)
    t = time.time()
    proc = subprocess.Popen([APP, "--watch", folder, "Instagram 1080 px JPG", "16"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    proc.stdout.readline()  # WATCHING
    photo = big_fixture("big.jpg")
    shutil.copy2(photo, os.path.join(folder, "a.jpg"))
    shutil.copy2(photo, os.path.join(folder, ".hidden.jpg"))
    shutil.copy2(photo, os.path.join(folder, "c.jpg.crdownload"))
    with open(os.path.join(folder, "notes.txt"), "w") as f: f.write("not a photo")
    data = open(photo, "rb").read()
    with open(os.path.join(folder, "slow.jpg"), "wb") as f:  # written in two halves, 2.5 s apart
        f.write(data[: len(data) // 2]); f.flush(); time.sleep(2.5); f.write(data[len(data) // 2:])
    out, errs = proc.communicate(timeout=120)
    outs = sorted(os.path.basename(l[4:]) for l in out.splitlines() if l.startswith("OUT:"))
    fails = [l for l in out.splitlines() if l.startswith("FAIL:")]
    err = None
    if fails: err = f"a half-written file was processed: {fails}"
    elif outs != ["a 2.jpg", "slow 2.jpg"]: err = f"outputs {outs} {errs.strip()[-200:]}"
    elif any(width(os.path.join(folder, o)) != 1080 for o in outs): err = "an output isn't 1080 px wide"
    elif sorted(os.listdir(folder)) != sorted([".hidden.jpg", "a.jpg", "a 2.jpg", "c.jpg.crdownload", "notes.txt", "slow.jpg", "slow 2.jpg"]): err = f"files {sorted(os.listdir(folder))}"
    print(f"{'OK  ' if not err else 'FAIL'} {'watch folder':28} {time.time() - t:5.1f}s {err or ''}")
    if err: failures.append(("watch folder", err))

print(f"\n{len(failures)} failures")
for f in failures: print("  ", f)
