# runner (macOS)

Ephemeral, Tart-backed GitHub Actions runners for Apple Silicon Macs. Each CI
job gets a fresh, throwaway macOS VM: clone base image → boot → JIT-register a
runner → run one job → destroy. Nothing from one job leaks into the next.

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
| 3 | Pulls the Tart base image (`macos-tahoe-xcode` by default) |
| 4 | Ensures the org runner group exists, optionally scopes it to one repo |
| 5 | Writes config + orchestrator script to `~/.gha-runner` |
| 6 | Installs a launchd agent that runs the orchestrator loop |

Each spawned runner carries the labels
`self-hosted, macOS, arm64` + `SHARED_LABEL` + `HOST_LABEL`.

```yaml
runs-on: [self-hosted, macos-runner]   # any host in the fleet
runs-on: [self-hosted, <hostname>]     # this specific host
```

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
| `SCOPE_REPO` | `""` | `owner/repo` to gate the group to (empty = org-wide) |
| `BASE_IMAGE` | `ghcr.io/cirruslabs/macos-tahoe-xcode:latest` | Tart base image |
| `VM_MEMORY_MB` / `VM_CPU_COUNT` / `VM_DISK_GB` | `10240` / `4` / `120` | Per-VM sizing |
| `HOST_RESERVE_MB` | `6144` | RAM kept free for the host; gates concurrency |
| `LAUNCHD_LABEL` | `dev.<org>.gha-runner` | launchd job label |
| `CONFIG_DIR` | `~/.gha-runner` | Config + scripts location |

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

## Running XCUITest directly on a host (`keepawake`)

CI runs XCUITest **inside Tart VMs**, each with its own auto-login, unlocked
session — so the runner host's lock state never affects it. But if you also run
XCUITest **directly on a host** (local iteration over SSH), its "enable
automation mode" step times out against a locked screen (looks like a hang, not
a test failure).

`mac/keepawake` keeps a host's GUI session unlocked + awake for that case:
screensaver + password-on-wake off, a `caffeinate` LaunchAgent (survives
reboots), and `pmset` sleep off. It's deliberately **separate** from `setup` and
opt-in per box — it weakens host lock security, so you don't want it fleet-wide.

```sh
mac/keepawake        # enable
mac/keepawake off    # disable + remove the LaunchAgent
```

An already-locked session must be unlocked **once** (Screen Sharing) for it to
take effect — `caffeinate` keeps a screen awake but can't unlock one.

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
- The orchestrator + plist are overwritten with identical content
- The launchd service is cycled
- In-flight VMs from a prior run are reaped on the next orchestrator start
