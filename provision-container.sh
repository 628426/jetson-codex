#!/usr/bin/env bash
# Post-start, low-peak provisioning for JetPack 7.2 / L4T R39.2.
# Installs into the persistent Docker container writable layer, not an image.
# Never docker commit/save/export: that would duplicate the installed delta.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
hash="${JETSON_CODEX_PROVISION_HASH:-}"
[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "Missing valid provision hash" >&2; exit 2; }
marker=/var/lib/jetson-codex/provision.sha256
# Remote Control requires a complete installer-managed Codex package, not the
# raw executable previously downloaded into /usr/local/bin.
managed_codex_path() {
  local candidate
  for candidate in "$HOME/.codex/packages/standalone/current/bin/codex" \
                   "$HOME/.codex/packages/standalone/current/codex"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}
managed_codex_ready() {
  local packaged
  packaged="$(managed_codex_path)" || return 1
  [[ -L /usr/local/bin/codex ]] || return 1
  [[ "$(readlink -f /usr/local/bin/codex)" == "$(readlink -f "$packaged")" ]] || return 1
  /usr/local/bin/codex remote-control --help >/dev/null 2>&1
}
if [[ -f "$marker" && "$(cat "$marker")" == "$hash" ]] \
  && command -v nvcc >/dev/null && managed_codex_ready \
  && command -v gh >/dev/null && command -v glab >/dev/null \
  && command -v az >/dev/null \
  && test -x /opt/nvidia/deepstream/deepstream-9.1/bin/deepstream-app; then
  echo "[image-provision] Already provisioned; no changes made."
  exit 0
fi

log() { printf '[image-provision] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
# The container upperdir receives only installed files; clean temporary
# APT archives and installers after each phase and even on failure.
cleanup() {
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
         /root/.cache/mise /root/.cache/npm /root/.cache/pip \
         /root/.cache/pipx /root/.cache/azure /tmp/codex.tar.gz
}
trap cleanup EXIT

log 'Checking required Ubuntu CLI, compiler, media and DeepStream dependencies.'
base_packages=( \
  bash-completion bzip2 build-essential ca-certificates \
  clang clang-format clang-tidy cmake curl \
  dnsutils fd-find ffmpeg file gdb git git-lfs gnupg gpg \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
  gstreamer1.0-rtsp libgstrtspserver-1.0-0 libgstrtspserver-1.0-dev \
  i2c-tools inotify-tools iputils-ping jq libatomic1 \
  libcurl4-openssl-dev libffi-dev libglib2.0-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libjansson4 libjson-glib-1.0-0 libjsoncpp-dev libyaml-cpp-dev \
  librabbitmq4 librdkafka1 libmosquitto1 \
  libjpeg-dev libpng-dev libssl-dev libv4l-dev libopencv-dev \
  make ninja-build openssh-client patch pipx pkg-config \
  procps protobuf-compiler python3-dev python3-pip python3-venv \
  ripgrep rsync sqlite3 sudo swig tmux tzdata unzip usbutils \
  v4l-utils wget xz-utils zip zlib1g-dev
)
missing_packages=()
for pkg in "${base_packages[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed' || missing_packages+=("$pkg")
done
if (("${#missing_packages[@]}")); then
  log "Installing ${#missing_packages[@]} missing Ubuntu packages."
  apt-get update
  apt-get install -y --no-install-recommends "${missing_packages[@]}"
  apt-get clean
  rm -rf /var/lib/apt/lists/*
else
  log 'Ubuntu dependencies already installed.'
fi

# CUDA base has the generic CUDA APT feed (which can offer incompatible TRT
# 11). Pin the entire JetPack 7.2 TensorRT family to CUDA 13.2.
trt_version='10.16.2.10-1+cuda13.2'
if [[ "$(dpkg-query -W -f='${Version}' tensorrt-libs 2>/dev/null || true)" == "$trt_version" ]] \
  && dpkg-query -W -f='${Status}' nvidia-tensorrt-dev libnvvpi4 vpi4-dev 2>/dev/null | grep -cFx 'install ok installed' | grep -Fxq 3; then
  log "TensorRT $trt_version and VPI 4 already installed; skipping APT."
else
log "Installing NVIDIA JetPack-matched TensorRT $trt_version and VPI 4."
install -dm 0755 /etc/apt/keyrings /etc/apt/preferences.d
curl -fsSL --retry 3 https://repo.download.nvidia.com/jetson/jetson-ota-public.asc \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nvidia-jetson-sdk.gpg
chmod 0644 /etc/apt/keyrings/nvidia-jetson-sdk.gpg
printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/nvidia-jetson-sdk.gpg] https://repo.download.nvidia.com/jetson/common r39.2 main\n' \
  > /etc/apt/sources.list.d/jetson-sdk.list
printf '%s\n' \
  'Package: tensorrt tensorrt-libs tensorrt-dev libnvinfer* libnvonnxparsers* python3-libnvinfer*' \
  'Pin: version 10.16.2.10-1+cuda13.2' \
  'Pin-Priority: 1001' > /etc/apt/preferences.d/jetpack72-tensorrt
apt-get update
apt-cache policy tensorrt-libs tensorrt
apt-cache madison tensorrt-libs | awk '{print $3}' | grep -Fx "$trt_version" >/dev/null \
  || fail "Jetson r39.2 repository lacks TensorRT $trt_version"
apt-get install -y --no-install-recommends \
  "tensorrt-libs=$trt_version" "tensorrt=$trt_version" \
  nvidia-tensorrt nvidia-tensorrt-dev libnvvpi4 vpi4-dev
[[ "$(dpkg-query -W -f='${Version}' tensorrt-libs)" == "$trt_version" ]] \
  || fail "Installed TensorRT version does not match JetPack 7.2"
apt-get clean
rm -rf /var/lib/apt/lists/*
ldconfig

fi

# Never materialise the ~657 MB DeepStream tarball on Docker's filesystem.
# Stream directly to extraction and remove demo videos before sealing layer.
if [[ ! -x /opt/nvidia/deepstream/deepstream-9.1/bin/deepstream-app ]]; then
log 'Streaming and installing DeepStream 9.1.'
curl -fLSs --retry 3 \
  'https://github.com/NVIDIA/DeepStream/releases/download/v9.1.0/deepstream_sdk_v9.1.0_jetson.tbz2' \
  | tar -xjf - -C /
test -x /opt/nvidia/deepstream/deepstream-9.1/install.sh \
  || fail 'DeepStream release missing install.sh'
/opt/nvidia/deepstream/deepstream-9.1/install.sh
rm -rf /opt/nvidia/deepstream/deepstream-9.1/samples/streams
ln -sfn /opt/nvidia/deepstream/deepstream-9.1 /opt/nvidia/deepstream/deepstream
printf '%s\n' /opt/nvidia/deepstream/deepstream-9.1/lib \
  > /etc/ld.so.conf.d/deepstream-9.1.conf
ldconfig
else
  log 'DeepStream 9.1 already installed; skipping archive transfer.'
fi

# The host driver provides libcuda. Forward-compatibility shims can shadow it.
for pkg in cuda-compat-13-2 cuda-compat-orin-13-2; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed'; then
    apt-get purge -y "$pkg"
  fi
done

if ! command -v gh >/dev/null 2>&1; then
log 'Installing GitHub CLI.'
curl -fsSL --retry 3 https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
  "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y --no-install-recommends gh
apt-get clean
rm -rf /var/lib/apt/lists/*
gh --version
else
  log 'GitHub CLI already installed.'
fi

if ! glab --version 2>/dev/null | head -n 1 | grep -Fq '1.128.0'; then
log 'Installing pinned GitLab CLI with mise.'
mise install 'glab@1.128.0'
mise use --global 'glab@1.128.0'
glab --version
rm -rf /root/.cache/mise
else
  log 'GitLab CLI already pinned.'
fi

if ! command -v az >/dev/null 2>&1; then
log 'Installing Microsoft Azure CLI and DevOps extension.'
curl -fsSL --retry 3 https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft-azure.gpg
chmod 0644 /etc/apt/keyrings/microsoft-azure.gpg
printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/microsoft-azure.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main\n' \
  > /etc/apt/sources.list.d/azure-cli.list
apt-get update
apt-get install -y --no-install-recommends azure-cli
apt-get clean
rm -rf /var/lib/apt/lists/*
az --version
fi
if ! az extension show --name azure-devops --query name -o tsv >/dev/null 2>&1; then
  log 'Installing Azure DevOps extension.'
  mkdir -p /opt/azure-cli-extensions
  az extension add --name azure-devops --yes
fi
az extension show --name azure-devops --query name -o tsv
rm -rf /root/.cache/azure /root/.cache/pip

log 'Installing Python 3.12 tools (no duplicate Python runtime).'
python3 -c 'import sys; assert sys.version_info[:2] == (3,12), sys.version'
command -v uv >/dev/null 2>&1 || pipx install uv
command -v ruff >/dev/null 2>&1 || pipx install ruff
uv --version
ruff --version
rm -rf /root/.cache/pipx /root/.cache/pip

if ! node --version 2>/dev/null | grep -Fxq 'v26.11.0' || ! command -v pnpm >/dev/null 2>&1 || ! command -v tsc >/dev/null 2>&1; then
log 'Installing one Node.js runtime and front-end tools.'
mise install 'node@26.11.0'
mise use --global 'node@26.11.0'
mise exec 'node@26.11.0' -- npm install --global typescript eslint prettier pnpm
mise exec 'node@26.11.0' -- npm cache clean --force
node --version
npm --version
pnpm --version
rm -rf /root/.cache/mise /root/.cache/npm
else
  log 'Node.js and front-end tools already installed.'
fi

if managed_codex_ready; then
  log 'Complete installer-managed Codex package already present; skipping install.'
else
  log 'Installing official complete Codex package (required for Remote Control).'
  # Reuse the existing /root/.codex Docker auth volume for the managed
  # standalone package and app-server daemon metadata. The old unpacked
  # /usr/local/bin/codex file is atomically replaced by the official CLI
  # installer with a symlink to the managed package.
  export CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR=/usr/local/bin
  curl -fsSL --retry 3 https://chatgpt.com/codex/install.sh | sh
  managed_codex_ready || fail 'Official Codex installer did not produce a complete managed package.'
fi
codex --version

# Keep live scripts in the read-only host bind. Only the executable shim is
# stored in this container's writable filesystem.
if [[ ! -x /usr/local/bin/codex-connect ]]; then
  printf '%s\n' '#!/bin/sh' 'exec /bin/bash /opt/jetson-codex/codex-connect.sh "$@"' \
    > /usr/local/bin/codex-connect
  chmod 0755 /usr/local/bin/codex-connect
fi
bash /opt/jetson-codex/setup-versions.sh

# Fail provisioning if even basic SDK components are unavailable.
command -v nvcc
test -f /usr/include/aarch64-linux-gnu/NvInfer.h -o -f /usr/include/NvInfer.h
test -x /opt/nvidia/deepstream/deepstream-9.1/bin/deepstream-app
for lib in libnvinfer.so libcudnn.so libnvvpi.so; do
  ldconfig -p | grep -F "$lib" >/dev/null || fail "Missing NVIDIA SDK library: $lib"
done
command -v gst-inspect-1.0
command -v mise
log 'SDK and developer tools provisioned; removing temporary downloads.'
cleanup
trap - EXIT
install -d -m 0755 /var/lib/jetson-codex
printf '%s\n' "$hash" > "$marker.tmp"
mv -f "$marker.tmp" "$marker"
log 'Provisioning complete; state marker saved.'
