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
check 'Python' python3 --version
check 'Installed Pythons' mise ls python
check 'Node.js' node --version
check 'Installed Nodes' mise ls node
check 'npm' npm --version
check 'TypeScript' tsc --version
check 'pnpm' pnpm --version
check 'Yarn' yarn --version
check 'Rust' rustc --version
check 'Rust toolchains' rustup toolchain list
check 'Go' go version
check 'Java' java -version
check 'Gradle' gradle --version
check 'Maven' mvn --version
check 'Ruby' ruby --version
check 'Bun' bun --version
check 'Bazelisk' bazelisk --version
check 'Erlang' erl -eval 'erlang:display(erlang:system_info(otp_release)),halt().' -noshell
check 'Elixir' elixir --version
check 'Poetry' poetry --version
check 'uv' uv --version
check 'Clang' clang --version
check 'CMake' cmake --version
check 'GStreamer' gst-inspect-1.0 --version
if command -v php >/dev/null 2>&1; then check 'PHP' php --version; check 'Composer' composer --version; fi
if command -v swift >/dev/null 2>&1; then check 'Swift' swift --version; fi
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
