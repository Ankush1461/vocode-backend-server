#!/usr/bin/env bash
set -euxo pipefail

# Build script for Render: install CPU-only torch, avoid pip cache, and print site-packages size

# 1) Upgrade pip tooling
python -m pip install --upgrade pip setuptools wheel

# 2) If requirements.txt contains `openai-whisper` and you DO NOT want the heavy local whisper,
#    remove it from the list installed on Render (keeps the remote API / whisper.cpp options).
if grep -q '^openai-whisper$' requirements.txt; then
  sed '/^openai-whisper$/d' requirements.txt > /tmp/reqs.txt
  REQ_FILE=/tmp/reqs.txt
else
  REQ_FILE=requirements.txt
fi

# 3) Install CPU-only PyTorch wheels (prebuilt CPU binaries - avoids CUDA libs)
python -m pip install --no-cache-dir -f https://download.pytorch.org/whl/cpu/torch_stable.html \
  torch torchvision torchaudio || true

# 4) Install the rest of requirements without caching wheels
python -m pip install --no-cache-dir -r "$REQ_FILE"

# 5) Purge pip cache and other build artifacts
python -m pip cache purge || true
rm -rf /root/.cache/pip /tmp/pip-* /tmp/build 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

# 6) Optional: strip unneeded symbols from shared libraries if `strip` is available
if command -v strip >/dev/null 2>&1; then
  find /usr/local/lib/python* -name "*.so" -exec strip --strip-unneeded {} + || true
fi

# 7) Debug: print site-packages size to help verify savings
python - <<'PY'
import site, os
sp = site.getsitepackages()[0]
def walk_size(path):
    total=0
    for root,_,files in os.walk(path):
        for f in files:
            try:
                total+=os.path.getsize(os.path.join(root,f))
            except: pass
    return total/1024/1024
print("site-packages size (MB):", round(walk_size(sp),2))
PY
