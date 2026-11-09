# syntax=docker/dockerfile:1.7
# Compact JetPack 7.2.0 / L4T R39.2.0 development image for Orin Nano.
# One container: CUDA/cuDNN compiler, TensorRT 10 SDK, DeepStream 9.1, VPI,
# Python 3.12, Node.js LTS, native Codex and Git provider CLIs.
# NVIDIA driver/device access still comes from the Jetson container runtime.
# Avoid the multi-GB Triton Inference Server and redundant CUDA/SDK copies.
ARG CUDA_IMAGE=nvidia/cuda:13.2.1-cudnn-devel-ubuntu24.04
FROM ghcr.io/jdx/mise:2026.10.4 AS mise-binary
FROM ${CUDA_IMAGE}

SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HOME=/root \
    PIPX_BIN_DIR=/usr/local/bin \
    PIPX_HOME=/opt/pipx \
    MISE_TRUSTED_CONFIG_PATHS=/root/.config/mise \
    UV_NO_PROGRESS=1 \
    PIP_NO_CACHE_DIR=1
ENV PATH="/opt/nvidia/deepstream/deepstream-9.1/bin:/root/.local/share/mise/shims:/root/.local/bin:/usr/local/cuda/bin:${PATH}"
ENV GST_PLUGIN_PATH="/opt/nvidia/deepstream/deepstream-9.1/lib/gst-plugins"
ENV LD_LIBRARY_PATH="/opt/nvidia/deepstream/deepstream-9.1/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

# Install the DeepStream 9.1 runtime's documented GStreamer dependencies plus
# only the development and CLI packages the Codex environment actually uses.
# No Java, Swift, PHP, Rust, Go, Erlang or Triton server.
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    v4l-utils wget xz-utils zip zlib1g-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# JetPack 7.2 / L4T R39.2 ships TensorRT 10.16.2.10 for CUDA 13.2.
# The CUDA base additionally configures NVIDIA's general CUDA APT repository,
# which offers newer TensorRT 11.x for CUDA 13.4. Without pinning, APT selects
# that release and nvidia-tensorrt's exact version dependencies cannot resolve.
# Keep all transitive TensorRT libraries on the JetPack-matched ABI.
ARG TENSORRT_VERSION=10.16.2.10-1+cuda13.2
RUN install -dm 0755 /etc/apt/keyrings /etc/apt/preferences.d \
    && curl -fsSL https://repo.download.nvidia.com/jetson/jetson-ota-public.asc \
       | gpg --dearmor -o /etc/apt/keyrings/nvidia-jetson-sdk.gpg \
    && chmod 0644 /etc/apt/keyrings/nvidia-jetson-sdk.gpg \
    && printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/nvidia-jetson-sdk.gpg] https://repo.download.nvidia.com/jetson/common r39.2 main\n' \
       > /etc/apt/sources.list.d/jetson-sdk.list \
    && printf '%s\n' \
       'Package: tensorrt tensorrt-libs tensorrt-dev libnvinfer* libnvonnxparsers* python3-libnvinfer*' \
       'Pin: version 10.16.2.10-1+cuda13.2' \
       'Pin-Priority: 1001' \
       > /etc/apt/preferences.d/jetpack72-tensorrt \
    && apt-get update \
    && echo "JetPack 7.2 TensorRT package candidates:" \
    && apt-cache policy tensorrt-libs tensorrt \
    && if ! apt-cache madison tensorrt-libs | awk '{print $3}' | grep -Fx "$TENSORRT_VERSION" >/dev/null; then \
         echo "ERROR: NVIDIA Jetson r39.2 repo is missing TensorRT $TENSORRT_VERSION" >&2; exit 1; \
       fi \
    && apt-get install -y --no-install-recommends \
       "tensorrt-libs=${TENSORRT_VERSION}" "tensorrt=${TENSORRT_VERSION}" \
       nvidia-tensorrt nvidia-tensorrt-dev libnvvpi4 vpi4-dev \
    && test "$(dpkg-query -W -f='${Version}' tensorrt-libs)" = "$TENSORRT_VERSION" \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    && ldconfig

# NVIDIA's official standalone Jetson SDK includes the DeepStream framework,
# plugins, apps and headers. Fetch, unpack and delete the archive IN ONE
# Docker layer so the 657-MB download never inflates the final image layers.
# Remove bundled demonstration videos after SDK installation. Model configs,
# application binaries and development headers remain. RTSP inputs work normally.
ARG DEEPSTREAM_VERSION=9.1.0
# Stream the ~657 MB DeepStream archive to tar: never write the downloaded
# archive to Docker scratch storage. pipefail catches a truncated transfer.
RUN curl -fLSs --retry 3 \
      "https://github.com/NVIDIA/DeepStream/releases/download/v9.1.0/deepstream_sdk_v${DEEPSTREAM_VERSION}_jetson.tbz2" \
    | tar -xjf - -C / \
    && test -x /opt/nvidia/deepstream/deepstream-9.1/install.sh \
    && /opt/nvidia/deepstream/deepstream-9.1/install.sh \
    && rm -rf /opt/nvidia/deepstream/deepstream-9.1/samples/streams \
    && ln -sfn /opt/nvidia/deepstream/deepstream-9.1 /opt/nvidia/deepstream/deepstream \
    && printf '%s\n' /opt/nvidia/deepstream/deepstream-9.1/lib \
       > /etc/ld.so.conf.d/deepstream-9.1.conf \
    && ldconfig

# JetPack 7.2 uses the host's NVIDIA driver. CUDA forward-compatibility
# shim packages may intercept libcuda and break Orin GPU initialisation.
RUN for pkg in cuda-compat-13-2 cuda-compat-orin-13-2; do \
      if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed'; then \
        apt-get purge -y "$pkg"; \
      fi; \
    done \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# DeepStream 9.1 is coupled to JetPack 7.2's CUDA 13.2/TensorRT 10.16.
# Run real inference/decoding tests on dexson after Docker startup; a
# library-presence check alone does not validate hardware integration.
RUN command -v nvcc \
    && test -f /usr/include/aarch64-linux-gnu/NvInfer.h \
       -o -f /usr/include/NvInfer.h \
    && test -x /opt/nvidia/deepstream/deepstream-9.1/bin/deepstream-app \
    && ldconfig -p > /tmp/jetson-ldconfig.txt \
    && for lib in libnvinfer.so libcudnn.so libnvvpi.so; do \
         grep -F "$lib" /tmp/jetson-ldconfig.txt >/dev/null || { \
           echo "Missing NVIDIA SDK library: $lib" >&2; exit 1; }; \
       done \
    && rm /tmp/jetson-ldconfig.txt \
    && command -v gst-inspect-1.0

# Official GitHub CLI APT repository, which ships current ARM64 builds.
RUN install -dm 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    && gh --version

# mise handles multiple versions of runtimes, with persistent shims in PATH.
# The official container contains /usr/local/bin/mise (static musl build).
COPY --from=mise-binary /usr/local/bin/mise /usr/local/bin/mise
RUN mise --version

# Persistent Git hosting clients for GitLab and Azure DevOps.
# glab is installed from GitLab releases using the mise backend.
ARG GLAB_VERSION=1.128.0
RUN mise install "glab@${GLAB_VERSION}" \
    && mise use --global "glab@${GLAB_VERSION}" \
    && glab --version \
    && rm -rf /root/.cache/mise

# Azure DevOps CLI for Azure DevOps Services (not on-prem DevOps Server).
# Official Microsoft Ubuntu Noble ARM64 APT repository.
RUN install -dm 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /etc/apt/keyrings/microsoft-azure.gpg \
    && chmod 0644 /etc/apt/keyrings/microsoft-azure.gpg \
    && printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/microsoft-azure.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main\n' \
      > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends azure-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    && az --version
ENV AZURE_EXTENSION_DIR=/opt/azure-cli-extensions
RUN mkdir -p "${AZURE_EXTENSION_DIR}" \
    && az extension add --name azure-devops --yes \
    && az extension show --name azure-devops --query name -o tsv \
    && rm -rf /root/.cache/pip /root/.cache/azure

# Use Ubuntu 24.04's system Python 3.12. NVIDIA/DeepStream Python wheels may
# rely on the distro ABI; no separate mise Python toolchains are installed.
# uv can install project-local dependencies on demand without bloating this image.
RUN python3 -c 'import sys; assert sys.version_info[:2] == (3,12), sys.version' \
    && pipx install uv \
    && pipx install ruff \
    && uv --version \
    && ruff --version \
    && rm -rf /root/.cache/pip /root/.cache/pipx

# One Node.js LTS runtime for front-end and full-stack work. Codex is a
# standalone ARM64 binary and does not require Node or Rust to execute.
ARG NODE_VERSION=26.11.0
RUN mise install "node@${NODE_VERSION}" \
    && mise use --global "node@${NODE_VERSION}" \
    && mise exec "node@${NODE_VERSION}" -- npm install --global \
       typescript eslint prettier pnpm \
    && mise exec "node@${NODE_VERSION}" -- npm cache clean --force \
    && node --version \
    && npm --version \
    && pnpm --version \
    && rm -rf /root/.cache/mise /root/.cache/npm

# Standalone native ARM64 Codex executable (not an npm or Rust build).
ARG CODEX_RELEASE=latest
RUN curl -fLSs "https://github.com/openai/codex/releases/${CODEX_RELEASE}/download/codex-aarch64-unknown-linux-musl.tar.gz" \
      -o /tmp/codex.tar.gz \
    && tar -xzf /tmp/codex.tar.gz -C /usr/local/bin \
    && mv /usr/local/bin/codex-aarch64-unknown-linux-musl /usr/local/bin/codex \
    && chmod 0755 /usr/local/bin/codex \
    && rm /tmp/codex.tar.gz \
    && codex --version

# Native-device utilities are installed; device access is granted at runtime.
COPY setup-versions.sh verify.sh entrypoint.sh configure-full-trust.py codex-connect.sh hardware-check.sh tensorrt-smoke.cpp /opt/jetson-codex/
RUN chmod 0755 /opt/jetson-codex/*.sh \
    && ln -sf /opt/jetson-codex/codex-connect.sh /usr/local/bin/codex-connect \
    && mkdir -p /workspace /root/.codex \
    && printf '\n# Jetson Codex development tools\nexport PATH="/opt/nvidia/deepstream/deepstream-9.1/bin:/root/.local/share/mise/shims:/root/.local/bin:/usr/local/cuda/bin:$PATH"\n' >> /root/.bashrc
# Build fingerprint is injected by install.sh and added only at the end so
# documentation changes do not invalidate expensive language toolchain layers.
ARG JETSON_CODEX_BUILD_HASH=untracked
LABEL org.jetson-codex.build-hash="${JETSON_CODEX_BUILD_HASH}"
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=all
WORKDIR /workspace
ENTRYPOINT ["/opt/jetson-codex/entrypoint.sh"]
CMD ["bash", "-l"]
