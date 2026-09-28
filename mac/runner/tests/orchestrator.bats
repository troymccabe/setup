#!/usr/bin/env bats
# The generated orchestrator's decisions.
#
# This is the script that actually runs CI — a launchd loop that lives for
# months. It guards its own executable tail, so sourcing it loads definitions
# without starting a runner loop, and the decisions can be exercised directly.

load helper

setup() {
  mr_sandbox_init
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "install failed: $output"; return 1; }
  mr_load_orchestrator
}
teardown() { mr_sandbox_teardown; }

# --- cycle classification ---------------------------------------------------
# A refused runner exits 0 having done nothing, so exit status alone cannot
# tell it from a clean finish. Getting this wrong in either direction is
# expensive: too loose and the host hot-loops through an outage (observed:
# 8,245 cycles); too tight and an idle fleet backs itself off.

@test "a healthy cycle that ran a job is clean, whatever its duration" {
  [ "$(classify_cycle 0 1 240 0)" = "clean 0 0" ]
  [ "$(classify_cycle 0 1 4 0)" = "clean 0 0" ]
}

@test "an idle runner that waited and stopped is clean, not refused" {
  # No job, but far too long to be a refusal — run.sh blocked on the broker.
  [ "$(classify_cycle 0 0 900 0)" = "clean 0 0" ]
}

@test "exit 0 with no job inside the threshold is REFUSED" {
  local out; out="$(classify_cycle 0 0 4 0)"
  [ "${out%% *}" = "refused" ] || { echo "got: $out"; return 1; }
}

@test "a non-zero exit is a job failure, not a refusal — fixed 30s, streak reset" {
  [ "$(classify_cycle 1 0 120 5)" = "failed 30 0" ]
}

@test "refusal backoff escalates 30s per consecutive occurrence" {
  [ "$(classify_cycle 0 0 4 0)" = "refused 30 1" ]
  [ "$(classify_cycle 0 0 4 1)" = "refused 60 2" ]
  [ "$(classify_cycle 0 0 4 2)" = "refused 90 3" ]
}

@test "refusal backoff is capped, so a long outage does not park the host forever" {
  [ "$(classify_cycle 0 0 4 9)"   = "refused 300 10" ]
  [ "$(classify_cycle 0 0 4 50)"  = "refused 300 51" ]
}

@test "one real job resets the streak" {
  [ "$(classify_cycle 0 1 120 12)" = "clean 0 0" ]
}

@test "the threshold sits above VM boot and below any real job" {
  # Boot-to-listening is ~15-25s, so 59s with no job cannot be a runner that
  # waited; 61s can. The boundary is the whole reason an idle fleet is safe.
  [ "$(classify_cycle 0 0 59 0)" = "refused 30 1" ] || { echo "59s not refused"; return 1; }
  [ "$(classify_cycle 0 0 61 0)" = "clean 0 0" ]    || { echo "61s not clean"; return 1; }
}

# --- reap scoping -----------------------------------------------------------
# The property that lets two installs share a host. Startup happens on every
# KeepAlive restart and every login, so an unscoped sweep kills the other
# install's running job.

stage_host() {
  mr_tart_vms '[
    {"Name":"test-base-image","Source":"local","State":"stopped"},
    {"Name":"ephem-s1-aaaa1111","Source":"local","State":"running"},
    {"Name":"ephem-s2-bbbb2222","Source":"local","State":"running"},
    {"Name":"ephem-cccc3333","Source":"local","State":"running"}
  ]'
  # cleanup_vm shells out to tart; record what it was asked to delete.
  cleanup_vm() { printf '%s\n' "$1" >> "$MR_SANDBOX/state/reaped"; }
  : > "$MR_SANDBOX/state/reaped"
}
reaped_list() { sort "$MR_SANDBOX/state/reaped" 2>/dev/null | tr '\n' ' '; }

@test "an install reaps only VMs carrying its own prefix" {
  stage_host
  VM_PREFIX="ephem-s1-"
  reap_orphans
  [ "$(reaped_list)" = "ephem-s1-aaaa1111 " ] || { echo "reaped: $(reaped_list)"; return 1; }
}

@test "the sibling install's running VM is never touched" {
  stage_host
  VM_PREFIX="ephem-s2-"
  reap_orphans
  [[ "$(reaped_list)" != *"ephem-s1-"* ]] || { echo "reaped a sibling's VM: $(reaped_list)"; return 1; }
}

@test "the base image is never reaped" {
  stage_host
  VM_PREFIX="ephem-"
  reap_orphans
  [[ "$(reaped_list)" != *"test-base-image"* ]] || { echo "reaped the base image!"; return 1; }
}

# --- pending-runner ledger --------------------------------------------------
# An ephemeral runner killed while idle lingers in GitHub as offline forever.
# The ledger is what stops a reboot leaking registrations — a sibling engine
# without one accumulated 3,171 of them.

@test "ledger records and removes ids" {
  ledger_add 111; ledger_add 222; ledger_add 333
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" = "3" ]
  ledger_remove 222
  grep -qx 111 "$LEDGER" || return 1
  grep -qx 333 "$LEDGER" || return 1
  ! grep -qx 222 "$LEDGER" || { echo "222 survived removal"; return 1; }
}

@test "ledger_remove on an absent id is a no-op, not a truncation" {
  ledger_add 111
  ledger_remove 999
  grep -qx 111 "$LEDGER" || { echo "removing an absent id destroyed the ledger"; return 1; }
}

@test "startup reaping empties the ledger so ids are never deregistered twice" {
  ledger_add 111; ledger_add 222
  deregister_runner() { printf '%s\n' "$1" >> "$MR_SANDBOX/state/dereg"; }
  : > "$MR_SANDBOX/state/dereg"
  reap_pending_runners
  [ "$(sort "$MR_SANDBOX/state/dereg" | tr '\n' ' ')" = "111 222 " ] || {
    echo "deregistered: $(cat "$MR_SANDBOX/state/dereg")"; return 1; }
  [ ! -s "$LEDGER" ] || { echo "ledger not emptied"; return 1; }
}

# --- credential resolution --------------------------------------------------

@test "without op-read, the PAT comes straight from config.env" {
  OP_ITEM_REF=""
  GH_PAT="ghp_fromconfig"
  resolve_gh_pat
  [ "$GH_PAT_CURRENT" = "ghp_fromconfig" ]
}

@test "op failure classes are logged distinguishably, and never echo op's raw output" {
  OP_ITEM_REF="op://vault/item/credential"
  OP_TOKEN_FILE="$MR_SANDBOX/op-token"
  printf 'sa-token\n' > "$OP_TOKEN_FILE"
  GH_PAT=""
  export STUB_OP_FAIL=1   # must be exported: the op stub is a separate process
  run resolve_gh_pat
  [ "$status" -ne 0 ] || { echo "a failed op read reported success"; return 1; }
  [[ "$output" == *"ERROR"* ]] || { echo "no error logged: $output"; return 1; }
}

@test "a missing op token file fails before any VM is created" {
  OP_ITEM_REF="op://vault/item/credential"
  OP_TOKEN_FILE="$MR_SANDBOX/does-not-exist"
  GH_PAT=""
  run resolve_gh_pat
  [ "$status" -ne 0 ]
  [[ "$output" == *"token file missing"* ]] || { echo "$output"; return 1; }
}
