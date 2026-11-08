#!/usr/bin/env bash
set -uo pipefail
failed=0
check() {
  local title="$1"; shift
  printf '%-22s ' "$title"
  if out=$("$@" 2>&1); then
    printf 'OK: %s\n' "$(printf '%s' "$out" | head -n 1)"
  else
    printf 'FAIL: %s\n' "$(printf '%s' "$out" | head -n 1)"
    failed=$((failed + 1))
  fi
}
check 'Codex' codex --version
check 'GitHub CLI' gh --version
check 'Git provider setup' codex-connect --status
check 'GitLab CLI' glab --version
check 'Azure CLI' az --version
check 'Azure DevOps CLI' az devops --help
check 'CUDA compiler' nvcc --version
check 'DeepStream' bash -lc 'test -d /opt/nvidia/deepstream/deepstream-9.1 && echo DeepStream-9.1'
check 'TensorRT' bash -lc 'ldconfig -p | grep -F libnvinfer.so'
check 'cuDNN' bash -lc 'ldconfig -p | grep -F libcudnn.so'
check 'VPI' bash -lc 'ldconfig -p | grep -F libnvvpi.so'
check 'DeepStream GStreamer' gst-inspect-1.0 nvinfer
check 'H264/H265 NVDEC' bash /opt/jetson-codex/hardware-check.sh --video
check 'DeepStream NVMM' bash /opt/jetson-codex/hardware-check.sh --deepstream
check 'TensorRT GPU inference' bash /opt/jetson-codex/hardware-check.sh --tensorrt
check 'Python 3.12' bash -lc "python3 -c 'import sys; assert sys.version_info[:2] == (3,12)'"
check 'uv' uv --version
check 'Ruff' ruff --version
check 'Node.js' node --version
check 'npm' npm --version
check 'pnpm' pnpm --version
check 'TypeScript' tsc --version
check 'Clang' clang --version
check 'Clang-format' clang-format --version
check 'CMake' cmake --version
check 'Ninja' ninja --version
check 'GStreamer' gst-inspect-1.0 --version
check 'FFmpeg' ffmpeg -version
check 'Git LFS' git lfs version
printf '%-22s ' 'CUDA device access'
if python3 - <<'PY'
import ctypes
lib = ctypes.CDLL('libcuda.so.1')
rc = lib.cuInit(0)
if rc != 0:
    raise RuntimeError(f'cuInit failed: {rc}')
count = ctypes.c_int()
rc = lib.cuDeviceGetCount(ctypes.byref(count))
if rc != 0 or count.value < 1:
    raise RuntimeError(f'cuDeviceGetCount returned {rc}, count={count.value}')
print(f'{count.value} CUDA device(s)')
PY
then :; else
  failed=$((failed + 1))
fi
printf '\n'
if [[ $failed -eq 0 ]]; then echo 'All available core checks passed.'; else echo "$failed checks failed."; fi
exit "${failed}"
