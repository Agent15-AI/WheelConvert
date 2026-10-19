import os, random, shutil, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DD/Build/Products/Debug/WheelConvert.app/Contents/MacOS/WheelConvert")
FIX = os.path.join(ROOT, "build/fixtures")
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
print(f"{len(bad)} problems")
for b in bad: print(b)
