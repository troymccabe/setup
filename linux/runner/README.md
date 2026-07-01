# runner (Linux)

Ephemeral, Incus-backed GitHub Actions runners. Each CI job gets a fresh,
throwaway instance: clone base image → boot → provision → JIT-register a
runner → run one job → destroy. Nothing from one job leaks into the next.

See [`../../mac/runner`](../../mac/runner) for the Mac (Tart) sibling.
See [`../../windows/runner`](../../windows/runner) for the Windows (Hyper-V) sibling.

## Why Incus

"Various distros" and "various desktop environments" are two problems:

- **Distro userland matrix** (Ubuntu / Debian / Fedora / Arch / openSUSE) —
  system **containers** share the host kernel, so they're near-instant and
  cheap. `INSTANCE_TYPE=container` (the default).
- **Desktop environments / real kernel / GPU / Wayland** — need a **VM**.
  `INSTANCE_TYPE=vm` (requires `/dev/kvm`).

Incus does both from one CLI and image server, so a single primitive spans the
whole matrix.

## Quick start

One run per distro/DE variant you want to serve:

```sh
GH_ORG=YourOrg GH_PAT=ghp_xxxxx DISTRO=ubuntu/24.04 linux/runner/setup
GH_ORG=YourOrg GH_PAT=ghp_xxxxx DISTRO=fedora/40    linux/runner/setup
GH_ORG=YourOrg GH_PAT=ghp_xxxxx DISTRO=archlinux    linux/runner/setup
```

A desktop-environment runner (real VM + a provisioning hook + a `gnome` label):

```sh
GH_ORG=YourOrg GH_PAT=ghp_xxxxx \
  DISTRO=ubuntu/24.04 INSTANCE_TYPE=vm EXTRA_LABELS=gnome,wayland \
  PROVISION_CMD='apt-get update && apt-get install -y ubuntu-desktop' \
  linux/runner/setup
```

Or `curl | sh` the raw file:

```sh
GH_ORG=YourOrg GH_PAT=ghp_xxxxx DISTRO=debian/12 \
    bash <(curl -fsSL https://raw.githubusercontent.com/troymccabe/setup/main/linux/runner/setup)
```

`GH_PAT` needs the **Self-hosted runners (Admin)** org permission (fine-grained
tokens recommended). Browse available images with `incus image list images:`.

---

## What it does

| Step | Description |
|------|-------------|
| 1 | Sanity checks (Linux, `sudo`, `/dev/kvm` if `vm` mode) |
| 2 | Installs `incus` + `jq` + `curl` via apt/dnf/pacman/zypper |
| 3 | Enables the Incus daemon, adds you to `incus-admin`, `incus admin init` |
| 4 | Caches the `DISTRO` base image to a local alias |
| 5 | Ensures the org runner group exists, optionally scopes it to one repo |
| 6 | Writes config + orchestrator to `~/.gha-runner/<distro>` |
| 7 | Installs a **system** systemd service running the orchestrator loop |

Each spawned runner carries
`self-hosted, Linux, <arch>` + `SHARED_LABEL` + `HOST_LABEL` + `DISTRO_LABEL`
(+ any `EXTRA_LABELS`).

```yaml
runs-on: [self-hosted, linux-runner]   # any Linux host in the fleet
runs-on: [self-hosted, ubuntu-24.04]   # this distro/DE variant
runs-on: [self-hosted, gnome]          # a desktop-enabled variant
runs-on: [self-hosted, <hostname>]     # this specific host
```

---

## Configuration

Set via environment variables at run time (defaults shown):

| Var | Default | Purpose |
|-----|---------|---------|
| `GH_ORG` | *(required)* | GitHub organization |
| `GH_PAT` | *(required)* | PAT with Self-hosted runners (Admin) |
| `DISTRO` | `ubuntu/24.04` | Incus image to build against |
| `INSTANCE_TYPE` | `container` | `container` (shared kernel) or `vm` (own kernel, needs KVM) |
| `IMAGE_REMOTE` | `images:` | Incus image server for `DISTRO` |
| `RUNNER_GROUP` | `linux-runners` | Org-level runner group |
| `SHARED_LABEL` | `linux-runner` | Fleet label all runners carry |
| `HOST_LABEL` | `<hostname -s>` | Per-host label |
| `EXTRA_LABELS` | `""` | Comma-separated labels to append (e.g. `gnome,wayland`) |
| `SCOPE_REPO` | `""` | `owner/repo` to gate the group to (empty = org-wide) |
| `PROVISION_CMD` | `""` | Shell run inside each fresh instance before the runner (the DE hook) |
| `VM_MEMORY_MB` / `VM_CPU_COUNT` | `4096` / `4` | Per-instance limits |
| `VM_DISK_GB` | `40` | Root disk size (`vm` mode only) |
| `HOST_RESERVE_MB` | `2048` | RAM kept free for the host; gates `vm` concurrency |
| `SECURITY_NESTING` | `true` | Allow Docker / nested containers in `container` mode (VMs don't need it) |
| `SERVICE_NAME` | `gha-runner-<org>-<distro>` | systemd unit name |
| `CONFIG_DIR` | `~/.gha-runner/<distro>` | Config + scripts location |

---

## Desktop environments

Two ways to get a DE into the instance:

1. **`PROVISION_CMD`** — installs the DE on every fresh instance. Simplest, but
   pays the install cost per job. Good for occasional DE jobs.
2. **Custom baked image** *(recommended for frequent DE jobs)* — provision once,
   snapshot to a local Incus image, and point `DISTRO` at it so every job
   starts pre-installed:

   ```sh
   incus launch images:ubuntu/24.04 build --vm
   incus exec build -- bash -c 'apt-get update && apt-get install -y ubuntu-desktop'
   incus stop build
   incus publish build --alias ubuntu-gnome
   incus delete build
   # then: DISTRO=ubuntu-gnome IMAGE_REMOTE=local: INSTANCE_TYPE=vm ... linux/runner/setup
   ```

Fidelity ladder for headless GUI testing: `xvfb-run` (framebuffer only) →
`weston`/`sway --headless` (real Wayland compositor) → full VM with a booted
GNOME/KDE session (most faithful, heaviest).

---

## Surviving reboots

No GUI login required. The orchestrator installs as a **system** systemd
service (`WantedBy=multi-user.target`, `Restart=always`), so it starts at boot
on a headless box with nobody logged in — the macOS auto-login dance does not
apply here. The service runs as the invoking user with the `incus-admin`
supplementary group; Incus itself starts from its own unit.

---

## Managing the service

```sh
tail -F ~/.gha-runner/<distro>/orchestrator.log   # follow logs
systemctl status  gha-runner-<org>-<distro>       # status
sudo systemctl restart gha-runner-<org>-<distro>  # restart
sudo systemctl disable --now gha-runner-<org>-<distro> \
  && sudo rm /etc/systemd/system/gha-runner-<org>-<distro>.service   # remove
```

---

## Docker / container jobs

Actions job-level `container:` and service containers are Linux-only, so this
runner is their natural home — and you can't control whether a workflow uses
them. Two ways they're supported:

- **`container` mode** — the orchestrator sets `security.nesting=true` by
  default (`SECURITY_NESTING`), which lets Docker / nested containers run inside
  the system container. Docker itself must be in the image (bake it, or install
  via `PROVISION_CMD`).
- **`vm` mode** — a real kernel, so Docker "just works" with full isolation and
  no privileged-nesting trade-off. Heavier per job.

Set `SECURITY_NESTING=false` to opt out of nesting in container mode.

## Adding distros, DEs & hosts

- **Another variant on the same host** — re-run with a different `DISTRO`
  (and `INSTANCE_TYPE` / `PROVISION_CMD` / `EXTRA_LABELS`). Each variant gets
  its own service and config dir and coexists; in `vm` mode they compete for
  RAM via `HOST_RESERVE_MB`.
- **Another host** — run on the new machine with a distinct `HOST_LABEL`. Same
  `GH_ORG` + `RUNNER_GROUP` + `SHARED_LABEL` → it joins the same fleet.

Each orchestrator runs one job at a time; run several (one per distro) for
per-host parallelism.

---

## Re-running

Idempotent — safe to run again at any time:

- The runner group + repo scoping are no-op on the second pass
- The orchestrator + systemd unit are overwritten with identical content
- The base image alias is refreshed
- The service is restarted; in-flight instances from a prior run are reaped on
  the next orchestrator start
