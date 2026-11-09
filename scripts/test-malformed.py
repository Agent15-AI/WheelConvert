import os, random, shutil, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert")
FIX = os.path.join(ROOT, "build/fixtures")
subprocess.run(["zsh", os.path.join(ROOT, "scripts/make-fixtures.sh")], check=True, stdout=subprocess.DEVNULL)
WORK = os.path.join(ROOT, "build/fuzz")
shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
random.seed(7)
bad = []
fixtures = sorted(f for f in os.listdir(FIX) if f.startswith("sample") and os.path.isfile(os.path.join(FIX, f)))
for name in fixtures:
    ext = name.split(".", 1)[1]
    data = open(os.path.join(FIX, name), "rb").read()
    variants = {"empty": b"", "random": bytes(random.getrandbits(8) for _ in range(65536)), "truncated": data[: len(data) // 2], "headonly": data[:64]}
    outs = subprocess.run([APP, "--outputs", os.path.join(FIX, name)], capture_output=True, text=True).stdout.split()
    for kind, payload in variants.items():
        for fmt in outs[:3]:
            d = os.path.join(WORK, f"{name}-{kind}-{fmt}"); os.makedirs(d)
            src = os.path.join(d, f"x.{ext}"); open(src, "wb").write(payload)
            try:
                r = subprocess.run([APP, "--convert", src, fmt], capture_output=True, text=True, timeout=120)
                if r.returncode not in (0, 1):
                    bad.append((name, kind, fmt, f"exit {r.returncode}", r.stderr[-300:]))
                leftovers = [f for f in os.listdir(d) if f.startswith(".wheelconvert")]
                if leftovers: bad.append((name, kind, fmt, "leftover staging", ""))
            except subprocess.TimeoutExpired:
                bad.append((name, kind, fmt, "TIMEOUT", ""))
# Smart wheel petals on broken pictures, files and text: a clean error or a result, never a crash, hang or leftover.
SMART = ["palette", "removeBackground", "resize:512", "stripMetadata", "sha256", "md5", "zip"]
for name in [f for f in fixtures if f.split(".", 1)[1] in ("png", "jpg", "heic", "webp", "tiff")]:
    ext = name.split(".", 1)[1]
    data = open(os.path.join(FIX, name), "rb").read()
    variants = {"empty": b"", "random": bytes(random.getrandbits(8) for _ in range(65536)), "truncated": data[: len(data) // 2], "headonly": data[:64]}
    for kind, payload in variants.items():
        for action in SMART:
            d = os.path.join(WORK, f"smart-{name}-{kind}-{action.split(':')[0]}"); os.makedirs(d)
            src = os.path.join(d, f"x.{ext}"); open(src, "wb").write(payload)
            try:
                r = subprocess.run([APP, "--smart", action, src], capture_output=True, text=True, timeout=120)
                if r.returncode not in (0, 1): bad.append((name, kind, action, f"exit {r.returncode}", r.stderr[-300:]))
                if open(src, "rb").read() != payload: bad.append((name, kind, action, "original changed", ""))
                if [f for f in os.listdir(d) if f.startswith(".wheelconvert")]: bad.append((name, kind, action, "leftover staging", ""))
            except subprocess.TimeoutExpired:
                bad.append((name, kind, action, "TIMEOUT", ""))
d = os.path.join(WORK, "smart-text"); os.makedirs(d)
for label, text in {"nul": "a\x00b", "lone surrogate escape": "\udcff".encode("utf-8", "surrogatepass").decode("utf-8", "replace"), "control": "\x1b[31m\x07", "long line": "x" * 2_000_000}.items():
    src = os.path.join(d, label.replace(" ", "-") + ".txt"); open(src, "w", encoding="utf-8").write(text)
    for action in ["makeQRCode", "copyQuoted", "countWords", "saveText", "copyPlain"]:
        try:
            r = subprocess.run([APP, "--smart", action, "text:" + src], capture_output=True, text=True, timeout=120, env={**os.environ, "WHEELCONVERT_RESULTS": d})
            if r.returncode not in (0, 1): bad.append((label, action, f"exit {r.returncode}", r.stderr[-300:]))
        except subprocess.TimeoutExpired:
            bad.append((label, action, "TIMEOUT", ""))
print(f"{len(bad)} problems")
for b in bad: print(b)
