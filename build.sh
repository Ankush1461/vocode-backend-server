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

# 8) Build or download whisper.cpp and a small ggml model for local transcription (whisper.cpp)
# This avoids installing heavy Python whisper packages and torch on Render.
mkdir -p whisper.cpp/models

# Download the tiny ggml model if not present
if [ ! -f whisper.cpp/models/ggml-tiny.bin ]; then
  echo "Downloading ggml-tiny model..."
  wget -q -O whisper.cpp/models/ggml-tiny.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/models/ggml-tiny.bin || true
fi

# Try to build whisper.cpp native library if libwhisper.so is not present
if [ ! -f whisper.cpp/libwhisper.so ]; then
  echo "Building whisper.cpp native library..."
  # clone shallow to /tmp and build
  rm -rf /tmp/whisper.cpp || true
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp /tmp/whisper.cpp || true
  if [ -d /tmp/whisper.cpp ]; then
    (cd /tmp/whisper.cpp && make -j"$(nproc)") && cp /tmp/whisper.cpp/libwhisper.so whisper.cpp/ || true
  fi
fi

# If build failed and no lib is present, warn but continue (app will fallback)
if [ ! -f whisper.cpp/libwhisper.so ]; then
  echo "Warning: libwhisper.so not found. You can provide a prebuilt lib or set OPENAI_API_KEY to use hosted Whisper."
fi

