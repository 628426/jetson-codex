# syntax=docker/dockerfile:1.7
# One ARM64 environment: native NVIDIA JetPack libraries + Codex Universal's toolchain inventory.
# Target host: Jetson Orin, JetPack 7.2 / L4T 39.2.
# NOT a rebuild of OpenAI's official image; this is an independently maintained port.
ARG JETPACK_IMAGE=nvcr.io/nvidia/deepstream:9.1-triton-multiarch
# Official static ARM64 mise binary, avoiding a build-time dependency on mise.run DNS.
FROM ghcr.io/jdx/mise:2026.10.4 AS mise-binary
FROM ${JETPACK_IMAGE}

SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HOME=/root \
    PIPX_BIN_DIR=/usr/local/bin \
    PIPX_HOME=/opt/pipx \
    MISE_TRUSTED_CONFIG_PATHS=/root/.config/mise \
    CARGO_HOME=/root/.cargo \
    RUSTUP_HOME=/root/.rustup \
    PHPENV_ROOT=/root/.phpenv \
    SWIFTLY_HOME_DIR=/root/.local/share/swiftly \
    UV_NO_PROGRESS=1
ENV PATH="/root/.phpenv/shims:/root/.phpenv/bin:/root/.local/share/mise/shims:/root/.local/bin:/root/.cargo/bin:/root/.swiftly/bin:/usr/local/cuda/bin:${PATH}"

# Noble (Ubuntu 24.04) packages. Official Jetson DeepStream 9.1 Triton image
# supplies CUDA 13.2, TensorRT, cuDNN, GStreamer plugins and DeepStream runtime.
# NVIDIA documents Jetson DeepStream containers as deployment-oriented: verify
# native SDK headers separately. VPI is installed explicitly below.
# Never upgrade the host BSP from inside a container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake bash-completion binutils bison build-essential \
    ca-certificates ccache clang clang-format clang-tidy cmake curl \
    default-libmysqlclient-dev dnsutils fd-find ffmpeg file gawk gdb \
    gettext git git-lfs gnupg gpg gstreamer1.0-tools \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    i2c-tools inotify-tools iputils-ping jq libatomic1 \
    libbz2-dev libcurl4-openssl-dev libdb-dev libedit-dev libffi-dev \
    libgd-dev libgdbm-compat-dev libgdbm-dev libgmp-dev libicu-dev \
    libjpeg-dev liblzma-dev libncurses-dev libnss3-dev libonig-dev \
    libpng-dev libpq-dev libreadline-dev libsqlite3-dev libssl-dev \
    libtidy-dev libunwind-dev libxml2-dev libxslt1-dev libyaml-dev \
    libzip-dev libz3-dev lsb-release make moreutils nasm netcat-openbsd \
    ninja-build openssh-client patch perl pipx pkg-config procps \
    protobuf-compiler python3-dev python3-pip python3-venv re2c rsync \
    software-properties-common sqlite3 sudo swig tk-dev tmux \
    tzdata universal-ctags unixodbc-dev unzip usbutils uuid-dev \
    v4l-utils wget xz-utils yasm zip zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# VPI is a separate JetPack SDK component. Require the NVIDIA VPI 4 packages;
# fail the build rather than quietly shipping a GPU-only image without VPI.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libnvvpi4 vpi4-dev \
    && rm -rf /var/lib/apt/lists/*

# Verify installed NVIDIA libraries without short-circuiting ldconfig.
# With pipefail, "ldconfig -p | grep -q" can return SIGPIPE (141) on a
# successful match because grep stops reading before ldconfig finishes.
# Save the complete list first so each check gives an accurate failure.
RUN command -v nvcc \
    && ldconfig -p > /tmp/jetson-ldconfig.txt \
    && for lib in libnvinfer.so libcudnn.so libnvvpi.so; do \
         if ! grep -F "$lib" /tmp/jetson-ldconfig.txt >/dev/null; then \
           echo "Missing NVIDIA SDK library: $lib" >&2; exit 1; \
         fi; \
       done \
    && rm /tmp/jetson-ldconfig.txt \
    && test -d /opt/nvidia/deepstream \
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
    && rm -rf /var/lib/apt/lists/* \
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
    && glab --version

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
    && rm -rf /var/lib/apt/lists/* \
    && az --version
ENV AZURE_EXTENSION_DIR=/opt/azure-cli-extensions
RUN mkdir -p "${AZURE_EXTENSION_DIR}" \
    && az extension add --name azure-devops --yes \
    && az extension show --name azure-devops --query name -o tsv

# Python: all versions in the upstream Codex Universal Dockerfile.
ARG PYTHON_VERSIONS="3.10 3.11.12 3.12 3.13 3.14.0"
RUN for v in ${PYTHON_VERSIONS}; do mise install "python@${v}"; done \
    && mise use --global python@3.12 \
    && for v in ${PYTHON_VERSIONS}; do \
         mise exec "python@${v}" -- python -m ensurepip --upgrade; \
         mise exec "python@${v}" -- python -m pip install --no-cache-dir \
           ruff black mypy pyright isort pytest; \
       done
RUN pipx install poetry && pipx install uv && pipx install cpplint \
    && pipx install cmakelang

# Node: upstream builds 18, 20, 22, 24, with formatter/linter tools.
ARG NODE_VERSIONS="18 20 22 24"
RUN for v in ${NODE_VERSIONS}; do \
      mise install "node@${v}"; \
      mise exec "node@${v}" -- npm install --global \
        typescript eslint prettier pnpm@10.12.1 yarn@1.22.22; \
    done \
    && mise use --global node@22

# Install Codex as an actual standalone native ARM64 executable.
# This remains callable even after changing the default Node version.
ARG CODEX_RELEASE=latest
RUN curl -fLSs "https://github.com/openai/codex/releases/${CODEX_RELEASE}/download/codex-aarch64-unknown-linux-musl.tar.gz" \
      -o /tmp/codex.tar.gz \
    && tar -xzf /tmp/codex.tar.gz -C /usr/local/bin \
    && mv /usr/local/bin/codex-aarch64-unknown-linux-musl /usr/local/bin/codex \
    && chmod 0755 /usr/local/bin/codex \
    && rm /tmp/codex.tar.gz \
    && codex --version

# Bun, as used by Codex Universal.
RUN mise install bun@1.2.14 && mise use --global bun@1.2.14

# Java, Gradle, Maven.  JDK 11 is intentionally excluded from the upstream
# ARM64 version; the JDK 17/21-25 set is installed here.
ARG JAVA_VERSIONS="25 24 23 22 21 17"
RUN for v in ${JAVA_VERSIONS}; do mise install "java@${v}"; done \
    && mise use --global java@21 \
    && mise install gradle@8.14 maven@3.9.10 \
    && mise use --global gradle@8.14 maven@3.9.10

# Rust: complete upstream version matrix + rustfmt + clippy.
ARG RUST_VERSIONS="1.95.0 1.94.0 1.93.0 1.92.0 1.91.1 1.90.0 1.89.0 1.88.0 1.87.0 1.86.0 1.85.1 1.84.1 1.83.0"
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain none \
    && for v in ${RUST_VERSIONS}; do \
      rustup toolchain install "${v}" --profile minimal \
        --component rustfmt --component clippy; \
    done \
    && rustup default 1.95.0

# Go and golangci-lint.
ARG GO_VERSIONS="1.25.1 1.24.3 1.23.8 1.22.12"
RUN for v in ${GO_VERSIONS}; do mise install "go@${v}"; done \
    && mise use --global go@1.25.1 \
    && mise install golangci-lint@2.1.6 \
    && mise use --global golangci-lint@2.1.6

# Ruby, Erlang, Elixir.
ARG RUBY_VERSIONS="3.4.4 3.3.8 3.2.3"
RUN for v in ${RUBY_VERSIONS}; do mise install "ruby@${v}"; done \
    && mise use --global ruby@3.4.4
ENV KERL_CONFIGURE_OPTIONS="--without-wx --without-javac"
# Erlang must be activated before Elixir's installation validation runs 'erl'.
# Keep it in its own Docker layer to preserve the expensive compilation cache.
RUN mise install erlang@27.1.2 \
    && mise use --global erlang@27.1.2 \
    && mise exec erlang@27.1.2 -- erl -noshell -eval 'halt().'
RUN mise exec erlang@27.1.2 -- mise install elixir@1.18.3-otp-27 \
    && mise use --global elixir@1.18.3-otp-27 \
    && mise exec erlang@27.1.2 -- elixir --version

# Bazelisk / bazel. See upstream's pinned version and release naming.
ARG BAZELISK_VERSION=v1.26.0
RUN curl -fLSs \
      "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-arm64" \
      -o /usr/local/bin/bazelisk \
    && chmod 0755 /usr/local/bin/bazelisk \
    && ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel

# PHP versions require compilation. This is a major part of the build time.
# Match upstream's 'snapshot' naming; they are NOT reproducible version pins.
ARG INSTALL_PHP=1
ARG PHP_VERSIONS="8.5 8.4 8.3 8.2"
RUN if [[ "${INSTALL_PHP}" == "1" ]]; then \
      git clone --depth 1 https://github.com/phpenv/phpenv.git "${PHPENV_ROOT}"; \
      git clone --depth 1 https://github.com/php-build/php-build.git \
        "${PHPENV_ROOT}/plugins/php-build"; \
      for v in ${PHP_VERSIONS}; do \
        MAKEFLAGS=-j2 phpenv install -s "${v}snapshot"; \
      done; \
      phpenv rehash; phpenv global 8.5snapshot; \
      curl -fLSs https://getcomposer.org/installer -o /tmp/composer-setup.php; \
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; \
      rm /tmp/composer-setup.php; \
    fi

# Swift toolchains are large on ARM64. Keep all requested versions, but
# cache each independently and never let swiftly init download an
# *additional* latest toolchain before the pinned versions are installed.
# Swift 5.10.1, 6.1.x, and 6.2.x have Ubuntu 24.04 aarch64 distributions.
ARG INSTALL_SWIFT=1
ARG SWIFT_VERSION_1=5.10
ARG SWIFT_VERSION_2=6.1
ARG SWIFT_VERSION_3=6.2
RUN if [[ "${INSTALL_SWIFT}" == "1" ]]; then \
      curl -fLSs https://download.swift.org/swiftly/linux/swiftly-aarch64.tar.gz \
        -o /tmp/swiftly.tar.gz; \
      mkdir -p /tmp/swiftly-extract; \
      tar -xzf /tmp/swiftly.tar.gz -C /tmp/swiftly-extract; \
      /tmp/swiftly-extract/swiftly init --assume-yes --skip-install --quiet-shell-followup; \
      test -f "${SWIFTLY_HOME_DIR}/env.sh"; \
      rm -rf /tmp/swiftly.tar.gz /tmp/swiftly-extract; \
    fi
# Print storage diagnostics before any multi-GB extraction. This checks
# Docker's writable filesystem, not a space estimate for the host root.
# 6 GiB is conservative headroom to avoid opaque "Write failed" errors.
RUN if [[ "${INSTALL_SWIFT}" == "1" ]]; then \
      source "${SWIFTLY_HOME_DIR}/env.sh"; \
      echo "Installing Swift ${SWIFT_VERSION_1} (version 1/3)"; \
      df -h /tmp "${SWIFTLY_HOME_DIR}"; df -i /tmp "${SWIFTLY_HOME_DIR}"; \
      available_kb="$(df -Pk /tmp | awk 'NR==2 {print $4}')"; \
      if (( available_kb < 6291456 )); then \
        echo "ERROR: Under 6 GiB free in Docker; Swift extraction needs more headroom." >&2; exit 1; \
      fi; \
      swiftly install "${SWIFT_VERSION_1}" --verbose; \
    fi
RUN if [[ "${INSTALL_SWIFT}" == "1" ]]; then \
      source "${SWIFTLY_HOME_DIR}/env.sh"; \
      echo "Installing Swift ${SWIFT_VERSION_2} (version 2/3)"; \
      df -h /tmp "${SWIFTLY_HOME_DIR}"; df -i /tmp "${SWIFTLY_HOME_DIR}"; \
      available_kb="$(df -Pk /tmp | awk 'NR==2 {print $4}')"; \
      if (( available_kb < 6291456 )); then \
        echo "ERROR: Under 6 GiB free in Docker; Swift extraction needs more headroom." >&2; exit 1; \
      fi; \
      swiftly install "${SWIFT_VERSION_2}" --verbose; \
    fi
RUN if [[ "${INSTALL_SWIFT}" == "1" ]]; then \
      source "${SWIFTLY_HOME_DIR}/env.sh"; \
      echo "Installing Swift ${SWIFT_VERSION_3} (version 3/3)"; \
      df -h /tmp "${SWIFTLY_HOME_DIR}"; df -i /tmp "${SWIFTLY_HOME_DIR}"; \
      available_kb="$(df -Pk /tmp | awk 'NR==2 {print $4}')"; \
      if (( available_kb < 6291456 )); then \
        echo "ERROR: Under 6 GiB free in Docker; Swift extraction needs more headroom." >&2; exit 1; \
      fi; \
      swiftly install "${SWIFT_VERSION_3}" --verbose; \
      swiftly use "${SWIFT_VERSION_3}"; \
      swift --version; \
    fi

# Native-device utilities are installed; device access is granted at runtime.
COPY setup-versions.sh verify.sh entrypoint.sh configure-full-trust.py codex-connect.sh hardware-check.sh /opt/jetson-codex/
RUN chmod 0755 /opt/jetson-codex/*.sh \
    && ln -sf /opt/jetson-codex/codex-connect.sh /usr/local/bin/codex-connect \
    && mkdir -p /workspace /root/.codex \
    && printf '\n# Jetson Codex development tools\nexport PATH="/root/.phpenv/shims:/root/.phpenv/bin:/root/.local/share/mise/shims:/root/.local/bin:/root/.cargo/bin:/root/.swiftly/bin:/usr/local/cuda/bin:$PATH"\n' >> /root/.bashrc
# Build fingerprint is injected by install.sh and added only at the end so
# documentation changes do not invalidate expensive language toolchain layers.
ARG JETSON_CODEX_BUILD_HASH=untracked
LABEL org.jetson-codex.build-hash="${JETSON_CODEX_BUILD_HASH}"
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=all
WORKDIR /workspace
ENTRYPOINT ["/opt/jetson-codex/entrypoint.sh"]
CMD ["bash", "-l"]
