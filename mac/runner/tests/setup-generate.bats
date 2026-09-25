#!/usr/bin/env bats
# What a successful run writes to the host.
#
# The installer's real output is three generated artifacts — config.env,
# orchestrator.sh and the launchd plist. They are what actually runs CI for
# months afterwards, so they are worth asserting on directly: a bug here
# surfaces as a fleet that misbehaves at 3am, not as a failed install.

load helper

setup()    { mr_sandbox_init; }
teardown() { mr_sandbox_teardown; }

converged() {
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "install failed: $output"; return 1; }
}

# --- config.env -------------------------------------------------------------

@test "config.env is written 0600 — it can hold the PAT" {
  converged || return 1
  local mode
  mode="$(stat -f '%Lp' "$(mr_config_file)" 2>/dev/null || stat -c '%a' "$(mr_config_file)")"
  [ "$mode" = "600" ] || { echo "mode is $mode"; return 1; }
}

@test "default credential model persists the PAT and records no vault reference" {
  converged || return 1
  [ "$(mr_config_value GH_PAT)" = "ghp_testtoken" ] || return 1
  grep -q '^OP_ITEM_REF=' "$(mr_config_file)" && { echo "OP_ITEM_REF written in default model"; return 1; }
  return 0
}

@test "op-read model NEVER persists the PAT — only the vault reference" {
  export OP_ITEM_REF="op://vault/runner-jit-pat/credential"
  export OP_TOKEN_FILE="$MR_SANDBOX/op-token"
  printf 'sa-token\n' > "$OP_TOKEN_FILE"   # pre-seeded: no tty to prompt on
  converged || return 1
  grep -q '^GH_PAT=' "$(mr_config_file)" && { echo "PAT persisted under op-read"; return 1; }
  [ "$(mr_config_value OP_ITEM_REF)" = "op://vault/runner-jit-pat/credential" ] || return 1
  # The whole point of the model: the token file is the only secret at rest.
  ! grep -q "ghp_testtoken" "$(mr_config_file)" || { echo "PAT leaked into config.env"; return 1; }
}

@test "op-read install fails loudly when the vault reference cannot be read" {
  export OP_ITEM_REF="op://vault/missing/credential"
  export OP_TOKEN_FILE="$MR_SANDBOX/op-token"
  printf 'sa-token\n' > "$OP_TOKEN_FILE"
  export STUB_OP_FAIL=1
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read"* ]] || { echo "$output"; return 1; }
}

@test "VM_PREFIX and RUNNER_VERSION are recorded so the orchestrator inherits them" {
  export VM_PREFIX="ephem-s2-"
  export RUNNER_VERSION="2.337.0"
  converged || return 1
  [ "$(mr_config_value VM_PREFIX)" = "ephem-s2-" ] || return 1
  [ "$(mr_config_value RUNNER_VERSION)" = "2.337.0" ] || return 1
}

# --- orchestrator.sh --------------------------------------------------------

@test "the generated orchestrator is valid bash" {
  converged || return 1
  run bash -n "$(mr_orchestrator)"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the generated in-VM script is valid bash" {
  converged || return 1
  mr_invm_script > "$MR_SANDBOX/invm.sh"
  [ -s "$MR_SANDBOX/invm.sh" ] || { echo "in-VM script came out empty"; return 1; }
  run bash -n "$MR_SANDBOX/invm.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the orchestrator names its VMs with the configured prefix, not a hardcoded one" {
  export VM_PREFIX="ephem-s2-"
  converged || return 1
  grep -q 'vm_name="${VM_PREFIX}' "$(mr_orchestrator)" || { echo "vm_name is not prefix-driven"; return 1; }
  # No literal ephem- may survive: that is the bug this prefix exists to fix.
  ! grep -q 'startswith("ephem-")' "$(mr_orchestrator)" || { echo "unscoped reap survived"; return 1; }
}

@test "the orchestrator defaults VM_PREFIX, so a config.env predating it still starts" {
  converged || return 1
  grep -q 'VM_PREFIX="${VM_PREFIX:-ephem-}"' "$(mr_orchestrator)" \
    || { echo "no backward-compatible default"; return 1; }
}

@test "RUNNER_VERSION reaches the in-VM script as an authority, not just a fallback" {
  converged || return 1
  local invm; invm="$(mr_invm_script)"
  # The regression this guards: the install branch used to run ONLY when no
  # runner was baked, making RUNNER_VERSION inert on every baked image.
  [[ "$invm" == *"runner_installed_version"* ]] || { echo "no version probe"; return 1; }
  [[ "$invm" == *"replacing"* ]] || { echo "no replace path"; return 1; }
}

# --- plist ------------------------------------------------------------------

@test "the plist is labelled and points at this install's config dir" {
  export LAUNCHD_LABEL="dev.testorg.gha-runner-s2"
  export CONFIG_DIR="$HOME/.gha-runner/s2"
  converged || return 1
  local p; p="$(mr_plist)"
  [ -f "$p" ] || { echo "no plist at $p"; return 1; }
  grep -q "<string>dev.testorg.gha-runner-s2</string>" "$p" || return 1
  grep -q "<string>${CONFIG_DIR}</string>" "$p" || return 1
}

@test "the plist carries Homebrew's bin on PATH — launchd agents do not inherit a login PATH" {
  converged || return 1
  grep -q "/opt/homebrew/bin" "$(mr_plist)" || return 1
}

@test "the plist contains no credential" {
  export OP_ITEM_REF="op://vault/runner-jit-pat/credential"
  export OP_TOKEN_FILE="$MR_SANDBOX/op-token"
  printf 'sa-token\n' > "$OP_TOKEN_FILE"
  converged || return 1
  local p; p="$(mr_plist)"
  # Assert on the actual secret VALUES. A pattern like "PAT" matches
  # StandardOutPath and PATH, so it reports a leak on a clean plist — the
  # failure mode that makes people delete the test rather than trust it.
  ! grep -q "ghp_testtoken" "$p" || { echo "the PAT is in the plist"; return 1; }
  ! grep -q "sa-token"      "$p" || { echo "the service-account token is in the plist"; return 1; }
  # Nor any env key that could carry one: the op-read model exists precisely so
  # no credential lives in a file nobody audits.
  ! grep -q "<key>GH_PAT</key>" "$p" || { echo "GH_PAT key in plist"; return 1; }
  ! grep -q "<key>OP_SERVICE_ACCOUNT_TOKEN</key>" "$p" || { echo "op token key in plist"; return 1; }
}

@test "the launchd service is cycled so a re-run actually takes effect" {
  converged || return 1
  local calls; calls="$(mr_calls launchctl)"
  [[ "$calls" == *"unload"* ]] || { echo "never unloaded: $calls"; return 1; }
  [[ "$calls" == *"load"* ]]   || { echo "never loaded: $calls"; return 1; }
}
