#!/usr/bin/env bats
# Two installs on one host must not have overlapping VM prefixes.
#
# Reaping matches with startswith(), and startup happens on every KeepAlive
# restart and every login — not just on install. So an install whose prefix
# overlaps another's destroys that one's running VM and kills the CI job on it,
# with nothing in either log explaining why. Prefixes must be DISJOINT, not
# merely different: the default "ephem-" also matches "ephem-s1-...".

load helper

setup()    { mr_sandbox_init; }
teardown() { mr_sandbox_teardown; }

# Stage an install already on this host: a plist recording its CONFIG_DIR, and
# a config.env declaring its prefix. Pass "" for a config predating VM_PREFIX.
stage_existing_install() {
  local prefix="$1" dir="$HOME/.gha-runner/existing"
  mkdir -p "$dir"
  cat > "$HOME/Library/LaunchAgents/dev.testorg.gha-runner-existing.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>dev.testorg.gha-runner-existing</string>
  <key>EnvironmentVariables</key><dict>
    <key>CONFIG_DIR</key>
    <string>${dir}</string>
  </dict>
</dict></plist>
PLIST
  {
    printf 'GH_ORG="TestOrg"\n'
    [ -n "$prefix" ] && printf 'VM_PREFIX="%s"\n' "$prefix"
  } > "$dir/config.env"
  # The new install must be a DIFFERENT install, or it just replaces this one.
  export LAUNCHD_LABEL="dev.testorg.gha-runner-new"
  export CONFIG_DIR="$HOME/.gha-runner/new"
}

@test "an identical prefix is refused" {
  stage_existing_install "ephem-s1-"
  export VM_PREFIX="ephem-s1-"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps"* ]] || { echo "$output"; return 1; }
}

@test "a prefix that CONTAINS the existing one is refused (ephem- vs ephem-s1-)" {
  stage_existing_install "ephem-s1-"
  export VM_PREFIX="ephem-"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps"* ]] || { echo "$output"; return 1; }
}

@test "a prefix CONTAINED BY the existing one is refused (ephem-s1- vs ephem-)" {
  stage_existing_install "ephem-"
  export VM_PREFIX="ephem-s1-"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps"* ]] || { echo "$output"; return 1; }
}

@test "an install predating VM_PREFIX is read as the default it actually ran with" {
  stage_existing_install ""        # no VM_PREFIX key at all
  export VM_PREFIX="ephem-s1-"
  run mr_run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"ephem-"* ]]   || { echo "did not report the assumed prefix: $output"; return 1; }
}

@test "disjoint slot prefixes are allowed — this is the supported multi-slot layout" {
  stage_existing_install "ephem-s1-"
  export VM_PREFIX="ephem-s2-"
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "refused a valid layout: $output"; return 1; }
  [ "$(mr_config_value VM_PREFIX)" = "ephem-s2-" ]
}

@test "an unrelated prefix is allowed" {
  stage_existing_install "ephem-s1-"
  export VM_PREFIX="other-"
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the guard refuses BEFORE writing anything to the host" {
  stage_existing_install "ephem-"
  export VM_PREFIX="ephem-s1-"
  run mr_run_setup
  [ "$status" -ne 0 ]
  # Nothing of the new install may exist: no config, no orchestrator, no plist.
  [ ! -e "$CONFIG_DIR/config.env" ]     || { echo "wrote config.env anyway"; return 1; }
  [ ! -e "$CONFIG_DIR/orchestrator.sh" ] || { echo "wrote orchestrator anyway"; return 1; }
  [ ! -e "$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist" ] || { echo "wrote plist anyway"; return 1; }
  [ -z "$(mr_calls launchctl)" ] || { echo "touched launchd anyway"; return 1; }
}

@test "re-running the SAME install is not a conflict with itself" {
  # The common case: converging a host that is already converged.
  export VM_PREFIX="ephem-s1-"
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "first run failed: $output"; return 1; }
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "re-run treated itself as a conflict: $output"; return 1; }
}
