"""Runs every file tool through WheelConvert's --tool mode and validates the results."""
import json, os, shutil, subprocess, sys, time

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
    ("compress webp target", "compress", ["sample.webp"], {"mode": "percentage", "reduction": 40}, "smaller"),
    ("compress heic", "compress", ["sample.heic"], {"strength": "strong"}, "smaller"),
    ("compress resize", "compress", ["sample.tiff"], {"strength": "balanced", "maxDimension": 320}, "image"),
    ("compress video preset", "compress", ["sample.mp4"], {"strength": "strong"}, "media"),
    ("compress video target", "compress", ["sample.mov"], {"mode": "fileSize", "targetBytes": 200000}, "<=200000"),
    ("compress webm", "compress", ["sample.webm"], {"strength": "balanced"}, "media"),
    ("compress gif", "compress", ["sample.gif"], {"strength": "strong"}, "smaller"),
    ("compress wav→m4a", "compress", ["sample.wav"], {"strength": "balanced"}, "media"),
    ("compress mp3 target", "compress", ["sample.mp3"], {"mode": "fileSize", "targetBytes": 30000}, "<=30000"),
    ("compress pdf", "compress", ["sample.pdf"], {"strength": "strong"}, "pdf"),
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
    ("extract zip", "extractArchive", ["sample.zip"], {}, "folder"),
    ("extract tgz", "extractArchive", ["sample.tar.gz"], {}, "folder"),
    ("extract gz", "extractArchive", ["single.txt.gz"], {}, "folder"),
]

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
        elif check == "pdf":
            with open(out, "rb") as fh:
                if fh.read(5) != b"%PDF-": err = "not pdf"
        elif check == "folder":
            if not os.path.isdir(out) or not os.listdir(out): err = "no folder output"
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
print(f"\n{len(failures)} failures")
for f in failures: print("  ", f)
