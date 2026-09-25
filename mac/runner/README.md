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
| 2 | Installs `tart` + `softnet` + `jq` + `sshpass` (+ `1password-cli` if `OP_ITEM_REF` is set) |
| 3 | Materialises the base image as a **local Tart VM** (one-time download; see below) |
| 4 | Ensures the org runner group exists, optionally scopes it to one repo |
| 5 | Writes config + orchestrator script to `~/.gha-runner` |
| 6 | Installs a launchd agent that runs the orchestrator loop |

Each spawned runner carries the labels
`self-hosted, macOS, arm64` + `SHARED_LABEL` + `HOST_LABEL` + any `EXTRA_LABELS`,
plus **capability labels read out of the booted VM** — `macos-major-<N>` and
`xcode-<version>` (the latter only when Xcode is present) — and `image-<tag>`,
derived from the `BASE_IMAGE` VM name for traceability.

```yaml
runs-on: [self-hosted, macos-runner]   # any host in the fleet
runs-on: [self-hosted, <hostname>]     # this specific host
runs-on: [macos-major-26, xcode-26.6]  # capability-gated, host-agnostic
```

Prefer the capability form for any job with a toolchain floor. It cannot land
on an image that lacks what it needs, and it does not pin work to one host.

**The omission of `self-hosted` there is deliberate — don't add it back.** It is
the form GitHub's docs show, so it looks like a mistake, but it is a *provenance*
label, not a capability: it says who owns the machine, which the scheduler
already knows from the namespaced labels. Requiring it is how a fleet ends up
with one usable runner and a multi-hour queue — a host registered through
`generate-jitconfig` gets only the labels it is handed, and any orchestrator
that forgets `self-hosted` becomes permanently invisible to jobs that demand it.
That is a real outage this fleet has had. Runners should advertise a superset
(this script always includes `self-hosted`); workflows should demand only what
they actually need.

### Capability labels are derived, never asserted

The orchestrator SSHes into each freshly booted VM and reads `xcodebuild
-version` and `sw_vers` before registering the runner. A label taken from
`config.env` says what *should* be in the image; only the VM knows what *is*,
and an asserted label that has drifted is worse than no gate at all — it routes
the job confidently to the wrong toolchain.

So the probe **owns** the `macos-major-*`, `xcode-*` and `image-*` namespaces. A
static `SHARED_LABEL` / `EXTRA_LABELS` entry in one of them is dropped and the
probed value used instead; if it *contradicts* what the VM reported, the
orchestrator logs a warning rather than dropping it silently. Put capabilities
the VM cannot report — like `mobile-runner` — in `EXTRA_LABELS`; anything it
*can* report should come from the probe.

`HOST_LABEL` is exempt — it is the host's identity, not a capability claim, so a
mini named `xcode-mini` keeps its label. Label matching is exact string
equality, so an identity label can never satisfy a job gated on `xcode-26.6`.

`image-<tag>` is the one *derived* rather than probed label — it records which
image the VM was cloned from, for tracing a bad build from the job page. It
comes from the pinned `SOURCE_IMAGE` tag captured at install time; for a VM that
arrived out of band it falls back to splitting the `BASE_IMAGE` name on the last
`-`, which is lossy for a hyphenated tag. Either way it reflects the image's
name, not its contents — only `macos-major-*` and `xcode-*` are read from the
running VM.

Fail-safe by construction:

- The probe retries **3×** in a single SSH round-trip each time. Two
  back-to-back connections proved flaky (the second returned empty), which
  silently dropped a label and left gated jobs queued until GitHub's 24h
  auto-cancel — a stall that reads as "no capacity" rather than "probe failed".
- If macOS version can't be read at all, the VM is **recycled** rather than
  registered half-labelled.
- No Xcode is a legitimate image, so the `xcode-*` label is simply absent and
  gated jobs pass the runner by. Set **`REQUIRE_XCODE=1`** on a fleet where a
  missing Xcode means a broken image and you want it recycled loudly instead.

---

## Credentials

Two models, chosen per host at install time.

### Default — PAT in `config.env`

`OP_ITEM_REF` unset. `GH_PAT` is written to `config.env` (0600) and the
orchestrator sources it. No extra dependency; nothing else to run.

The PAT sits on disk indefinitely, so rotating it means editing `config.env` on
every host. Fine for one machine or a throwaway setup.

### op-read — PAT never touches disk

Set `OP_ITEM_REF` to a 1Password secret reference:

```sh
GH_ORG=YourOrg GH_PAT=ghp_xxxxx \
OP_ITEM_REF='op://runners/runner-jit-pat/credential' \
    mac/runner/setup
```

The installer adds `1password-cli`, prompts once for a **service-account token**
(hidden input, written 0600), and verifies it can actually read the reference
before finishing — so a bad vault path fails now, not silently at 3am on the
first job cycle.

After that the orchestrator fetches the PAT from 1Password **at the top of every
cycle**. `GH_PAT` is used for install-time setup only and is never persisted:
`config.env` records `OP_ITEM_REF` and `OP_TOKEN_FILE`, nothing secret.

**Rotating the PAT** becomes a vault edit — replace the credential, revoke the
old token on GitHub. Every host picks it up on its next cycle with **no host
visits**.

### What op-read does and doesn't buy you

It protects the PAT from every leak channel that **isn't** host access: logs,
screenshots, backups, a stray file read, a `config.env` copied somewhere it
shouldn't be.

It does **not** protect against host compromise — an attacker holding the
service-account token can `op read` the PAT themselves. Pair it with *a
compromised host is rebuilt, not re-credentialed*, which is cheap here: this
script reprovisions a host from scratch, every job already runs in a throwaway
VM, and the rebuild issues a fresh service-account token as a side effect.

Scope the service account **read-only to a vault holding nothing but runner
credentials** — that vault's contents are the token's entire blast radius.

### No runtime fallback, on purpose

If 1Password is unreachable the agent backs off 60s and retries. It does **not**
fall back to a cached PAT, because a PAT cached on disk would defeat the whole
point of the model.

In-flight jobs are unaffected — the credential is fetched *before* a VM is
cloned — but new cycles stall until 1Password returns. The failure classes are
logged distinguishably, so triage is one line rather than a log dive:

| Log line | Means |
|---|---|
| `op unreachable` | 1Password down or no network — retrying |
| `bad service-account token` | Token revoked/expired — rotate it, re-run setup |
| `missing item` | Wrong `OP_ITEM_REF`, or the vault lost the item |
| `EMPTY credential` | Item resolved but its field is blank — a config error, not an outage |

`GH_PAT` in the environment overrides op-read for local debugging. **Never put
it in the plist** — that re-creates the persistent-plaintext-PAT problem this
model exists to remove, in a file nobody thinks to audit.

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
  per-job runner download **only while the baked version matches
  `RUNNER_VERSION`**. When it doesn't, the orchestrator replaces it in the VM
  before starting the runner — see [A baked runner
  ages](#a-baked-runner-ages-runner_version-is-authoritative).

### A baked runner ages — `RUNNER_VERSION` is authoritative

GitHub retires old `actions/runner` releases. A retired one is refused at the
broker **after** JIT registration has already succeeded:

```
√ Connected to GitHub
Current runner version: '2.335.1'
2026-09-25 00:57:43Z: Listening for Jobs
Runner listener exit with terminated error, stop the service, no retry needed.
```

with the real cause landing in `orchestrator.err`, not `orchestrator.log`:

```
An error occurred: Runner version v2.335.1 is deprecated and cannot receive messages.
```

Read from the GitHub UI this looks like a host problem — the runner appears,
then goes offline seconds later. It also **hot-loops**: the runner exits `0`,
so the orchestrator's non-zero backoff never fires and the host re-registers a
doomed runner every ~25 s.

`RUNNER_VERSION` is therefore the authority, not a fallback for images with no
runner: a baked runner that disagrees with it is replaced inside the ephemeral
VM before `run.sh` starts. Fixing a deprecation is a config bump plus an agent
restart — no image rebuild:

```sh
# on the runner host
sed -i '' 's/^RUNNER_VERSION=.*/RUNNER_VERSION="2.337.0"/' ~/.gha-runner/config.env
launchctl unload ~/Library/LaunchAgents/<label>.plist
launchctl load   ~/Library/LaunchAgents/<label>.plist
```

This cost two separate diagnoses before it was fixed (`v2.334.0`, then
`v2.335.1`), because `RUNNER_VERSION` *looked* like the knob for it and was
silently inert on any image that baked a runner.

**The replacement costs a ~60 MB download per job VM.** To get that back, bake
the current runner into the image and keep `RUNNER_VERSION` matching it — then
the check is a no-op and nothing is downloaded.

### `du` lies about clones — use `diskutil`

Tart clones are APFS copy-on-write, and `du` counts shared blocks against
**every** file that references them. A per-job clone will read as ~50 GB when
its true cost is a few GB:

```
du -sh ~/.tart/vms/*          →  base 50G, clone 49G   ("99 GB used!")
delete the clone              →  container free space +2.68 GB
```

So don't size a host from `du`, and don't delete a clone expecting to reclaim
its apparent size. The honest number:

```sh
diskutil info / | grep "Container Free Space"
```

A full job cycle costs ~3 GB of real disk, reclaimed at teardown. The base
image is the only large persistent cost.

---

## Building a custom base image (Tart + Packer)

Not needed for a stock image — this is for hosts running a purpose-built one.
Two traps, both of which cost hours before they were understood.

### `packer build` must run in the logged-in GUI (Aqua) session

Launched over a plain SSH connection, `packer build` **hangs at
`Waiting for SSH` until it times out**. It is the same constraint as the
runner agent (Tart drives `Virtualization.framework`, which needs a logged-in
GUI session) — but it is easy to miss, because a build reads like an ordinary
CLI step you'd run anywhere.

Sitting at the machine (or via Screen Sharing) it just works. To drive a build
**remotely**, run it as a one-shot LaunchAgent, which executes inside the Aqua
session:

```xml
<!-- ~/Library/LaunchAgents/dev.local.packerbuild.plist
     RunAtLoad=true, KeepAlive=false, ProgramArguments = /bin/bash <build script>,
     StandardOutPath = somewhere you can tail -->
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.local.packerbuild.plist
tail -f <StandardOutPath>
```

`launchctl asuser $(id -u) …` is the obvious alternative and **does not work
unprivileged** — it needs root (`Could not switch to audit session …:
Operation not permitted`), so on a host without passwordless sudo the
LaunchAgent is the practical route.

### `no route to host` is not a failure — don't kill the run

While the guest boots, the packer log emits:

```
[DEBUG] TCP connection to SSH ip/port failed: dial tcp 192.168.64.x:22: connect: no route to host
```

repeatedly. The plugin re-resolves the IP and recovers on its own —
`handshake complete!` follows within a minute or so. **Three otherwise-healthy
builds were abandoned mid-flight** on the assumption that this message meant
the plugin couldn't reach its own VM.

### Sizing

`packer-plugin-tart` ships **darwin/arm64 only** (Tart is Apple-Silicon
exclusive), so `packer init` fails outright on Linux — a `packer validate` CI
job has to run on macOS.

Templates commonly default to a 16 GB VM, which is unbuildable on a 16 GB
host — the VM starves the host. Override per build, e.g.
`PKR_VAR_vm_memory_gb=10 PKR_VAR_vm_cpu_count=6`. Budget ~110 GB free disk for
a full Xcode image, and read free space with `diskutil`, not `du` (above).

---

## Configuration

Set via environment variables at run time (defaults shown):

| Var | Default | Purpose |
|-----|---------|---------|
| `GH_ORG` | *(required)* | GitHub organization |
| `GH_PAT` | *(required)* | PAT with Self-hosted runners (Admin). With `OP_ITEM_REF` set this is **install-time only** and is never written to disk |
| `OP_ITEM_REF` | `""` | 1Password secret reference (`op://vault/item/field`). Set it to opt into the op-read model — see [Credentials](#credentials) |
| `OP_TOKEN_FILE` | `~/.config/gha-runner/op-token` | Where the 1Password service-account token is stored (0600). Only used with `OP_ITEM_REF` |
| `RUNNER_GROUP` | `macos-runners` | Org-level runner group |
| `SHARED_LABEL` | `macos-runner` | Fleet label all runners carry |
| `HOST_LABEL` | `<hostname -s>` | Per-host label |
| `EXTRA_LABELS` | `""` | Comma-separated capability labels appended to every registration (e.g. `mobile-runner`). `macos-major-*`/`xcode-*`/`image-*` are **probed** — a static one here is dropped |
| `REQUIRE_XCODE` | `0` | `1` = a VM with no Xcode is a broken image: recycle it instead of registering without an `xcode-*` label |
| `SCOPE_REPO` | `""` | `owner/repo` to gate the group to (empty = org-wide) |
| `SOURCE_IMAGE` | `ghcr.io/cirruslabs/macos-tahoe-xcode:26.5` | Remote image, fetched once. Pinned tag required — `:latest` refused |
| `BASE_IMAGE` | *derived*: `base-<image>-<tag>` | Existing **local** Tart VM to use instead of pulling `SOURCE_IMAGE` |
| `REGISTRY_USER` / `REGISTRY_PAT` | `""` | `tart login` credentials for a private `SOURCE_IMAGE` registry |
| `RUNNER_VERSION` | `2.337.0` | actions/runner version every VM runs. **Authoritative** — a runner baked into the image is replaced when it disagrees. Bump when GitHub deprecates a release |
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
- An existing 1Password service-account token is left alone (delete it to be re-prompted)
- The orchestrator + plist are overwritten with identical content
- The launchd service is cycled
- In-flight VMs from a prior run are reaped on the next orchestrator start
- Runner registrations stranded by a reboot/crash are deregistered from
  GitHub at startup (ledger in `CONFIG_DIR/pending-runners`)
