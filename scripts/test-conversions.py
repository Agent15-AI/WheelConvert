"""Runs every conversion WheelConvert offers for each fixture and validates the results.

usage: python3 -I scripts/test-conversions.py [filter...]
"""
import json, os, re, shutil, subprocess, sys, time, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert")
FFPROBE = os.path.join(ROOT, "Vendor/build/bin/ffprobe")
FIXTURES = os.path.join(ROOT, "build/fixtures")
WORK = os.path.join(ROOT, "build/conversion-test")
filters = sys.argv[1:]
# Image-only PDFs have no text for these targets; a clear error is the right result.
EXPECTED_ERRORS = {("sample-images.pdf", "txt"), ("sample-images.pdf", "xlsx")}

def run(args, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

def pdf_error(path):
    """A PDF header, at least one page box, and no zero-size page boxes."""
    with open(path, "rb") as f: data = f.read()
    if not data.startswith(b"%PDF-"): return "not a PDF"
    boxes = re.findall(rb"/MediaBox\s*\[([^\]]*)\]", data)
    if not boxes:
        # Page dictionaries packed in compressed object streams (PDFBox) can't be read here.
        return None if b"/ObjStm" in data else "no MediaBox"
    for box in boxes:
        nums = [float(x) for x in box.split()]
        if len(nums) != 4 or nums[2] - nums[0] < 1 or nums[3] - nums[1] < 1: return f"bad MediaBox {box.decode()}"
    return None

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
        return pdf_error(path)
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
        if (name, fmt) in EXPECTED_ERRORS and r.returncode != 0:
            results.append((name, fmt, "OK", elapsed)); print(f"OK   {name} -> {fmt} (expected error)"); continue
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

# Batches run several files at once through the job queue: order, failures and cancel must hold.
def batch(case, fmt, names, extra=()):
    d = os.path.join(WORK, case); os.makedirs(d)
    paths = []
    for name in names:
        dst = os.path.join(d, name)
        if name.startswith("broken"):
            with open(dst, "wb") as f: f.write(os.urandom(5000))
        else:
            shutil.copy2(os.path.join(FIXTURES, name.split("@")[-1]), dst.replace("@", ""))
            dst = dst.replace("@", "")
        paths.append(dst)
    r = run([APP, "--batch", fmt] + paths + list(extra), timeout=600)
    lines = r.stdout.splitlines()
    outs = [l[4:] for l in lines if l.startswith("OUT:")]
    fails = [l[5:].split("\t")[0] for l in lines if l.startswith("FAIL:")]
    phase = next((l[6:] for l in lines if l.startswith("PHASE:")), None)
    leftovers = [f for f in os.listdir(d) if f.startswith(".wheelconvert")]
    return d, paths, outs, fails, phase, leftovers

if not filters or any("batch" in f for f in filters):
    names = ["sample.jpg", "broken.png", "sample.png", "sample.heic", "sample.tiff", "sample.bmp", "sample.webp", "copy@sample.jpg"]
    d, paths, outs, fails, phase, leftovers = batch("batch-images", "avif", names)
    good = [p for p in paths if "broken" not in p]
    err = None
    if len(outs) != len(good) or len(set(outs)) != len(outs): err = f"outputs {outs}"
    elif fails != ["broken.png"] or phase != "failed": err = f"failures {fails} phase {phase}"
    elif leftovers: err = f"leftover staging {leftovers}"
    elif any(validate(o, "avif") for o in outs): err = "invalid output"
    elif [os.path.basename(o).split(" ")[0].split(".")[0] for o in outs] != [os.path.basename(p).split(".")[0] for p in good]: err = f"order {outs}"
    results.append(("batch", "avif", "OK" if not err else "FAIL " + err, 0)); print(f"{'OK  ' if not err else 'FAIL'} parallel batch with a broken file {err or ''}")
    clip = os.path.join(FIXTURES, "batch-clip.webm")
    if not os.path.exists(clip):
        run([os.path.join(ROOT, "Vendor/build/bin/ffmpeg"), "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=40", "-f", "lavfi", "-i", "sine=d=40",
             "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "2M", "-c:a", "libopus", clip])
    d, paths, outs, fails, phase, leftovers = batch("batch-cancel", "avi", [f"c{i}@batch-clip.webm" for i in range(5)], ["--cancel-after", "1.5"])
    err = None
    if phase != "cancelled": err = f"phase {phase}"
    elif leftovers: err = f"leftover staging {leftovers}"
    elif sorted(os.listdir(d)) != sorted([os.path.basename(p) for p in paths] + [os.path.basename(o) for o in outs]): err = f"stray files {os.listdir(d)}"
    results.append(("batch", "cancel", "OK" if not err else "FAIL " + err, 0)); print(f"{'OK  ' if not err else 'FAIL'} cancelled parallel batch {err or ''}")

ok = sum(1 for r in results if r[2] == "OK")
print(f"\n{ok}/{len(results)} conversions passed")
for r in results:
    if r[2] != "OK": print("  ", r[0], "->", r[1], ":", r[2])
