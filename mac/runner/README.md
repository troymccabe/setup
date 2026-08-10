# runner (macOS)

Ephemeral, Tart-backed GitHub Actions runners for Apple Silicon Macs. Each CI
job gets a fresh, throwaway macOS VM: clone the local base image → boot →
JIT-register a runner (only once the VM is reachable, so runners never sit
"offline" in GitHub during boot) → run one job → destroy. Nothing from one job
leaks into the next.

See [`../../linux/runner`](../../linux/runner) for the Linux (Incus) sibling.
See [`../../windows/runner`](../../windows/runner) for the Windows (Hyper-V) sibling.

## Quick start

```sh
GH_ORG=YourOrg GH_PAT=ghp_xxxxx mac/runner/setup
```

Or `curl | sh` the raw file:

```sh
GH_ORG=YourOrg GH_PAT=ghp_xxxxx \
    bash <(curl -fsSL https://raw.githubusercontent.com/troymccabe/setup/main/mac/runner/setup)
```

`GH_PAT` needs the **Self-hosted runners (Admin)** org permission (fine-grained
tokens recommended).

---

## What it does

| Step | Description |
|------|-------------|
| 1 | Sanity checks (Apple Silicon, Homebrew) |
| 2 | Installs `tart` + `softnet` + `jq` + `sshpass` |
| 3 | Materialises the base image as a **local Tart VM** (one-time download; see below) |
| 4 | Ensures the org runner group exists, optionally scopes it to one repo |
| 5 | Writes config + orchestrator script to `~/.gha-runner` |
| 6 | Installs a launchd agent that runs the orchestrator loop |

Each spawned runner carries the labels
`self-hosted, macOS, arm64` + `SHARED_LABEL` + `HOST_LABEL` + any `EXTRA_LABELS`.

```yaml
runs-on: [self-hosted, macos-runner]   # any host in the fleet
runs-on: [self-hosted, <hostname>]     # this specific host
runs-on: [mobile-runner, xcode-26.6]   # capability labels via EXTRA_LABELS
```

---

## Base image model

The remote image is downloaded **once** at install time and materialised as a
local Tart VM (`base-<image>-<tag>` under `~/.tart/vms/`); the per-job
`tart clone` runs against that local name and **never consults a registry**.

Why this matters: a remote ref in the per-job path lives in Tart's OCI cache,
which auto-prunes under disk pressure. On a small-SSD host that degenerates
into re-downloading the full image on **every cycle** — observed in production
as 64 GB × 398 pulls ≈ 27 TB, ~55 min per cycle, with the runner sitting
"offline" in GitHub ~95 % of the time. Local VMs are never auto-pruned, and
per-job clones are APFS copy-on-write: cycles cost seconds and only their
write-delta in disk.

Consequences:

- `SOURCE_IMAGE` must be **pinned to a version tag**; `:latest` is refused.
  The pin is the fleet's audit trail.
- Images built or transferred out of band (Packer, `rsync` from another host)
  are used directly by passing `BASE_IMAGE=<local-vm-name>` — no pull at all.
- **Updating the image**: re-run the script with a new pinned `SOURCE_IMAGE`
  (or a new `BASE_IMAGE`). The old base VM is left in place; delete it after
  the first green cycle: `tart delete <old-base>`.
- Images that bake `~/actions-runner` (e.g. purpose-built CI images) skip the
  per-job runner download entirely; otherwise the pinned `RUNNER_VERSION` is
  installed.

---

## Configuration

Set via environment variables at run time (defaults shown):

| Var | Default | Purpose |
|-----|---------|---------|
| `GH_ORG` | *(required)* | GitHub organization |
| `GH_PAT` | *(required)* | PAT with Self-hosted runners (Admin) |
| `RUNNER_GROUP` | `macos-runners` | Org-level runner group |
| `SHARED_LABEL` | `macos-runner` | Fleet label all runners carry |
| `HOST_LABEL` | `<hostname -s>` | Per-host label |
| `EXTRA_LABELS` | `""` | Comma-separated capability labels appended to every registration (e.g. `mobile-runner,xcode-26.6`) |
| `SCOPE_REPO` | `""` | `owner/repo` to gate the group to (empty = org-wide) |
| `SOURCE_IMAGE` | `ghcr.io/cirruslabs/macos-tahoe-xcode:26.5` | Remote image, fetched once. Pinned tag required — `:latest` refused |
| `BASE_IMAGE` | *derived*: `base-<image>-<tag>` | Existing **local** Tart VM to use instead of pulling `SOURCE_IMAGE` |
| `REGISTRY_USER` / `REGISTRY_PAT` | `""` | `tart login` credentials for a private `SOURCE_IMAGE` registry |
| `RUNNER_VERSION` | `2.335.1` | actions/runner installed in VMs whose image doesn't bake one |
| `VM_MEMORY_MB` / `VM_CPU_COUNT` | `10240` / `4` | Per-VM sizing |
| `VM_DISK_GB` | `""` (keep image's disk) | Applied only when it would **grow** the disk — Tart cannot shrink one |
| `HOST_RESERVE_MB` | `6144` | RAM kept free for the host; gates concurrency |
| `LAUNCHD_LABEL` | `dev.<org>.gha-runner` | launchd job label |
| `CONFIG_DIR` | `~/.gha-runner` | Config + scripts location |

**Sizing on a 16 GB host**: the defaults leave one 10 GB VM at a time. For
heavy toolchain images (mobile builds: simulator + Metro + a local API), raise
to `VM_MEMORY_MB=12288 HOST_RESERVE_MB=4096 VM_CPU_COUNT=6` — and trial the
heaviest job once before advertising its capability label via `EXTRA_LABELS`.

---

## Surviving reboots

The orchestrator installs as a **launchd agent**, which loads only inside a
logged-in GUI (Aqua) session — **not** at the login window. A LaunchDaemon
won't help: Tart uses `Virtualization.framework`, which needs a GUI session, so
it can't run pre-login.

For an unattended runner, configure the host to log in automatically on boot:

- System Settings ▸ Users & Groups ▸ **Automatically log in as** ▸ `<user>`
  (requires **FileVault off** — it blocks auto-login)
- `sudo pmset -a sleep 0 displaysleep 0 autorestart 1`
- System Settings ▸ Energy ▸ **Start up automatically after a power failure**

With auto-login on: reboot → login → agent loads → orchestrator starts. Without
it, someone must log in once after each reboot.

---

## Managing the service

```sh
tail -F ~/.gha-runner/orchestrator.log                     # follow logs
launchctl unload ~/Library/LaunchAgents/<label>.plist      # stop
launchctl load   ~/Library/LaunchAgents/<label>.plist      # start
```

---

## Adding hosts & scaling

Run the script on each new Mac with a distinct `HOST_LABEL`. Same `GH_ORG` +
`RUNNER_GROUP` + `SHARED_LABEL` → it joins the same fleet.

This is a **single-host** design — each Mac runs its own launchd loop and
schedules VMs against local free RAM. Simplest for 1–2 machines. At ~3+ hosts,
consider [Orchard](https://github.com/cirruslabs/orchard), Cirrus's cluster
scheduler for Tart: a central controller bin-packs VMs across a worker pool,
replacing per-host capacity guessing with fleet-wide scheduling and one
`orchard list vms` view. Caveats — it still drives `tart` (GUI-login
requirement unchanged), adds a controller to run, and the JIT-registration glue
stays in this script (Orchard places VMs, it doesn't register runners).

---

## Re-running

Idempotent — safe to run again at any time:

- The runner group + repo scoping are no-op on the second pass
- An already-materialised base VM is detected and the download skipped
- The orchestrator + plist are overwritten with identical content
- The launchd service is cycled
- In-flight VMs from a prior run are reaped on the next orchestrator start
- Runner registrations stranded by a reboot/crash are deregistered from
  GitHub at startup (ledger in `CONFIG_DIR/pending-runners`)
