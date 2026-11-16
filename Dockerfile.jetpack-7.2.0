# syntax=docker/dockerfile:1.7
# Minimal persistent JetPack 7.2 / L4T R39.2 container foundation.
# Bring this container up FIRST. The full SDK is installed later into its
# own writable layer by provision-container.sh via docker exec.
# No Dockerfile APT, SDK unpacking, docker commit, or duplicate image export.
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
    PIP_NO_CACHE_DIR=1 \
    AZURE_EXTENSION_DIR=/opt/azure-cli-extensions
ENV PATH="/opt/nvidia/deepstream/deepstream-9.1/bin:/root/.local/share/mise/shims:/root/.local/bin:/usr/local/cuda/bin:${PATH}"
ENV GST_PLUGIN_PATH="/opt/nvidia/deepstream/deepstream-9.1/lib/gst-plugins"
ENV LD_LIBRARY_PATH="/opt/nvidia/deepstream/deepstream-9.1/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
# Cloud model weights use rclone's existing read-through cache; keep APT,
# dpkg and durable credentials on local Docker storage instead.
ENV HF_HOME=/workspace/projects/.cache/huggingface \
    TORCH_HOME=/workspace/projects/.cache/torch
COPY --from=mise-binary /usr/local/bin/mise /usr/local/bin/mise
ARG JETSON_CODEX_BUILD_HASH=untracked
LABEL org.jetson-codex.build-hash="${JETSON_CODEX_BUILD_HASH}"
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=all
WORKDIR /workspace
CMD ["sleep", "infinity"]
