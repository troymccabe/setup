#!/usr/bin/env bats
# Inputs the installer must refuse.
#
# Every one of these guards a production input: the script converges a real CI
# host, so a value it accepts and shouldn't becomes a broken fleet rather than
# a failed build. Each refusal must also happen BEFORE anything on the host is
# written, which is why these assert on exit status and message rather than on
# side effects.

load helper

setup()    { mr_sandbox_init; }
teardown() { mr_sandbox_teardown; }

@test "GH_ORG is required" {
  unset GH_ORG
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_ORG"* ]] || { echo "$output"; return 1; }
}

@test "GH_PAT is required" {
  unset GH_PAT
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_PAT"* ]] || { echo "$output"; return 1; }
}

# --- VM_PREFIX --------------------------------------------------------------
# The prefix is spliced into VM names and matched with startswith() when
# reaping, so a malformed one either cannot name a VM or widens the reap.

@test "VM_PREFIX accepts the documented forms" {
  local p
  for p in "ephem-" "ephem-s1-" "ephem-s2-" "a-" "run-2-"; do
    export VM_PREFIX="$p"
    run mr_run_setup
    [[ "$output" != *"VM_PREFIX must be"* ]] || { echo "rejected valid prefix '$p': $output"; return 1; }
  done
}

@test "VM_PREFIX rejects uppercase, missing trailing dash, underscores, leading dash" {
  local p
  for p in "Ephem-" "ephem" "ephem_s1-" "-ephem-" "ephem-s1"; do
    export VM_PREFIX="$p"
    run mr_run_setup
    [ "$status" -ne 0 ] || { echo "accepted invalid prefix '$p'"; return 1; }
    [[ "$output" == *"VM_PREFIX must be"* ]] || { echo "wrong error for '$p': $output"; return 1; }
  done
}

@test "empty VM_PREFIX falls back to the default rather than failing" {
  export VM_PREFIX=""
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mr_config_value VM_PREFIX)" = "ephem-" ] || { echo "got '$(mr_config_value VM_PREFIX)'"; return 1; }
}

# --- image inputs -----------------------------------------------------------

@test "SOURCE_IMAGE pinned to :latest is refused — a moving tag rolls the fleet silently" {
  unset BASE_IMAGE
  export SOURCE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"pinned to a version tag"* ]] || { echo "$output"; return 1; }
}

@test "SOURCE_IMAGE with no tag at all is refused" {
  unset BASE_IMAGE
  export SOURCE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"pinned to a version tag"* ]] || { echo "$output"; return 1; }
}

@test "BASE_IMAGE must be a LOCAL vm name, not a registry reference" {
  export BASE_IMAGE="ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"must name an existing LOCAL tart VM"* ]] || { echo "$output"; return 1; }
}

@test "BASE_IMAGE that is not present locally is refused" {
  export BASE_IMAGE="not-on-this-host"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || { echo "$output"; return 1; }
}

@test "BASE_IMAGE sharing VM_PREFIX is refused — the reaper would delete the image" {
  export VM_PREFIX="ephem-"
  export BASE_IMAGE="ephem-base"
  mr_tart_vms '[{"Name":"ephem-base","Source":"local","State":"stopped","Disk":140}]'
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not start with VM_PREFIX"* ]] || { echo "$output"; return 1; }
}

# --- credentials ------------------------------------------------------------

@test "OP_ITEM_REF must be a 1Password secret reference" {
  export OP_ITEM_REF="runner-jit-pat"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a 1Password secret reference"* ]] || { echo "$output"; return 1; }
}
