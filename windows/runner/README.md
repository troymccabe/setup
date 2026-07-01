# runner (Windows)

Ephemeral, Hyper-V-backed GitHub Actions runners. Each CI job gets a fresh,
throwaway VM booted from a differencing disk off a read-only base VHDX: create
diff disk → boot → JIT-register a runner → run one job → destroy. Nothing from
one job leaks into the next.

The Windows sibling of [`../../mac/runner`](../../mac/runner) and
[`../../linux/runner`](../../linux/runner) — same shape, but the isolation
primitive is a **Hyper-V VM**, the in-guest control channel is **PowerShell
Direct** (no SSH/WinRM), and the boot service is a **Scheduled Task**.

Guests get **virtualization extensions exposed by default**, so Docker / nested
containers work if the base image ships Docker — see [Docker jobs](#docker-jobs).

## Prerequisite: a base VHDX

Unlike Tart (macOS) and Incus (Linux), Windows has no public catalog of
ready-to-clone CI images, so you build the base once yourself:

1. Create a **Generation 2 (UEFI)** VM, install Windows 11 or Server
   2019/2022/2025 from an ISO.
2. Inside it: enable PowerShell Direct's prerequisites (Windows integration
   services are on by default), set a **known local admin password**, install
   any baseline build tooling you want pre-baked (VS Build Tools, Git, language
   SDKs — anything here is skipped per-job).
3. *(Optional — for Docker jobs)* install **Docker + the Containers feature**
   so `docker` steps work with `NESTED_VIRT` (on by default). On **Server**:

   ```powershell
   Install-WindowsFeature -Name Containers
   Install-Module -Name DockerMsftProvider -Force
   Install-Package -Name docker -ProviderName DockerMsftProvider -Force
   Set-Service docker -StartupType Automatic
   ```

   On **Windows 11**, install Docker Desktop (or dockerd) and enable the
   **Containers** and **Hyper-V** optional features. Leave the daemon set to
   start automatically so it's up before a job runs. Verify with `docker info`
   before sysprepping.
4. Generalize with **Sysprep** (`sysprep /generalize /oobe /shutdown`) so each
   clone gets a unique identity.
5. Note the resulting `.vhdx` path and the admin password — those are
   `BASE_VHDX` and `VM_PASS`.

[Packer](https://www.packer.io/) with the `hyperv-iso` builder automates all of
this (including the Docker step) if you'd rather not do it by hand.

## Quick start

Run once per base image, from an **elevated** PowerShell:

```powershell
$env:GH_ORG    = 'YourOrg'
$env:GH_PAT    = 'ghp_xxxxx'          # PAT with Self-hosted runners (Admin)
$env:BASE_VHDX = 'D:\images\win2022-base.vhdx'
$env:VM_PASS   = '<base image admin password>'
$env:IMAGE_LABEL = 'server2022'
.\windows\runner\setup.ps1
```

Or straight from the raw file:

```powershell
$env:GH_ORG='YourOrg'; $env:GH_PAT='ghp_xxxxx'
$env:BASE_VHDX='D:\images\win2022-base.vhdx'; $env:VM_PASS='<pw>'
iwr https://raw.githubusercontent.com/troymccabe/setup/main/windows/runner/setup.ps1 | iex
```

> It's `setup.ps1` (not bare `setup` like the mac/linux scripts) because
> PowerShell needs the extension to run natively.

The first run enables Hyper-V if it isn't already, which requires a **reboot** —
after rebooting, run the script again to finish.

---

## What it does

| Step | Description |
|------|-------------|
| 1 | Sanity checks (Windows, admin, Hyper-V, base VHDX, switch); enables Hyper-V if needed |
| 2 | Ensures the org runner group exists, optionally scopes it to one repo |
| 3 | Writes config (PAT + VM password, ACL'd to SYSTEM/Administrators) + orchestrator to `%ProgramData%\gha-runner\<image>` |
| 4 | Registers a **Scheduled Task** (AtStartup, SYSTEM) running the orchestrator loop |

Each spawned runner carries
`self-hosted, Windows, <arch>` + `SHARED_LABEL` + `HOST_LABEL` + `IMAGE_LABEL`
(+ any `EXTRA_LABELS`).

```yaml
runs-on: [self-hosted, windows-runner]   # any Windows host in the fleet
runs-on: [self-hosted, server2022]       # this base image
runs-on: [self-hosted, <hostname>]       # this specific host
```

---

## Configuration

Set via environment variables (for `iwr | iex`) or matching `-Params`
(defaults shown):

| Env / Param | Default | Purpose |
|-------------|---------|---------|
| `GH_ORG` / `-GhOrg` | *(required)* | GitHub organization |
| `GH_PAT` / `-GhPat` | *(required)* | PAT with Self-hosted runners (Admin) |
| `BASE_VHDX` / `-BaseVhdxPath` | *(required)* | Sysprepped Gen2 base VHDX |
| `VM_PASS` / `-VmPass` | *(required)* | Base image local-admin password |
| `VM_USER` / `-VmUser` | `Administrator` | Base image local-admin user |
| `IMAGE_LABEL` / `-ImageLabel` | `windows` | Label for this base (e.g. `server2022`) |
| `RUNNER_GROUP` / `-RunnerGroup` | `windows-runners` | Org runner group |
| `SHARED_LABEL` / `-SharedLabel` | `windows-runner` | Fleet label |
| `HOST_LABEL` / `-HostLabel` | `<hostname>` | Per-host label |
| `EXTRA_LABELS` / `-ExtraLabels` | `""` | Comma-separated extra labels |
| `SCOPE_REPO` / `-ScopeRepo` | `""` | `owner/repo` to gate the group to |
| `SWITCH_NAME` / `-SwitchName` | `Default Switch` | Hyper-V switch for guest internet |
| `VM_MEMORY_MB` / `-VmMemoryMb` | `8192` | Per-VM memory |
| `VM_CPU_COUNT` / `-VmCpuCount` | `4` | Per-VM CPUs |
| `HOST_RESERVE_MB` / `-HostReserveMb` | `4096` | RAM kept free for the host; gates concurrency |
| `SECURE_BOOT` / `-SecureBoot` | `$true` | Gen2 secure boot |
| `NESTED_VIRT` / `-NestedVirt` | `$true` | Expose virt extensions so Docker / nested containers work in the guest |
| `CONFIG_DIR` / `-ConfigDir` | `%ProgramData%\gha-runner\<image>` | Config + scripts location |

**Networking:** guests reach the internet through `SWITCH_NAME`. `Default
Switch` (NAT + DHCP, always present on Windows **client** SKUs) works out of the
box. On **Server** SKUs it may not exist — create an external switch bound to a
NIC, or a NAT switch, and pass `-SwitchName`. PowerShell Direct is used for the
*control* channel and needs no networking.

---

## Surviving reboots

The orchestrator installs as a **Scheduled Task** (trigger AtStartup, principal
SYSTEM, highest privileges, restart-on-failure), so it starts at boot with
nobody logged in. Plain build/test jobs run fully headless — only jobs that
need an *interactive desktop* would require guest autologon.

---

## Managing the service

```powershell
Get-Content -Wait "$env:ProgramData\gha-runner\<image>\orchestrator.log"  # follow logs
Get-ScheduledTask gha-runner-<org>-<image> | Get-ScheduledTaskInfo        # status
Stop-ScheduledTask gha-runner-<org>-<image>; Start-ScheduledTask gha-runner-<org>-<image>  # restart
Unregister-ScheduledTask gha-runner-<org>-<image> -Confirm:$false         # remove
```

---

## Docker jobs

Because you can't control whether a workflow runs `docker`, the orchestrator
**exposes virtualization extensions to every guest by default** (`NESTED_VIRT`,
default `$true`) — so Docker / Hyper-V-isolated / WSL2 containers work inside
the VM. It also enables MAC-address spoofing on the VM's adapter, which nested
guests need for outbound networking. If the host CPU can't nest, the
orchestrator warns once and continues; plain jobs are unaffected.

Two things are still on you:

1. **Docker must be in the base image.** Exposing the extensions is necessary
   but not sufficient — bake **Docker + the Containers feature** into the base
   VHDX, or `docker` steps fail regardless. `NESTED_VIRT` only opens the door.
2. **Linux containers** — Actions job-level `container:` and service containers
   are Linux-only and don't run on Windows runners at all. Route those jobs to
   the [Linux/Incus runner](../../linux/runner); it's their natural home and
   cheaper. On Windows, "Docker" means workflow *steps* that invoke `docker`.

Set `NESTED_VIRT=$false` to opt out (e.g. hosts you know never run containers).

---

## Adding versions & hosts

- **Another Windows version on the same host** — re-run with a different
  `BASE_VHDX` and `IMAGE_LABEL`. Each gets its own task and config dir and
  coexists, competing for RAM via `HOST_RESERVE_MB`.
- **Another host** — run on the new machine with a distinct `HOST_LABEL`. Same
  `GH_ORG` + `RUNNER_GROUP` + `SHARED_LABEL` → it joins the same fleet.

Each orchestrator runs one job at a time; run several (one per base image) for
per-host parallelism.

---

## Re-running

Idempotent — safe to run again at any time:

- The runner group + repo scoping are no-op on the second pass
- The orchestrator + scheduled task are overwritten with identical content
- The task is restarted; in-flight VMs from a prior run are reaped on the next
  orchestrator start
