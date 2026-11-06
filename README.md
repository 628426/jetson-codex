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
docker compose up -d --no-build
docker exec -it jetson-codex bash -l
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


Codex login persists in the `jetson-codex-auth` Docker volume. GitHub CLI and Git credential settings persist separately in `jetson-github-auth` and `jetson-git-config`. Both startup methods use the same named volumes.

**Build resource warning:** this is deliberately huge. Compiling four PHP versions, Erlang, Ruby and loading five Python versions, 13 Rust toolchains, six JDKs etc takes substantial disk, RAM, CPU and time. NVMe recommended; limit other workloads. If the Orin memory is tight, build with extra swap or on an ARM64 builder while retaining this target architecture. Do not claim completion until the image builds and `verify.sh` passes.

## Start, attach, stop and restart the named container

After a successful build, run these commands **on the Jetson host**:

```bash
cd ~/jetson-codex
docker compose up -d --no-build
docker ps --filter name=jetson-codex
docker exec -it jetson-codex bash -l
```

This starts a persistent container **named `jetson-codex`**. It uses
`sleep infinity` as its keepalive command, `restart: unless-stopped`
for Jetson reboots, the NVIDIA runtime for GPU access, and host networking
for JetPack's Docker firewall incompatibility. A shell opened with
`docker exec` is independent: **`exit` leaves the container running.**

From the Jetson host:

```bash
docker exec -it jetson-codex bash -l     # new shell
docker exec -it jetson-codex codex       # run Codex directly
docker logs --tail=100 jetson-codex      # container logs
docker stop jetson-codex                # stop
docker start jetson-codex               # start again
docker compose down                     # remove container, keep named auth volumes
```

If you change the Dockerfile, run `docker compose build` and then
`docker compose up -d --no-build --force-recreate`. `docker compose
down -v` **deletes authentication volumes**, so don't use `-v` unless
you deliberately intend to clear saved logins.

### Authenticate Codex with ChatGPT

Open a shell in the running container:

```bash
docker exec -it jetson-codex bash -l
codex login --device-auth
```

Open **https://auth.openai.com/codex/device** on another device, sign in
to your ChatGPT account, and enter the one-time code from the terminal.
Follow the URL printed by Codex if it differs. Test with:

```bash
codex login status
codex
```

### Authenticate the GitHub CLI with your GitHub account

Codex authentication and GitHub authentication are **separate**. The
container includes the official `gh` CLI and Git. In the container run:

```bash
gh auth login --hostname github.com --git-protocol https --web
```

Use the printed one-time code at **https://github.com/login/device** and
approve the GitHub CLI authorisation for account `628426`. A browser
inside the Jetson container is *not* required; open the URL on your
desktop or phone. Then:

```bash
gh auth status
gh auth setup-git
gh repo view 628426/jetson-codex
```

`gh auth setup-git` makes authenticated Git operations use the GitHub
CLI credential helper. Set the Git author identity to the name/email
associated with your GitHub account before making commits:

```bash
git config --global user.name "Your Name"
git config --global user.email "your-verified-github-email"
```

The GitHub login lives in `jetson-github-auth`; your global Git config
lives in `jetson-git-config`. They persist after `docker compose down`
and image rebuilds, without embedding a token in the image or a public
repository. GitHub CLI may store credentials in plain text inside that
Docker volume when no system keyring is available; protect root access to
your Jetson.

Example development session:

```bash
docker exec -it jetson-codex bash -l
cd /workspace
gh repo clone 628426/jetson-codex
cd jetson-codex
codex
```

Codex can now use Git and `gh` in its local execution environment.
It still uses your ChatGPT login for AI reasoning, and your GitHub
authorisation for repository operations.

## mise binary and DNS during Docker build

An older Dockerfile fetched the mise installer from `https://mise.run`.
If the Jetson or Docker build couldn't resolve that hostname, the build
failed with `curl: (6) Could not resolve host: mise.run`, regardless of
whether `apt-get` had succeeded. The current Dockerfile instead uses
the official ARM64 binary from `ghcr.io/jdx/mise:2026.10.4` as a
multi-stage `COPY`. No `mise.run` DNS lookup is needed.

After pulling updates, rebuild:

```bash
cd ~/jetson-codex
git pull --ff-only
docker compose build --progress=plain
```

If fetching the official image **also** fails, check DNS/registry reachability
from the Jetson host instead of changing Docker firewall rules blindly:

```bash
getent ahosts ghcr.io
getent ahosts github.com
getent ahosts cli.github.com
docker buildx imagetools inspect ghcr.io/jdx/mise:2026.10.4
```

A successful pull from Docker Hub or NVIDIA NGC does not prove that
every other registry or domain is reachable.

## JetPack Docker bridge networking

JetPack 6.2 / L4T 36.4.3 omits the Linux `CONFIG_IP_NF_RAW` firewall
table on some Jetson kernels. Docker Engine 28+ can fail while creating a
**bridge-network endpoint**, *before* executing a Dockerfile `RUN` command:

```text
Unable to enable DIRECT ACCESS FILTERING - DROP rule
iptables: can't initialize iptables table 'raw'
```

This repo avoids Docker's bridge for both **build** and **runtime**:
`compose.yaml` sets `build.network: host`, grants the
`network.host` build entitlement, and uses `network_mode: host`.
`run-hardware.sh` also launches with `--network=host`.
These choices are independent of CUDA / GPU device passthrough.

On the Jetson, pull the fix then rebuild:

```bash
cd ~/jetson-codex
git pull --ff-only
docker compose build --progress=plain
docker compose up -d --no-build
docker exec -it jetson-codex bash -l
```

**If BuildKit complains about the `network.host` entitlement** (including
some Compose/Buildx combinations), build directly with Buildx:

```bash
docker buildx build --network=host --allow=network.host \
  --platform linux/arm64 --load -t jetson-codex:jp62-full .
docker compose up -d --no-build
docker exec -it jetson-codex bash -l
```

An installed Docker Compose supporting build entitlements (2.27.1+) is
required for the first method. The Buildx fallback may require the chosen
builder daemon to permit `network.host`.

**Security:** host networking shares the Jetson's network namespace. Services
started inside the container can bind host interfaces and reach local services.
Do not run untrusted code or expose development servers publicly. This
workaround avoids weakening firewall isolation for every other Docker
container on the machine.

See [Docker's build networking reference](https://docs.docker.com/reference/compose-file/build/#network)
and [the Jetson-specific Moby issue](https://github.com/moby/moby/issues/50149).

## Device access

The default Compose container grants the GPU via NVIDIA runtime, but does *not* grant cameras, GPIO, serial devices or I²C. To start a **named persistent container** with detected host hardware devices, stop/remove the Compose-created container *without deleting volumes* and use the optional hardware launcher:

```bash
docker compose down
chmod +x run-hardware.sh
./run-hardware.sh
docker exec -it jetson-codex bash -l
```

Both launch paths use the name `jetson-codex`, so only one may exist at once.
The hardware script uses `-d` rather than `--rm`, retains credentials, and
maps detected devices when the container is created. If you later attach new
USB hardware, recreate the hardware container to refresh device mappings.

The hardware script inspects existing `/dev/video*`, `/dev/i2c-*`, `/dev/gpiochip*`, `/dev/ttyUSB*`, and `/dev/ttyACM*` nodes, and passes each into the container. CSI camera access may also require `/tmp/argus_socket`, which is mounted only if present. Access still depends on device permissions, driver compatibility, and the specific camera interface. It does **not** grant blanket `--privileged` access. Both launch methods use the same explicitly named `jetson-codex-auth` Docker volume.

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

Specify them in the Compose `environment:` section (or as `docker run -e KEY=value ...` for a standalone launcher). The values must be preinstalled by the Dockerfile.

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

Codex is a privileged *developer* inside its container, not a host admin. The default launch shares the Jetson's network namespace to work around the JetPack kernel issue. Avoid mounting `/var/run/docker.sock`, `/`, or `--privileged`, especially if running Codex without sandboxing. Binding hardware devices deliberately means code in this workspace can act on them. Do not bake tokens into the Dockerfile. `codex login --device-auth` uses an interactive login and stores credentials in the volume.

## References

- https://github.com/openai/codex-universal/blob/main/Dockerfile
- https://github.com/openai/codex
- https://mise.jdx.dev/mise-cookbook/docker.html
- https://cli.github.com/manual/gh_auth_login
- https://cli.github.com/manual/gh_auth_setup-git
- https://catalog.ngc.nvidia.com/orgs/nvidia/containers/l4t-jetpack
- https://docs.nvidia.com/metropolis/deepstream/7.1/text/DS_Installation.html
- https://www.swift.org/install/linux/ubuntu/22_04/

## Project status

This repository publishes the **Docker build sources**, not a prebuilt Docker image. The full image must be built and hardware-verified on a Jetson Orin or equivalent ARM64 builder. Successfully running `docker compose build` and `/opt/jetson-codex/verify.sh` on your actual device is the acceptance test.

The image is intentionally extensive. If the full build fails at a particular upstream installer, check the installer and CPU/RAM requirements. Both PHP and Swift are enabled by default; they can be temporarily excluded when diagnosing a build using `docker build --build-arg INSTALL_PHP=0 --build-arg INSTALL_SWIFT=0 ...`, but such a build is **not** the full inventory.
