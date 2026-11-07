#!/usr/bin/env bash
# Jetson hardware inventory and media smoke-test. Invoked by install.sh.
# --devices prints pass-through-eligible character device paths, one per line.
# --video tests CPU H.264 encoding and the actual NVIDIA hardware decoder.
set -Eeuo pipefail

devices() {
  shopt -s nullglob
  local paths=()
  # NVIDIA GPU, NVDEC, VIC, NVJPG and optional other nvhost engines.
  # Camera/media, I2C, SPI, GPIO, and hot-pluggable USB serial interfaces.
  for node in /dev/nvhost* /dev/nvmap /dev/nvidia* /dev/dri/renderD* /dev/dri/card* \
              /dev/video[0-9]* /dev/media[0-9]* /dev/v4l-subdev* \
              /dev/i2c-[0-9]* /dev/spidev* /dev/gpiochip[0-9]* \
              /dev/ttyUSB[0-9]* /dev/ttyACM[0-9]*; do
    [[ -c "$node" ]] && paths+=("$node")
  done
  if ((${#paths[@]})); then printf '%s\n' "${paths[@]}" | LC_ALL=C sort -u; fi
}

video() {
  local tmp result=0
  tmp="$(mktemp -d /tmp/jetson-codec-XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT
  printf '[Video] NVIDIA hardware decode plugin: '
  if ! command -v gst-inspect-1.0 >/dev/null || ! gst-inspect-1.0 nvv4l2decoder >/dev/null 2>&1; then
    echo 'FAIL (nvv4l2decoder missing)'; return 1
  fi
  echo OK
  printf '[Video] CPU H.264 encode fixture: '
  if ! command -v ffmpeg >/dev/null || ! timeout 30 ffmpeg -nostdin -hide_banner -loglevel error \
      -f lavfi -i 'testsrc2=size=160x120:rate=10' \
      -frames:v 12 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
      -y -f h264 "$tmp/sample.h264"; then
    echo 'FAIL (ffmpeg libx264 unavailable)'; return 1
  fi
  echo OK
  printf '[Video] Real NVIDIA H.264 NVDEC decode: '
  if timeout 30 gst-launch-1.0 -q \
      filesrc location="$tmp/sample.h264" ! h264parse ! nvv4l2decoder \
      ! fakesink sync=false >"$tmp/decode.log" 2>&1; then
    echo 'PASS (hardware pipeline executed)'
  else
    echo 'FAIL (NVIDIA decoder did not execute)'
    tail -n 15 "$tmp/decode.log" >&2
    result=1
  fi
  printf '[Video] NVENC hardware encode: N/A (Orin Nano has no NVENC engine)\n'
  printf '[Video] Software H.265 encoder: '
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -F 'libx265' >/dev/null; then
    echo available
  else
    echo unavailable
  fi
  return "$result"
}

cuda() {
  # CUDA is checked with the *driver API*, not nvcc presence. Stock Python3
  # and ctypes suffice; no CUDA compiler or development packages on the host.
  python3 - <<'PY'
import ctypes
cuda = ctypes.CDLL("libcuda.so.1")
code = cuda.cuInit(0)
if code != 0:
    raise SystemExit(f"CUDA driver initialisation returned {code}")
count = ctypes.c_int()
code = cuda.cuDeviceGetCount(ctypes.byref(count))
if code != 0 or count.value < 1:
    raise SystemExit(f"CUDA device count failed: status={code}, count={count.value}")
print(f"CUDA devices: {count.value}")
PY
}

case "${1:---devices}" in
  --devices) devices ;;
  --video) video ;;
  --cuda) cuda ;;
  *) echo "Usage: hardware-check.sh [--devices|--cuda|--video]" >&2; exit 2 ;;
esac
