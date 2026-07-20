# setup

Personal machine bootstrap + self-hosted GitHub Actions runner fleet.

## Developer machine

| Path | What |
|------|------|
| [`mac/dev`](mac/dev) | Fresh-Mac bootstrap for macOS Tahoe — Homebrew, Brewfile, shell config, mise runtimes, Xcode, macOS defaults. |

## macOS utilities

| Path | What |
|------|------|
| [`mac/keepawake`](mac/keepawake) | Keep a Mac's GUI session unlocked + awake (screensaver/lock off, a `caffeinate` LaunchAgent, no sleep) so XCUITest — or any UI automation — can run **directly on the host**. Opt-in per box; the Tart-VM CI path doesn't need it. `keepawake off` reverses it. |

## CI runner fleet

Ephemeral, self-hosted GitHub Actions runners. Each shares the same skeleton —
JIT runner registration → clone a fresh environment → run one job → destroy —
and differs only in the isolation primitive and boot service per platform.

| Path | Platform | Primitive | Control channel | Boot service |
|------|----------|-----------|-----------------|--------------|
| [`mac/runner`](mac/runner) | macOS (Apple Silicon) | Tart VM | SSH | launchd |
| [`linux/runner`](linux/runner) | Linux | Incus container / VM | `incus exec` | systemd |
| [`windows/runner`](windows/runner) | Windows | Hyper-V VM | PowerShell Direct | Scheduled Task |

Each runner's README covers quick start, configuration, reboot persistence,
Docker/container support, and scaling. Same `GH_ORG` + `RUNNER_GROUP` +
`SHARED_LABEL` across hosts joins them into one fleet; per-platform and
per-host labels target a subset:

```yaml
runs-on: [self-hosted, linux-runner]   # any Linux host
runs-on: [self-hosted, ubuntu-24.04]   # a specific distro/image
runs-on: [self-hosted, <hostname>]     # a specific host
```

Container/Docker jobs are Linux-only in Actions, so route them to
[`linux/runner`](linux/runner); the Windows and macOS runners handle native
build/test.
