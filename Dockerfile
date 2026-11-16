# syntax=docker/dockerfile:1.7
# Peak-disk-oriented JetPack 7.2 image:
# CUDA/cuDNN base + ONE mutable RUN containing all APT/SDK/tool installs.
# No Docker-in-Docker, docker commit, local docker save, or stacked APT layers.
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

COPY --from=mise-binary /usr/local/bin/mise /usr/local/bin/mise
# Mount provisioning code for this build step without copying it to a layer.
# Nothing installed in the full SDK step is cached in a separate RUN layer.
# All APT downloads, temporary archives and tools are cleaned before the
# *same* RUN completes. Rebuilds of operational helpers reuse the heavy layer.
RUN --mount=type=bind,source=provision-image.sh,target=/tmp/provision-image.sh,ro \
    bash /tmp/provision-image.sh

COPY setup-versions.sh verify.sh entrypoint.sh configure-full-trust.py codex-connect.sh hardware-check.sh tensorrt-smoke.cpp /opt/jetson-codex/
RUN chmod 0755 /opt/jetson-codex/*.sh \
    && ln -sf /opt/jetson-codex/codex-connect.sh /usr/local/bin/codex-connect \
    && mkdir -p /workspace /root/.codex \
    && ln -sfn /workspace/projects/models /opt/model-store \
    && printf '\n# Jetson Codex development tools\nexport PATH="/opt/nvidia/deepstream/deepstream-9.1/bin:/root/.local/share/mise/shims:/root/.local/bin:/usr/local/cuda/bin:$PATH"\n' >> /root/.bashrc

ARG JETSON_CODEX_BUILD_HASH=untracked
LABEL org.jetson-codex.build-hash="${JETSON_CODEX_BUILD_HASH}"
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=all
WORKDIR /workspace
ENTRYPOINT ["/opt/jetson-codex/entrypoint.sh"]
CMD ["bash", "-l"]
