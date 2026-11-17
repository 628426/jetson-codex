# Jetson Codex Ultimate

**Goal:** A lean native ARM64 Jetson Codex development container with NVIDIA GPU/video SDKs, C/C++, system Python 3.12, Node.js and persistent Git/cloud connections.

**Host target:** JetPack 7.2.0 (L4T R39.2.0), Ubuntu 24.04, arm64. **Base:** NVIDIA CUDA 13.2.1 + cuDNN *development* image. TensorRT 10.16 and VPI 4 are installed from NVIDIA's Jetson r39.2 SDK repository; the standalone DeepStream 9.1 Jetson SDK comes from NVIDIA's GitHub release. **No Triton Inference Server.**

This is an independently authored ARM64 development image, **not OpenAI's official Codex Universal image**. It intentionally provides a narrower, leaner toolset. The complete Docker build and NVIDIA hardware tests still need validation on the Orin.

## Quick start: Windows PowerShell (OneDrive / Google Drive login)

**Use this command from Windows** when configuring cloud access on the
headless Jetson. It runs the same installer, but forwards the browser's OAuth
callback to the Jetson over SSH.

```powershell
ssh -tt -o ExitOnForwardFailure=yes -L 53682:127.0.0.1:53682 dex@192.168.0.80 'export RCLONE_SSH_TUNNEL=1; curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash'
```

When prompted to connect OneDrive or Google Drive, choose **Y**. Open the
`http://127.0.0.1:53682/...` link printed by rclone in your **Windows
browser**, approve access, and return to the terminal. No second program,
manual token copy, or SSH session is needed.

Replace `dex@192.168.0.80` with your own Jetson username and LAN IP on
other devices. Once cloud access is linked, credentials persist.

For ordinary installation or reruns from an existing **Jetson SSH terminal**
without new cloud authorisation:

```bash
curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash
```

## One smaller container, real NVIDIA hardware

The image provides **native Codex CLI, CUDA C/C++ development, cuDNN,
TensorRT 10 engine building and inference, DeepStream 9.1, VPI, GStreamer,
RTSP/NVDEC and Jetson I/O** in one headless environment.

Unlike the old `9.1-triton-multiarch` base, it starts from:

```text
nvidia/cuda:13.2.1-cudnn-devel-ubuntu24.04
```

Then it installs just NVIDIA's JetPack 7.2 TensorRT/VPI development packages
and extracts `deepstream_sdk_v9.1.0_jetson.tbz2`.

**TensorRT dependency pin:** The general CUDA repository also advertises
TensorRT 11.x for newer CUDA releases, which conflicts with JetPack 7.2's
`nvidia-tensorrt` packages. Both Dockerfiles pin `tensorrt`,
`tensorrt-libs` and their transitive libraries to
`10.16.2.10-1+cuda13.2` at APT priority 1001. The build prints the
package candidates, refuses an unavailable pinned version, and verifies
the installed version before continuing. Do not remove this pin unless
the JetPack/TensorRT compatibility matrix changes. Downloaded archives and
bundled sample videos are removed **within their build layer**. The previous
Triton Dockerfile remains as a non-default
[rollback source](Dockerfile.jetpack-7.2.0.triton-legacy).

**No host CUDA directory bind mounts** are required. The NVIDIA container
runtime exposes compatible GPU drivers and hardware devices; the SDK and
development headers live in the image. No build toolchains are installed
on the Jetson host.

A smaller base is not itself proof of compatibility. After building, the
installer still requires all these acceptance tests:

- CUDA driver access and matching host/container GPU device counts.
- H.264 and H.265 hardware decoding through `nvv4l2decoder`.
- DeepStream GStreamer plugins `nvinfer`, `nvstreammux`, `nvtracker`,
  `nvvideoconvert`; actual headless NVMM processing.
- A compiled TensorRT 10 C++ smoke test that builds a network and executes
  GPU inference via `enqueueV3`.

On `dexson`, individual tests can be repeated with:

```bash
docker exec jetson-codex bash /opt/jetson-codex/hardware-check.sh --tensorrt
docker exec jetson-codex bash /opt/jetson-codex/hardware-check.sh --deepstream
docker exec jetson-codex bash /opt/jetson-codex/hardware-check.sh --video
```

These tests verify real TensorRT GPU execution and DeepStream pipeline
components, but do not yet prove an arbitrary model/config or custom
DeepStream plugin build. NVIDIA calls its prebuilt Jetson DeepStream
containers deployment-oriented. This separately assembled developer image
requires its own acceptance testing, and **has not yet passed a live build
on `dexson`**.

References:
- [NVIDIA DeepStream 9.1 release assets](https://github.com/NVIDIA/DeepStream/releases/tag/v9.1.0)
- [NVIDIA JetPack 7.2 SDK versions](https://developer.nvidia.com/embedded/jetpack/downloads/archive-7.2)
- [NVIDIA DeepStream Docker guidance](https://docs.nvidia.com/metropolis/deepstream/9.1/text/DS_docker_containers.html)

## Version-specific Dockerfile selection

The installer now reads `/etc/nv_tegra_release` and selects a Dockerfile
**before building**. Currently supported:

| Detected L4T | JetPack | Dockerfile | Image tag |
|---|---|---|---|
| R39.2.0 | 7.2.0 | [Dockerfile.jetpack-7.2.0](Dockerfile.jetpack-7.2.0) | `jetson-codex:jp72-full` |

This matches the **Seeed J401 / Orin Nano 8GB** firmware reported by the
original device. The script refuses unknown versions rather than accidentally
building a container for the wrong JetPack. The original `Dockerfile` remains
for backwards compatibility, but the installer explicitly selects the versioned
file. Compose accepts `JETSON_CODEX_DOCKERFILE` and
`JETSON_CODEX_IMAGE` overrides, both set automatically by `install.sh`.

Direct manual build (without installer):

```bash
# For the complete setup, use install.sh (builds base, starts the container,
# then provisions the full JetPack development SDK in its writable layer).
bash ./install.sh
```

**Note:** The base image contains CUDA/cuDNN and mise only. The full SDK is
installed **after** container creation. Do not delete/recreate the container
without accepting loss of its locally installed packages.

## Codex full trust

The installer automatically persists these Codex settings in the named
`jetson-codex-auth` volume:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

Codex therefore **does not ask for command approvals** and can read/write
the container filesystem and mounted workspace. These settings survive
container recreation. They do **not** give Codex unrestricted access to
the Jetson host filesystem, but the container uses host networking and
passes through detected hardware devices. Only run trusted repositories
and prompts with this setting.

## Cloud account linking from a Windows PC

**Microsoft and Google require the OAuth redirect URI at
`http://localhost:53682/`.** Changing it to the Jetson's LAN address will
not work with rclone's shared OAuth application registrations. See
[rclone's remote setup documentation](https://rclone.org/remote_setup/).

The full Windows PowerShell command is also at the top under **Quick start**.
It is the preferred method when linking cloud storage from a headless Jetson:

```powershell
ssh -tt -o ExitOnForwardFailure=yes -L 53682:127.0.0.1:53682 dex@dexson 'export RCLONE_SSH_TUNNEL=1; curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash'
```

The installer runs on the Jetson as normal. During OneDrive/Google Drive
setup, it automatically answers **Y** to rclone's browser prompt. Click
the `http://127.0.0.1:53682/auth?state=...` URL in your **Windows browser**.
The SSH connection forwards both the login page and OAuth callback to rclone
on the Jetson. **No Windows rclone installation, token copying, or second
terminal is needed.**

The standard Jetson-side installer remains supported for already-linked
cloud storage or when cloud storage is declined. If you request a new cloud
connection without SSH OAuth forwarding, it **prints the Windows PowerShell
SSH command and pauses before building Docker**. It does not continue into
the multi-GB image build until the cloud connection is completed.
Once linked, credentials persist on the host, so future runs do not
require OAuth.

### Rclone health checks and interactive recovery

Every installer run with existing cloud configuration checks
`rclone lsf` against the remote, the systemd user service, the FUSE
`mountpoint`, and **actual directory listings both as the invoking user and
as root**. The last check matters: Docker's daemon runs as root, and an
ordinary user-only FUSE mount can appear healthy to `dex` but fail with
`mkdir /home/dex/jetson-codex-cloud: file exists` on Docker startup.

The host cloud service uses `--allow-other --default-permissions` with
`0700` directory and `0600` file permissions. The rclone FUSE backend in
this environment ignores `--allow-root`. Root can traverse the mount for
Docker, while unprivileged host users are restricted by the kernel.
`configure-storage.sh` enables `user_allow_other` in `/etc/fuse.conf`.

The hardware launcher uses Docker's **explicit `--mount type=bind`** and
never tries to `mkdir` an existing FUSE mountpoint. Docker Compose uses
`bind.create_host_path: false`. A failed container creation is **not**
auto-deleted: inspecting or manually removing a failed instance avoids
accidentally discarding a populated writable layer.

If any check fails, installation **pauses before building Docker** and asks:

1. Repair FUSE/Docker access and restart the cloud mount.
2. Reconnect the existing OneDrive/Google Drive OAuth token in your browser.
3. Reconfigure the remote or cloud project folder.
4. Abort without changing the Docker container.

The first rerun after this change may detect that the existing rclone
mount was started without Docker-readable permissions. Choose **1** to restart it
with the corrected permissions. Do this after pending cloud uploads
complete; nothing requires rebuilding the existing CUDA/TensorRT image.

Options 2 and 3 require the Windows SSH redirect (shown above). Without it,
the installer prints the exact PowerShell command instead of proceeding.
Failed attempts return to the menu. The script never runs `rm -rf` on the
cloud mount and refuses to force-unmount a busy filesystem. Pending VFS
write-back operations must finish before intentionally restarting the mount.

## Cloud-backed projects and repeatable health checks

The installer can configure **OneDrive or Google Drive** as the persistent
cloud root using `rclone config` OAuth. When cloud setup is selected, it
**pauses Docker installation until login, cloud access and the FUSE mount
are verified**. The installer manages these minimal host prerequisites:

```bash
sudo apt install rclone fuse3
```

Cloud project files appear in the container at `/workspace/projects`.
For example, selecting `OneDrive:/Codex` exposes:

```text
/workspace/projects/Smart-Home/    # Cloud-backed documents, scripts, outputs
/workspace/projects/LOTFA/         # Cloud-backed documents, scripts, outputs
/workspace/source/                 # Local NVMe Git working trees
```

**Files Codex creates under `/workspace/projects` are written through to
the cloud** using rclone's VFS write-back cache. Files are fetched on demand.
The cache is capped at 2 GiB for clean files, but pending uploads and active
files may temporarily exceed that limit. Writes are asynchronous: wait for
uploads to complete before powering off or deleting the local cache. This is
not an atomic or transactional filesystem. Do not use it for Git repositories,
databases, SQLite files or build directories.

The host mount is managed by the user systemd service
`jetson-codex-cloud.service`, with configuration at
`~/.config/jetson-codex/storage.env`. For automatic startup before login,
run `sudo loginctl enable-linger "$USER"` once. rclone OAuth credentials
remain on the host in `~/.config/rclone/rclone.conf`; they are **not**
mounted into the Codex container. Codex accesses the mounted files, not the
OAuth tokens. Note that full-trust Codex can still modify or delete files
in the selected cloud root, and those changes propagate.

GitHub source lives under `/workspace/source/<project>` as a normal local
Git checkout, and pushes to GitHub for durable storage. Generated scripts
and documents that must live in OneDrive/Drive should be written under
`/workspace/projects/<project>`. Native Google Docs/Sheets require their
respective APIs for true editing.

```bash
# Reconfigure the cloud provider or folder
bash ~/jetson-codex/configure-storage.sh --reconfigure

# Reapply the mount service after changing configuration
bash ~/jetson-codex/configure-storage.sh --mount

# Run the one-command installer again to reconcile and verify setup
bash ~/jetson-codex/install.sh
```

Normal reruns reuse the minimal CUDA base image and the **same post-provisioned
container writable layer**, without reinstalling unchanged packages. The
installer verifies Docker, CUDA, media, Codex, Git CLIs and cloud access.

## Automatic updates and full-trust verification

The installer now offers **Ubuntu unattended security updates**, using
`unattended-upgrades`, daily APT timers and weekly APT cache cleaning.
It invokes `sudo` only for host configuration. The same no-argument installer
rebuilds the minimal CUDA base only when its Dockerfile changes; changes
to `provision-container.sh` are applied within the existing container.
JetPack BSP upgrades and untracked upstream tool releases remain manual.

The health checker now parses `/root/.codex/config.toml` using Python
`tomllib` and requires `approval_policy="never"` and
`sandbox_mode="danger-full-access"`. It also checks the Codex executable,
CUDA compiler and developer tools. These are static/runtime presence checks,
not an end-to-end Codex agent command execution test.

## Completely uninstall and retest

Use the **single installer flag** `--uninstall`. This is intentionally
destructive: it removes the persistent container and post-installed SDK,
both `jetson-codex` image tags, all six credential volumes, local rclone
cache, the cloud-mount user service, and the entire verified local checkout
**including `workspace/source`**. It also clears shared BuildKit cache
(including cache owned by *other* Docker projects).

On dexson:

```bash
bash ~/jetson-codex/install.sh --uninstall
```

Or when the checkout is missing, using the same installer from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash -s -- --uninstall
```

From Windows PowerShell:

```powershell
ssh -tt dex@192.168.0.80 'curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash -s -- --uninstall'
```

**Confirmation is required.** Read the scope, make sure any rclone VFS
uploads are finished, and type exactly `ERASE jetson-codex`. If the
confirmation is missing or the checkout/container belongs to another
project, the command refuses to proceed. A partially completed uninstall
can be rerun safely.

**Never deletes cloud files.** Shared `~/.config/rclone/rclone.conf`,
`/etc/fuse.conf`, Docker/NVIDIA runtime installation and host unattended
security updates remain. The rclone remote itself may be reused by other
tools. A subsequent installation can reuse its saved OAuth grant.

To reinstall from scratch:

```bash
curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash
```

The new container starts from the minimal CUDA base, provisions the full SDK
inside its persistent writable filesystem, then offers ChatGPT pairing after
Codex sign-in. Do not use `docker compose down` as a reset: it would remove
the SDK filesystem without cleaning up associated credentials/configuration.

## Azure CLI download and DNS recovery

Azure CLI and the Azure DevOps extension are installed **after** the container
starts, not in the CUDA base image. An intermittent failure resolving
`packages.microsoft.com` does **not** mean the NVIDIA SDK needs rebuilding.

The installer now downloads Microsoft's signing key into a temporary file,
retries DNS/TLS failures with a bounded timeout, verifies the published
Microsoft signing-key fingerprint, then atomically replaces the APT keyring.
A failed download leaves the existing key and APT sources untouched. It
checks installed tools on each rerun, so successful GitHub/GitLab/DeepStream
steps are preserved.

If Azure download fails, check name resolution from both environments:

```bash
getent ahostsv4 packages.microsoft.com
docker exec jetson-codex getent ahostsv4 packages.microsoft.com
docker exec jetson-codex cat /etc/resolv.conf
```

If the host succeeds but the container fails, investigate Docker's generated
`/etc/resolv.conf` and the nameserver it lists. With host networking, the
container still has its own resolver file. Do **not** blindly change the host
DNS or remove the persistent Docker container.

Once connectivity returns, use the same installer:

```bash
curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash
```

The provisioner resumes after the last successful package group; it does not
duplicate an image or delete previously installed tools. If the network is
still unavailable, it fails clearly and retains the container for another try.

## One command, every time

Run the same command for initial setup, repair and health checks:

```bash
curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash
```

No flags. The installer detects JetPack, uses the invoking Linux account
for persistent files and OAuth, configures Docker access with sudo if
needed, installs the NVIDIA runtime and unattended security updates,
reuses an existing image and healthy container, links accounts when
needed, and runs integrated health checks. It does not create a second
service account: the invoking user is the inspectable owner of the
installation. Docker group access is root-equivalent.

The installer separately fingerprints the minimal base Dockerfile and the
post-start provision script. The CUDA base image is built when needed; the
running container gets missing SDK packages through `docker exec`. No
`docker commit`, `docker save` or duplicate full-size exported image.

## Orin CUDA CDI hook crash on JetPack 7.2 (R39.2)

If Docker fails at `createContainer hook #2` with
`nvidia-cdi-hook/cudacompat/cuda-elf-header.go:100` or
`slice bounds out of range [:73] with capacity 71`, the failure occurs
**on the host**, before a container can run. It is an NVIDIA Container
Toolkit bug: the CUDA compatibility ELF header on Orin triggered this panic.
NVIDIA fixed it in **Container Toolkit 1.19.1**. This is not a rclone,
GPU device-mapping or container APT problem.

The previous full image also **purged `cuda-compat-13-2` and
`cuda-compat-orin-13-2` before startup**. The minimal image initially
omitted that safeguard. It now performs only this conditional removal in
its Dockerfile, prior to OCI startup; all heavyweight package installation
still occurs after the persistent container starts.

The installer checks the host's four Nvidia toolkit packages on every run:
`nvidia-container-toolkit`, `nvidia-container-toolkit-base`,
`libnvidia-container-tools` and `libnvidia-container1`. If all are
1.19.1 or newer, it makes **no changes**. If any are older/missing, it
refreshes the configured APT repositories, verifies that all four have
the same fixed candidate version, simulates the transaction, refuses
package removals, then installs exactly those four packages. It does **not**
upgrade JetPack, drivers, CUDA or unrelated host software.

Inspect the installed package versions without changing anything:

```bash
dpkg-query -W nvidia-container-toolkit nvidia-container-toolkit-base \
  libnvidia-container-tools libnvidia-container1
```

To retry after a corrected host-toolkit installation:

```bash
bash ~/jetson-codex/install.sh
```

An OCI startup failure may have left a `Created` container. On an
**unchanged** base, the launcher retries starting that same container. When
the base Dockerfile changes, the installer automatically removes an owned
container **only if** Docker confirms its state is `created` and PID 1 has
never started. Anything that might contain post-installed SDK changes
requires explicit migration (`JETSON_CODEX_MIGRATE=1`). If the configured APT repositories lack a consistent fixed
toolkit, the installer stops instead of introducing a driver mismatch.

Sources: [NVIDIA 1.19.1 release notes](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/1.19.1/release-notes.html)
and [Jetson R39.2 reproduction](https://forums.developer.nvidia.com/t/cuda-13-2-1-runtime-image-cant-run-on-r39-2-sample-rootfs-for-orin-nano/372683).

## Jetson accelerator passthrough and hardware verification

The single installer now inventories **both the Jetson host and the running
Docker container**. It explicitly maps only detected character devices
through `--device`, including `/dev/nvhost*`, `/dev/nvmap`, NVIDIA
render/GPU devices, cameras, media nodes, I²C, SPI, GPIO and USB serial.
The NVIDIA container runtime supplies compatible GPU driver integration;
the Argus camera socket is mounted when present.

On every run, `install.sh`:

1. Inventories eligible character devices on the host, without installing
   multimedia/development packages.
2. Compares host device nodes with **explicit Docker device mappings**.
   If mappings have changed, it stops safely rather than recreating the
   container and silently deleting installed packages.
3. Compares the available host and container device nodes.
4. Calls the CUDA **driver API** on both host and container and compares the
   discovered GPU counts when the host supports the probe.
5. Inside Docker, generates small H.264/H.265 clips with CPU FFmpeg encoders
   and actually decodes them through GStreamer's `nvv4l2decoder`.
   **An installed decoder plugin alone does not count as passing.**

**Orin Nano 8GB has NVDEC and VIC, but no NVENC hardware encoder.**
H.264/H.265 *decoding* uses the supported NVIDIA hardware when the smoke
test passes. *Encoding* uses CPU `libx264` / `libx265` inside Docker.
If your workload requires hardware encoding, the Orin Nano cannot provide
it through any software or Docker passthrough change. The Orin NX has
NVENC hardware, but requires different hardware and suitable configuration.
See [NVIDIA's Orin Nano software encoding guide](https://docs.nvidia.com/jetson/archives/r38.4/DeveloperGuide/SD/Multimedia/SoftwareEncodeInOrinNano.html).

The NVIDIA runtime, driver versions, active kernel devices and SDK libraries
must still match. An actual H.264/H.265 smoke test on `dexson` is the
acceptance criterion. These tests have not yet been run on the physical
machine. We do not pass `--privileged`, mount the host root directory,
or expose the Docker socket.

## Persistent Git provider connections

The Jetson Codex container now has **Git, Git LFS, GitHub CLI (`gh`),
GitLab CLI (`glab`), Azure CLI (`az`) and the Azure DevOps extension**.
One installer command still provisions and repairs everything. After
first installation it offers a one-time menu to link additional providers.
You can reopen that menu without rebuilding:

```bash
docker exec -it jetson-codex codex-connect
```

| Provider | Git clone/push | Repository management |
|---|---|---|
| GitHub.com | SSH (Ed25519) | `gh` issues, pull requests, releases |
| GitHub Enterprise Server | Per-host SSH (Ed25519) | `gh --hostname` / `GH_HOST` |
| GitLab.com | SSH (Ed25519) | `glab` issues, merge requests, pipelines |
| GitLab Self-Managed | Per-host SSH (Ed25519) | `glab` for supported instances |
| Bitbucket Cloud | SSH (Ed25519) | Git push/pull; API/PR access needs separate authorisation |
| Azure DevOps Services | SSH (**RSA 3072, RSA-SHA2**) | `az repos`, `az boards`, `az pipelines` |

A separate SSH key is created for each provider/host. The public key is
either uploaded using `gh`/`glab` after device-code login or displayed
for addition to your Bitbucket/Azure account. Private keys never leave
the container's persistent Docker SSH volume. The menu can connect
private GitHub Enterprise or GitLab hosts by DNS name, and it never
overwrites an existing key.

Git credentials are preserved in named Docker volumes
(`jetson-github-auth`, `jetson-codex-gitlab-auth`,
`jetson-codex-azure-auth`, `jetson-codex-git-ssh`).
Unattended SSH uses **unencrypted, host-specific private keys** inside
the protected volume, and depends on the remote account's access control.
Protect Docker access and back up the volumes securely. Your Git repository
working trees stay in `/workspace/source` on NVMe, not the cloud FUSE
directory; scripts and documents can be written to `/workspace/projects`
for OneDrive/Google Drive write-back.

**Important:** Azure DevOps Services accepts RSA keys for Git SSH, not
Ed25519. Azure DevOps Server (on-premises) is not supported by Microsoft's
`az devops` extension, though Git SSH access to an on-prem server can be
configured separately. GitLab Self-Managed OAuth device flow requires an
instance version and application configuration that supports it; otherwise
the menu offers an interactive personal access token alternative.
GitHub Enterprise may also require your administrator to enable
the chosen authentication method. Organisation policies, branch
protections, token expiration and provider consent still apply.

**Update behaviour:** `install.sh` fingerprints the lightweight base
separately from `provision-container.sh`. It preserves the container's
writable layer across reruns. This architecture still requires validation
on the actual ARM64 Jetson.

## Early Docker disk-space warning

Before downloading or building Docker images, the installer checks free
space on the filesystem holding Docker's configured `DockerRootDir`.
This works even when Docker stores its layers on a different partition
from `/`. There is no new host package.

The new CUDA/cuDNN + TensorRT + DeepStream image's final size is
**not yet measured on dexson**. The installer uses a **24 GiB advisory
build-headroom allowance** and warns below **48 GiB free**. This is an
estimate, not a guarantee. The warning doesn't stop Docker or delete
anything. Actual image size is reported when the container starts.

## Peak-disk-optimised container design

Peak disk consumption, not just final image size, is the primary constraint.

1. Build a lightweight CUDA/cuDNN base image, without large APT runs.
2. Start one persistent Docker container with read-only provisioning scripts.
3. Prune reclaimable BuildKit cache **before** installing the full SDK.
4. Run `provision-container.sh` through `docker exec` in that live container.
5. APT downloads and DeepStream archives are deleted/streamed during setup.
   The installed packages remain in the container's writable overlay layer.
6. Save a provision fingerprint; unchanged repeat runs skip installation.

**This removes the extra full-image snapshot/export, but the persistent
container's writable layer is essential state.** `docker rm`,
`docker compose down`, `docker compose up --force-recreate`, and
`docker commit` must **not** be used in normal operations.

A one-time migration from the previous `jp72-full` image requires
`JETSON_CODEX_MIGRATE=1`; it deliberately deletes the old container's
writable layer. The installer refuses accidental replacement.

### Cloud read-through mount

The host rclone FUSE mount is exposed **twice** into the same container:

- `/cloud` is the primary OneDrive project filesystem.
- `/workspace/projects` remains as a compatibility alias.

Both point to `~/jetson-codex-cloud` on the host. They do **not** duplicate
remote files. Model downloads using `HF_HOME` and `TORCH_HOME` target
`/cloud/.cache`. Rclone fetches cloud files on access, using a bounded
local VFS cache for clean files. Dirty write-back and concurrent downloads
can still consume additional local disk and are **not** safe to remove before
uploads finish. Git credentials, `/var/lib/dpkg`, and installed SDK files
remain on local Docker storage, never on rclone FUSE.

## One-command install or update

After starting the container, the installer checks `codex login status`. If already linked, it skips login. Otherwise, when run from an interactive terminal (including `curl ... | bash` over SSH), it launches `codex login --device-auth` automatically and displays the one-time code. Open **https://auth.openai.com/codex/device** on your laptop or phone to approve. If no terminal is available or login fails, the container stays running and the installer prints a retry command. GitHub CLI authentication remains a separate, optional step.

### Pair the Jetson Codex CLI to ChatGPT mobile

Remote Control needs the **complete installer-managed Codex package**, not
a lone `codex` binary. The provisioner now installs that official package
inside the existing persistent container using
`https://chatgpt.com/codex/install.sh`. Its files are stored under
`/root/.codex/packages/standalone` in the existing Docker auth volume.

After device sign-in, the installer checks Remote Control and offers to
generate a mobile pairing code. To retry or get a fresh code later:

```bash
bash ~/jetson-codex/codex-remote.sh pair
```

Open ChatGPT on your phone, visit Codex/Remote and follow the pairing
prompt. Remote Control is not host SSH and does **not** require a Codex
executable on the Jetson host. Pairing codes are displayed directly in the
terminal, never saved to a file or logged. The pairing prompt is shown
only once during automatic setup; `pair` can be repeated explicitly.

The installer does not silently recreate the container or force a new
image when pairing fails. The native daemon is started again on Docker
reboot for **newly created** containers using the updated keepalive command.
An existing container launched with the old keepalive command is preserved;
it will need an explicit migration to adopt automatic daemon restart.


On a Jetson Orin with Docker, Docker Compose v2, and the NVIDIA container
runtime already installed, run this **as your normal Docker-enabled user**:

```bash
curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash
```

This is also the update command. The [public install.sh](install.sh) checks the
ARM64 architecture, Docker prerequisites and NVIDIA runtime, then clones the
repository (or runs `git pull --ff-only` on `main`), builds the image, and
starts a persistent Docker container called **`jetson-codex`**. No manual
`git clone` or `docker run` is required. Existing Codex and GitHub login
volumes and the host-mounted workspace are retained.

**Default is hardware mode:** GPU via NVIDIA runtime, plus detected
`/dev/video*`, `/dev/i2c-*`, `/dev/gpiochip*`, USB serial devices and
`/tmp/argus_socket` when present. Not all Jetson interfaces are covered by
these mappings; camera functionality still depends on host drivers and
libraries. It does **not** use `--privileged`.

The installer takes **no arguments**. Every rerun reconciles dependencies,
rebuilds changed image inputs and checks the existing container.

The installer can recreate an existing `jetson-codex` container when
deploying an update, which interrupts any active processes inside it. It will
**not** delete authentication volumes. It refuses to overwrite a directory
that is not this checkout, a checkout with tracked local modifications, or
an unrelated container with the same name. It can install and register the NVIDIA Container Toolkit and restart Docker
when the runtime is absent; Docker Engine itself must be present.

After the script completes:

```bash
docker exec -it jetson-codex bash -l
```

Inside the container, sign in to both services (once):

```bash
codex login --device-auth
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
codex
```

Codex device login: **https://auth.openai.com/codex/device**.
GitHub CLI device login: **https://github.com/login/device**. Use the
one-time codes printed in your terminal. These are two distinct identities;
the installer does not capture or store either credential itself.

**Security:** `curl | bash` executes code downloaded from the internet.
Read [install.sh](install.sh) before running it, especially on a machine with
hardware devices and a shared host network. If you prefer a reviewable
download, use `curl -fsSLo install.sh
https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh`,
inspect it, then run `bash install.sh`.

The NVIDIA development image remains substantial and unverified until
the build and `/opt/jetson-codex/verify.sh` succeed on a real Jetson.

## Install (on your Orin)

For manual troubleshooting only, ensure Docker and Compose are installed, then
clone and build from the appropriate versioned Dockerfile:

```bash
git clone https://github.com/628426/jetson-codex.git
cd jetson-codex
bash ./install.sh
docker exec -it jetson-codex bash -l
```

For headless Codex authentication, ensure **device code login is enabled** under your security settings (or allowed by your workspace administrator). Then, inside the container, authenticate using **device-code login** (recommended for headless Jetsons):

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

**Build resource warning:** Triton and the heavy general-purpose toolchains have been removed. The CUDA/cuDNN developer image, TensorRT libraries and standalone DeepStream SDK still require several GB. The installer warns below its estimated storage threshold; the actual image size and NVIDIA hardware checks must be confirmed on the Orin.

## Start, attach, stop and restart the named container

After a successful build, run these commands **on the Jetson host**:

```bash
cd ~/jetson-codex
bash ./run-hardware.sh   # start/restart existing, never replace it
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
# DO NOT run docker compose down: post-installed SDK files would be lost
```

If you change provisioning, rerun `install.sh`; it reconciles packages
inside the persistent container. Changing the CUDA base Dockerfile requires
explicit migration (`JETSON_CODEX_MIGRATE=1`) because replacement destroys
the writable layer. Never use `docker compose down -v`: it also deletes
authentication volumes.

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

This is a **legacy JetPack 6 issue**. JetPack 7 builds now use normal Docker build networking; runtime retains host networking for local development. Do not apply the old workaround unless the new kernel exhibits the same fault.

On the Jetson, pull the fix then rebuild:

```bash
cd ~/jetson-codex
git pull --ff-only
docker compose build --progress=plain
docker compose up -d --no-build
docker exec -it jetson-codex bash -l
```

If JetPack 7 has a bridge networking error, diagnose the current Docker/kernel combination before applying an old workaround.

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

## Lean development image

The JetPack 7.2 image is intentionally focused on AI, computer vision and
day-to-day coding. It does **not** try to install every language from
OpenAI's general-purpose `codex-universal` image.

| Included | Implementation |
|---|---|
| NVIDIA GPU / CV | CUDA 13.2.1 + cuDNN devel base, TensorRT 10.16, VPI 4, standalone DeepStream 9.1, NVIDIA GStreamer/NVDEC |
| C/C++ | GCC, Clang, CMake, Ninja, GDB, formatting/linting, headers for GStreamer and V4L2 |
| Python | Ubuntu 24.04's Python **3.12** and `pipx` |
| Python tooling | `uv`, `ruff`; additional project dependencies installed on demand |
| Node.js | One LTS runtime, pinned at 26.11.0, plus npm, pnpm, TypeScript, ESLint, Prettier |
| AI agent | Standalone Codex ARM64 CLI, persistent authentication and no-approval configuration |
| Git providers | Git, Git LFS, SSH, GitHub CLI, GitLab CLI, Azure CLI / DevOps |

**Removed entirely from the project's explicit installation steps:** Rust,
Go, Ruby, Java/JDK, Gradle, Maven, Swift, PHP, Composer, Erlang, Elixir, Bun
and Bazelisk. Also removed Python 3.15, Poetry, Black, isort, mypy, pyright,
Yarn and redundant version managers. System or NVIDIA image dependencies may
contain languages internally; the project does not install extra versions.

Toolchain versions are chosen at **image build time**. The former
`CODEX_ENV_*_VERSION` overrides are rejected rather than downloading
extra toolchains at container startup.

The full lean ARM64 build and hardware decoder smoke tests still need
validation on the real Orin. Do not treat the GitHub syntax checks as a
completed NVIDIA SDK acceptance test.

## Hardware checks

`/opt/jetson-codex/verify.sh` checks the installed CLI/toolchains and calls the real CUDA driver to count GPU devices. `nvcc --version` alone proves only that the compiler is present, **not** that CUDA works. `nvidia-smi` is not a reliable Jetson health test.

DeepStream 9.1 is now included via the official Jetson image. JetPack 7.2 GA is the intended host. This does not guarantee DeepStream SDK development support inside the container; validate on-device.

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

The image now deliberately excludes Swift, PHP, Erlang/Elixir, Java, Ruby, Go, Rust, Bun and Bazel to minimise storage. The Triton server is excluded; the remaining CUDA developer SDK and DeepStream still require several GB. The one-command installer performs the full build and hardware checks; GitHub CI currently validates script syntax and the lean configuration, not a GPU-equipped ARM64 build.
