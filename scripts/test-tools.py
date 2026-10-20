"""Runs every file tool through WheelConvert's --tool mode and validates the results."""
import json, os, re, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert")
FFPROBE = os.path.join(ROOT, "Vendor/build/bin/ffprobe")
FIX = os.path.join(ROOT, "build/fixtures")
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
