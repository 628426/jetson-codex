# Jetson Codex Ultimate

**Goal:** One native ARM64 developer container for Jetson Orin, with NVIDIA JetPack userland, GPU support, Codex CLI, and the complete *language/toolchain inventory* from OpenAI's `codex-universal` Dockerfile as reviewed 6 November 2026.

**Host target:** JetPack 6.2 (L4T 36.4.3), Ubuntu 22.04, arm64. **NVIDIA base:** `nvcr.io/nvidia/l4t-jetpack:r36.4.0` (NVIDIA's latest published `l4t-jetpack` tag). JetPack base includes CUDA, cuDNN, TensorRT, VPI and multimedia libraries. DeepStream is *not* bundled with JetPack.

This is an independently authored ARM64 port, **not OpenAI's official Codex Universal image**. Tool *presence* and selectable language versions are the target; exact package versions and behaviour need validation. It has **not been built or tested on your Orin**.

## Install (on your Orin)

1. Ensure Docker, the Compose plugin, and the NVIDIA container runtime are installed: `docker compose version` and `docker info | grep -A3 Runtimes` (look for `nvidia`).
2. Clone this repository onto your Jetson Orin and build:

```bash
git clone https://github.com/628426/jetson-codex.git
cd jetson-codex
mkdir -p workspace
docker compose build --progress=plain
docker compose run --rm jetson-codex bash -l
```

3. In ChatGPT settings, ensure **device code login is enabled** under your security settings (or allowed by your workspace administrator). Then, inside the container, authenticate using **device-code login** (recommended for headless Jetsons):

```bash
codex login --device-auth
```

4. The terminal prints a verification URL and one-time code. Open **https://auth.openai.com/codex/device** in a browser on your laptop or phone, sign into the ChatGPT account you want linked, enter the **code printed by your own Codex CLI**, and approve. Do not paste the code into GitHub issues or share it. The CLI will confirm when authentication completes. The URL should match what Codex itself prints; follow that if OpenAI changes it.

5. Verify the login, check toolchains and start Codex:

```bash
codex login status
/opt/jetson-codex/verify.sh
codex
```

You can now ask Codex to inspect `/workspace`, compile software and run hardware-facing tests. The ChatGPT sign-in uses your Codex entitlement, not a separately created OpenAI API key. An Internet connection is required for Codex's hosted reasoning.


Logins persist in a Docker named volume, shared by Compose and `run-hardware.sh`.

**Build resource warning:** this is deliberately huge. Compiling four PHP versions, Erlang, Ruby and loading five Python versions, 13 Rust toolchains, six JDKs etc takes substantial disk, RAM, CPU and time. NVMe recommended; limit other workloads. If the Orin memory is tight, build with extra swap or on an ARM64 builder while retaining this target architecture. Do not claim completion until the image builds and `verify.sh` passes.

## Device access

`docker compose run` grants the GPU via NVIDIA runtime, but does *not* grant cameras, GPIO, serial devices or I²C. For those use:

```bash
chmod +x run-hardware.sh
./run-hardware.sh
```

This inspects existing `/dev/video*`, `/dev/i2c-*`, `/dev/gpiochip*`, `/dev/ttyUSB*`, and `/dev/ttyACM*` nodes, and passes each into the container. CSI camera access may also require `/tmp/argus_socket`, which is mounted only if present. Access still depends on device permissions, driver compatibility, and the specific camera interface. It does **not** grant blanket `--privileged` access. Both launch methods use the same explicitly named `jetson-codex-auth` Docker volume.

## Version selectors

These follow the upstream environment variable conventions (but switch versions using `mise` rather than OpenAI's exact `pyenv`/`nvm` implementation):

```
CODEX_ENV_PYTHON_VERSION=3.12
CODEX_ENV_NODE_VERSION=22
CODEX_ENV_RUBY_VERSION=3.4.4
CODEX_ENV_RUST_VERSION=1.95.0
CODEX_ENV_GO_VERSION=1.25.1
CODEX_ENV_JAVA_VERSION=21
CODEX_ENV_PHP_VERSION=8.5
CODEX_ENV_SWIFT_VERSION=6.2
```

Specify them with `docker compose run -e KEY=value ...` or in the `environment:` section. The values must be preinstalled by the Dockerfile.

## Complete inventory targeted

| Component | Versions / features |
|---|---|
| Python | 3.10, 3.11.12, 3.12, 3.13, 3.14.0; Poetry, uv, Ruff, Black, mypy, pyright, isort, pytest |
| Node | 18, 20, 22, 24; npm, pnpm, Yarn, TypeScript, ESLint, Prettier |
| Rust | 1.83.0, 1.84.1, 1.85.1, 1.86.0, 1.87.0, 1.88.0, 1.89.0, 1.90.0, 1.91.1, 1.92.0, 1.93.0, 1.94.0, 1.95.0; Clippy, rustfmt |
| Go | 1.22.12, 1.23.8, 1.24.3, 1.25.1; golangci-lint |
| Java | 17, 21, 22, 23, 24, 25; Gradle 8.14; Maven 3.9.10 |
| Ruby | 3.2.3, 3.3.8, 3.4.4 |
| PHP | 8.2, 8.3, 8.4, 8.5 source snapshots; Composer. `INSTALL_PHP=1` |
| Swift | 5.10, 6.1, 6.2, where ARM64 installer works. `INSTALL_SWIFT=1` |
| Erlang/Elixir | Erlang 27.1.2; Elixir 1.18.3-otp-27 |
| Others | Bun 1.2.14, Bazelisk 1.26.0, GCC, Clang, Clang-Tidy/Format, CMake, Ninja, NASM, GDB, SWIG, Protobuf, SQLite, git, git-lfs, jq, ripgrep (see note), rsync, Git tooling, SSH, GStreamer, V4L2, GPIO, I²C |
| NVIDIA | JetPack CUDA, cuDNN, TensorRT, VPI, Jetson multimedia development libraries, video/device utilities |
| Codex | OpenAI Codex standalone ARM64-musl release binary, independently of Node |

**Gap vs exact OpenAI environment:** `codex-universal` uses Ubuntu **24.04**; this uses NVIDIA's **22.04**. `mise` replaces upstream `pyenv`/`nvm`, so those exact managers are absent. The upstream ARM64 reference excludes Swift, but this image attempts Swift via its supported ARM64 binaries. The upstream docs also conflict with its Dockerfile for Node24/PHP8.5, so this file uses the Dockerfile versions. `ripgrep` is installed by apt as `rg` (Ubuntu version differs). Java 11 is not part of OpenAI's ARM64 JDK set. Build failures on upstream download/toolchain combinations must be fixed, not silently ignored.

## Hardware checks

`/opt/jetson-codex/verify.sh` checks the installed CLI/toolchains and calls the real CUDA driver to count GPU devices. `nvcc --version` alone proves only that the compiler is present, **not** that CUDA works. `nvidia-smi` is not a reliable Jetson health test.

DeepStream 7.1 targets JetPack 6.1 / L4T 36.4.0 and is a separate installer/container. It is **not** included here because your JetPack 6.2 / L4T 36.4.3 pairing has not been certified by NVIDIA for DeepStream 7.1. Install/test DeepStream as a separate, pinned layer once the core runtime passes. Newer DeepStream 9.x requires a newer JetPack generation.

## Security

Codex is a privileged *developer* inside its container, not a host admin. Avoid mounting `/var/run/docker.sock`, `/`, or `--privileged`, especially if running Codex without sandboxing. Binding hardware devices deliberately means code in this workspace can act on them. Do not bake tokens into the Dockerfile. `codex login --device-auth` uses an interactive login and stores credentials in the volume.

## References

- https://github.com/openai/codex-universal/blob/main/Dockerfile
- https://github.com/openai/codex
- https://catalog.ngc.nvidia.com/orgs/nvidia/containers/l4t-jetpack
- https://docs.nvidia.com/metropolis/deepstream/7.1/text/DS_Installation.html
- https://www.swift.org/install/linux/ubuntu/22_04/

## Project status

This repository publishes the **Docker build sources**, not a prebuilt Docker image. The full image must be built and hardware-verified on a Jetson Orin or equivalent ARM64 builder. Successfully running `docker compose build` and `/opt/jetson-codex/verify.sh` on your actual device is the acceptance test.

The image is intentionally extensive. If the full build fails at a particular upstream installer, check the installer and CPU/RAM requirements. Both PHP and Swift are enabled by default; they can be temporarily excluded when diagnosing a build using `docker build --build-arg INSTALL_PHP=0 --build-arg INSTALL_SWIFT=0 ...`, but such a build is **not** the full inventory.
