#!/usr/bin/env bash
# Shared harness for the mac/runner suite.
#
# `setup` is a one-shot installer that converges a real Mac: it brews packages,
# clones multi-gigabyte VMs, calls the GitHub API and loads launchd agents.
# None of that can run in CI, and none of it is the interesting part. What is
# interesting is what it DECIDES — which inputs it refuses, and what it writes
# into config.env, orchestrator.sh and the plist.
#
# So the tests run the real script against a sandbox HOME with every external
# command stubbed, then assert on the artifacts. Nothing here mutates the
# machine running the tests; MR_SANDBOX is a mktemp dir and every stub writes
# only inside it.

SETUP_SCRIPT="${SETUP_SCRIPT:-${BATS_TEST_DIRNAME}/../setup}"

# Create a sandbox HOME plus a stub bin dir, and export the environment the
# script needs. Call from setup().
mr_sandbox_init() {
  MR_SANDBOX="$(mktemp -d)"
  export MR_SANDBOX
  export HOME="$MR_SANDBOX/home"
  mkdir -p "$HOME/Library/LaunchAgents" "$MR_SANDBOX/bin" "$MR_SANDBOX/state"
  export PATH="$MR_SANDBOX/bin:$PATH"
  # Defaults every test can override before calling mr_run_setup.
  export GH_ORG="TestOrg"
  export GH_PAT="ghp_testtoken"
  export CONFIG_DIR="$HOME/.gha-runner"
  export LAUNCHD_LABEL="dev.testorg.gha-runner"
  export BASE_IMAGE="test-base-image"
  unset SOURCE_IMAGE OP_ITEM_REF VM_PREFIX RUNNER_VERSION SCOPE_REPO \
        EXTRA_LABELS SHARED_LABEL HOST_LABEL REQUIRE_XCODE VM_DISK_GB \
        REGISTRY_USER REGISTRY_PAT
  mr_stub_all
}

mr_sandbox_teardown() {
  [ -n "${MR_SANDBOX:-}" ] && rm -rf "$MR_SANDBOX"
  return 0
}

# Write an executable stub. Body reads $@ like the real command would.
mr_stub() {
  local name="$1"; shift
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$*"; } > "$MR_SANDBOX/bin/$name"
  chmod +x "$MR_SANDBOX/bin/$name"
}

# Record every invocation so a test can assert what the script asked for.
mr_calls() { cat "$MR_SANDBOX/state/$1.calls" 2>/dev/null || true; }

# Stub bodies are single-quoted ON PURPOSE: they must expand when the stub
# RUNS, inside the script under test, not when the stub is written here.
# shellcheck disable=SC2016
mr_stub_all() {
  mr_stub brew 'printf "%s\n" "$*" >> "$MR_SANDBOX/state/brew.calls"; exit 0'
  mr_stub sshpass 'exit 0'
  mr_stub softnet 'exit 0'
  mr_stub op 'printf "%s\n" "$*" >> "$MR_SANDBOX/state/op.calls"
              [ "${STUB_OP_FAIL:-0}" = "1" ] && { echo "(401) Unauthorized" >&2; exit 1; }
              echo "${STUB_OP_VALUE:-ghp_from_vault}"'

  # `tart list --format json` is the only form the installer reads. The stub
  # serves whatever the test staged in state/tart-list.json.
  mr_stub tart '
    printf "%s\n" "$*" >> "$MR_SANDBOX/state/tart.calls"
    case "$1" in
      list) cat "$MR_SANDBOX/state/tart-list.json" 2>/dev/null || echo "[]" ;;
      *)    exit 0 ;;
    esac'
  mr_tart_vms '[{"Name":"test-base-image","Source":"local","State":"stopped","Disk":140}]'

  # Only the GitHub API is called at install time. Runner groups resolve to id
  # 7 unless the test stages something else.
  mr_stub curl '
    printf "%s\n" "$*" >> "$MR_SANDBOX/state/curl.calls"
    for a in "$@"; do case "$a" in
      *actions/runner-groups*) cat "$MR_SANDBOX/state/groups.json"; exit 0 ;;
    esac; done
    exit 0'
  mr_groups '{"runner_groups":[{"id":7,"name":"macos-runners"}]}'

  mr_stub launchctl 'printf "%s\n" "$*" >> "$MR_SANDBOX/state/launchctl.calls"; exit 0'
  mr_stub uname 'echo arm64'
  mr_stub sw_vers 'echo 26.0'
  mr_stub df 'echo "Filesystem 1G-blocks Used Avail Capacity"; echo "/dev/disk1 500 100 400 20%"'
  mr_stub hostname 'echo test-host'

  # Power configuration. These MUST be stubbed: the installer calls
  # `sudo -n pmset -a ...` for real, and a CI runner with passwordless sudo
  # would have its own sleep settings rewritten by the test suite — exactly
  # the host mutation this harness promises not to do.
  #
  # The default machine is a DESKTOP: `-g cap` advertises autorestart, and a
  # write is honoured, so the happy path reads back clean. Tests override with
  # mr_pmset_cap / mr_pmset_custom / mr_pmset_unapplied.
  mr_pmset_cap 'displaysleep
disksleep
sleep
womp
autorestart'
  # `-g custom` is seeded with stock PRE-install values, because a real Mac
  # always reports these keys — it never omits one just because it was not set.
  # That makes the installer's two negative outcomes distinguishable: a key
  # reported with the OLD value (write ignored) versus a key not reported at
  # all (unverifiable). Seeding empty would conflate them.
  mr_pmset_custom 'AC Power:
 displaysleep         10
 disksleep            10
 sleep                10
 autorestart          0'
  mr_stub sudo '
    printf "%s\n" "$*" >> "$MR_SANDBOX/state/sudo.calls"
    [ "${STUB_SUDO_DENIED:-0}" = "1" ] && exit 1
    # Drop sudo-only flags and run the rest through the stub PATH.
    while [ $# -gt 0 ]; do case "$1" in -n|-H|-E) shift ;; *) break ;; esac; done
    exec "$@"'
  mr_stub defaults '
    printf "%s\n" "$*" >> "$MR_SANDBOX/state/defaults.calls"
    case "$*" in
      *autoLoginUser*) cat "$MR_SANDBOX/state/autologin.txt" 2>/dev/null \
                         || { echo "does not exist" >&2; exit 1; } ;;
    esac
    exit 0'
  mr_stub pmset '
    printf "%s\n" "$*" >> "$MR_SANDBOX/state/pmset.calls"
    case "$*" in
      "-g cap")    cat "$MR_SANDBOX/state/pmset-cap.txt" ;;
      "-g custom") cat "$MR_SANDBOX/state/pmset-custom.txt" 2>/dev/null || true ;;
      -a*)         # Model a machine that HONOURS the write by appending the
                   # new values. Appending (rather than rewriting the old line)
                   # is enough: the installer only ever asks whether a given
                   # key+value pair is present, never which line came first.
                   [ "${STUB_PMSET_UNAPPLIED:-0}" = "1" ] && exit 0
                   shift
                   while [ $# -ge 2 ]; do
                     # STUB_PMSET_UNREPORTED models a key pmset ACCEPTS but
                     # `-g custom` never surfaces, so the write is real and
                     # still unconfirmable.
                     case " ${STUB_PMSET_UNREPORTED:-} " in
                       *" $1 "*) ;;
                       *) printf " %s %s\n" "$1" "$2" \
                            >> "$MR_SANDBOX/state/pmset-custom.txt" ;;
                     esac
                     shift 2
                   done ;;
    esac
    exit 0'
}

# Stage the machine capabilities `pmset -g cap` reports (one key per line).
mr_pmset_cap() { printf '%s\n' "$1" > "$MR_SANDBOX/state/pmset-cap.txt"; }

# Stage the settings `pmset -g custom` reports before the installer writes.
mr_pmset_custom() { printf '%s\n' "$1" > "$MR_SANDBOX/state/pmset-custom.txt"; }

# Auto-login state the installer probes. Stubbed rather than read from the
# real machine so the assertion does not depend on whose Mac runs the suite.
# Default: OFF, which is the stock macOS state (the key does not exist).
mr_autologin_on()  { printf 'ci-runner\n' > "$MR_SANDBOX/state/autologin.txt"; }
mr_autologin_off() { rm -f "$MR_SANDBOX/state/autologin.txt"; }

# Model a machine that ACCEPTS a pmset write and ignores it — the failure mode
# the installer's read-back exists to catch.
mr_pmset_unapplied() { export STUB_PMSET_UNAPPLIED=1; }

mr_tart_vms()  { printf '%s' "$1" > "$MR_SANDBOX/state/tart-list.json"; }
mr_groups()    { printf '%s' "$1" > "$MR_SANDBOX/state/groups.json"; }

# Run the real installer. Output lands in $output / $status via bats `run`.
mr_run_setup() { bash "$SETUP_SCRIPT" "$@"; }

# --- artifact accessors -----------------------------------------------------

mr_config_file()  { printf '%s\n' "$CONFIG_DIR/config.env"; }
mr_orchestrator() { printf '%s\n' "$CONFIG_DIR/orchestrator.sh"; }
mr_plist()        { printf '%s\n' "$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"; }

# Value of KEY="..." in the generated config.env.
mr_config_value() {
  sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$(mr_config_file)"
}

# Extract the in-VM script the orchestrator ssh's into the guest, so its
# decisions can be checked without a guest.
mr_invm_script() {
  # Opener matched anywhere on the line, never anchored to the end: it carries
  # a trailing pipe, and an anchored pattern extracts an empty file in silence.
  awk '/<<.INVMEOF./{f=1;next} /^INVMEOF$/{f=0} f' "$(mr_orchestrator)"
}

# Source the generated orchestrator for function-level tests. It guards its own
# executable tail, so this loads definitions only.
mr_load_orchestrator() {
  # shellcheck source=/dev/null
  source "$(mr_orchestrator)"
  # The orchestrator sets `set -u` for its own run; don't leak it into tests.
  set +u
}
