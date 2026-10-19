#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends   ca-certificates build-essential pkg-config zstd file   python3 python3-dev python3-venv python3-pip   libcairo2-dev libpango1.0-dev   ffmpeg dvisvgm texlive-latex-base texlive-latex-extra   fonts-dejavu-core
rm -rf /var/lib/apt/lists/*

python3 --version
python3 - <<'PY'
import sys
assert sys.version_info[:2] == (3, 13), sys.version
print("PYTHON_ABI_OK", sys.version)
PY

WORK=/work
ROOT="$WORK/stage/manim-ce-runtime"
PYROOT="$ROOT/python"
rm -rf "$WORK/stage" "$WORK/out"
mkdir -p "$PYROOT" "$ROOT/bin" "$ROOT/libexec" "$ROOT/lib/dvisvgm" "$WORK/out"

python3 -m venv /tmp/build-venv
. /tmp/build-venv/bin/activate
python -m pip install -U pip setuptools wheel "Cython<3.1"

# Install the complete Python dependency closure. PyAV's official Linux wheel is
# intentionally kept, making media bindings self-contained. ManimPango/PyCairo
# are compiled against Debian 13's Pango/Cairo ABI.
python -m pip install --target "$PYROOT"   "av==15.1.0"   "ManimPango==0.7.0"   "manim==0.22.0"

# Bundle dvisvgm because the target sandbox has TeX Live but lacks dvisvgm.
cp /usr/bin/dvisvgm "$ROOT/libexec/dvisvgm.real"
chmod +x "$ROOT/libexec/dvisvgm.real"

# ldd output already contains the transitive dynamic dependency closure.
ldd /usr/bin/dvisvgm | awk '/=> \/.*\(/ {print $3}' | sort -u | while read -r lib; do
  base="$(basename "$lib")"
  case "$base" in
    libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libgcc_s.so.*|libstdc++.so.*|ld-linux-*.so.*)
      continue
      ;;
  esac
  cp -L "$lib" "$ROOT/lib/dvisvgm/$base"
done

cat > "$ROOT/bin/python" <<'SH'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export PYTHONPATH="$ROOT/python${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$ROOT/bin:$PATH"
exec python3 "$@"
SH

cat > "$ROOT/bin/manim" <<'SH'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export PYTHONPATH="$ROOT/python${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$ROOT/bin:$PATH"
exec python3 -m manim "$@"
SH

cat > "$ROOT/bin/dvisvgm" <<'SH'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export LD_LIBRARY_PATH="$ROOT/lib/dvisvgm${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$ROOT/libexec/dvisvgm.real" "$@"
SH

chmod +x "$ROOT/bin/python" "$ROOT/bin/manim" "$ROOT/bin/dvisvgm"

cat > "$ROOT/env.sh" <<'SH'
# Source from bash/zsh if persistent environment variables are preferred.
_MANIM_RUNTIME_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE:-$0}")" && pwd)"
export MANIM_RUNTIME_ROOT="$_MANIM_RUNTIME_ROOT"
export PYTHONPATH="$MANIM_RUNTIME_ROOT/python${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$MANIM_RUNTIME_ROOT/bin:$PATH"
unset _MANIM_RUNTIME_ROOT
SH

cat > "$ROOT/verify.py" <<'PY'
import importlib
import importlib.metadata
import platform
import shutil
import subprocess
import sys

if sys.version_info[:2] != (3, 13):
    raise SystemExit(f"requires CPython 3.13, got {sys.version}")

required = [
    ("manim", "manim"),
    ("av", "av"),
    ("manimpango", "ManimPango"),
    ("cairo", "pycairo"),
    ("moderngl", "moderngl"),
    ("moderngl_window", "moderngl-window"),
    ("glm", "PyGLM"),
    ("mapbox_earcut", "mapbox-earcut"),
    ("pathops", "skia-pathops"),
]

print("python:", sys.version.replace("\n", " "))
print("platform:", platform.platform())
for module, dist in required:
    importlib.import_module(module)
    print(f"{module}: {importlib.metadata.version(dist)}")

for binary in ("ffmpeg", "ffprobe", "latex", "dvisvgm"):
    p = shutil.which(binary)
    if not p:
        raise SystemExit(f"missing required binary: {binary}")
    print(f"{binary}: {p}")

import manim
if manim.__version__ != "0.22.0":
    raise SystemExit(f"unexpected manim version: {manim.__version__}")
print("IMPORT-SMOKE: PASS")
PY

cat > "$ROOT/smoke_scene.py" <<'PY'
from manim import *

class RuntimeSmoke(Scene):
    def construct(self):
        title = Text("Manim CE 0.22")
        formula = MathTex(r"x^2+y^2=1").next_to(title, DOWN)
        self.play(FadeIn(title), Write(formula), run_time=0.2)
        self.wait(0.1)
PY

cat > "$ROOT/bootstrap.sh" <<'SH'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PYTHONPATH="$ROOT/python${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$ROOT/bin:$PATH"

python3 "$ROOT/verify.py"

if [ "${1:-}" = "--full" ]; then
  OUT="${TMPDIR:-/tmp}/manim-runtime-smoke"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  "$ROOT/bin/manim" -ql --disable_caching --media_dir "$OUT"     "$ROOT/smoke_scene.py" RuntimeSmoke
  VIDEO="$(find "$OUT" -type f -name '*.mp4' -print -quit)"
  test -n "$VIDEO"
  test -s "$VIDEO"
  ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$VIDEO"
  echo "RENDER-SMOKE: PASS"
fi

echo "MANIM-CE-RUNTIME: READY"
SH
chmod +x "$ROOT/bootstrap.sh"

python -m pip freeze --path "$PYROOT" | sort > "$ROOT/requirements.lock.txt"

python3 - <<'PY'
import json, pathlib, platform, subprocess
root = pathlib.Path("/work/stage/manim-ce-runtime")
manifest = {
    "name": "manim-ce-runtime",
    "manim": "0.22.0",
    "python_abi": "cp313",
    "architecture": "x86_64",
    "build_os": "Debian 13 (trixie)",
    "delivery": "Dropbox/ChatGPT Library -> files.materialize -> /mnt/data",
    "external_runtime_requirements": [
        "CPython 3.13",
        "ffmpeg and ffprobe",
        "Pango/Cairo runtime libraries",
        "TeX Live with latex",
        "fontconfig/system fonts"
    ],
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

# Prove the staged runtime works before archiving.
"$ROOT/bootstrap.sh" --full

# Remove caches only after verification.
find "$PYROOT" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$PYROOT" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

tar -I 'zstd -15 -T0'   -cf "$WORK/out/manim-ce-runtime-linux-x86_64-py313.tar.zst"   -C "$WORK/stage" manim-ce-runtime

cd "$WORK/out"
sha256sum manim-ce-runtime-linux-x86_64-py313.tar.zst   > manim-ce-runtime-linux-x86_64-py313.tar.zst.sha256
stat -c 'ARCHIVE_SIZE=%s' manim-ce-runtime-linux-x86_64-py313.tar.zst
cat manim-ce-runtime-linux-x86_64-py313.tar.zst.sha256
