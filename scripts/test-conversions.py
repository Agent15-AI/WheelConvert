"""Runs every conversion WheelConvert offers for each fixture and validates the results.

usage: python3 -I scripts/test-conversions.py [filter...]
"""
import json, os, shutil, subprocess, sys, time, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert")
FFPROBE = os.path.join(ROOT, "Vendor/build/bin/ffprobe")
FIXTURES = os.path.join(ROOT, "build/fixtures")
WORK = os.path.join(ROOT, "build/conversion-test")
filters = sys.argv[1:]

def run(args, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

def validate(path, fmt):
    if os.path.isdir(path):
        files = [os.path.join(path, f) for f in sorted(os.listdir(path))]
        if not files: return "empty folder"
        for f in files:
            err = validate(f, fmt)
            if err: return f"{os.path.basename(f)}: {err}"
        return None
    if os.path.getsize(path) == 0: return "empty file"
    if fmt in ("mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"):
        r = run([FFPROBE, "-v", "error", "-show_streams", "-of", "json", path])
        if r.returncode != 0: return "ffprobe failed: " + r.stderr[:200]
        streams = json.loads(r.stdout).get("streams", [])
        if not streams: return "no streams"
        return None
    if fmt in ("jpg", "png", "heic", "tiff", "bmp", "avif", "webp"):
        r = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path])
        if r.returncode != 0 or "pixelWidth" not in r.stdout: return "sips cannot read: " + r.stderr[:200]
        return None
    if fmt == "pdf":
        r = run(["python3", "-I", "-c", "import sys,subprocess;print(subprocess.run(['mdls','-raw','-name','kMDItemNumberOfPages',sys.argv[1]],capture_output=True,text=True).stdout)", path])
        with open(path, "rb") as f: head = f.read(5)
        if head != b"%PDF-": return "not a PDF"
        return None
    if fmt in ("docx", "pptx", "xlsx", "ods", "epub", "zip", "pages"):
        try:
            with zipfile.ZipFile(path) as z:
                bad = z.testzip()
                if bad: return "corrupt member " + bad
                names = z.namelist()
                need = {"docx": "word/document.xml", "pptx": "ppt/presentation.xml", "xlsx": "xl/workbook.xml", "ods": "content.xml", "epub": "META-INF/container.xml", "pages": "Index/Document.iwa"}.get(fmt)
                if need and need not in names: return f"missing {need}"
                if fmt == "epub" and names[0] != "mimetype": return "mimetype not first"
        except zipfile.BadZipFile as e:
            return f"bad zip: {e}"
        return None
    if fmt in ("tar", "gzip"):
        r = run(["/usr/bin/tar", "-tf", path])
        return None if r.returncode == 0 and r.stdout.strip() else "tar cannot list: " + r.stderr[:200]
    if fmt in ("txt", "md", "html", "srt", "vtt", "csv", "tsv"):
        with open(path, encoding="utf-8") as f: text = f.read()
        return None if text.strip() else "no text"
    return None

shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
results = []
fixtures = sorted(f for f in os.listdir(FIXTURES) if f.startswith(("sample", "single")) and not f.startswith("."))
for name in fixtures:
    if filters and not any(x in name for x in filters): continue
    src = os.path.join(FIXTURES, name)
    outputs = run([APP, "--outputs", src]).stdout.split()
    for fmt in outputs:
        case = os.path.join(WORK, f"{name}__to_{fmt}")
        os.makedirs(case)
        dst = os.path.join(case, name)
        if os.path.isdir(src): shutil.copytree(src, dst)
        else: shutil.copy2(src, dst)
        t = time.time()
        try:
            r = run([APP, "--convert", dst, fmt], timeout=600)
        except subprocess.TimeoutExpired:
            results.append((name, fmt, "TIMEOUT", 600)); print(f"TIMEOUT {name} -> {fmt}"); continue
        elapsed = time.time() - t
        outs = [l[4:] for l in r.stdout.splitlines() if l.startswith("OUT:")]
        if r.returncode != 0 or not outs:
            msg = (r.stderr.strip().splitlines() or ["(no message)"])[-1]
            results.append((name, fmt, "FAIL " + msg, elapsed)); print(f"FAIL {name} -> {fmt}: {msg}")
            continue
        err = None
        for o in outs:
            err = validate(o, fmt) or err
        leftovers = [f for f in os.listdir(case) if f.startswith(".wheelconvert")]
        if leftovers: err = (err or "") + f" leftover staging {leftovers}"
        status = "OK" if not err else "INVALID " + err
        results.append((name, fmt, status, elapsed))
        print(f"{status:4} {name} -> {fmt} ({elapsed:.1f}s) {[os.path.basename(o) for o in outs]}")

ok = sum(1 for r in results if r[2] == "OK")
print(f"\n{ok}/{len(results)} conversions passed")
for r in results:
    if r[2] != "OK": print("  ", r[0], "->", r[1], ":", r[2])
