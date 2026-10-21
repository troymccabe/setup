#!/usr/bin/env bats
# Host power behaviour — the 2026-10-20 outage.
#
# A power cut took down the fleet's only macOS host. Power came back, the Mac
# did not, its runners deregistered with it, and the dependent repo's macOS CI
# stalled ~4.5h. The installer now configures the host to boot again by itself
# and never sleep.
#
# The interesting part is NOT that it calls pmset — it is what it does when
# pmset cannot deliver. `pmset` accepts a key the machine does not support and
# silently ignores it (measured: only a misspelled key errors), so a naive
# install would print success and leave the host exactly as dark as before.
# These tests pin the three ways that goes wrong: unsupported feature, no
# sudo, and a write that is accepted and ignored. Each must be VISIBLE, and
# none may fail the install.

load helper

setup()    { mr_sandbox_init; }
teardown() { mr_sandbox_teardown; }

converged() {
  run mr_run_setup
  [ "$status" -eq 0 ] || { echo "install failed: $output"; return 1; }
}

# Every pmset write the installer made, as recorded by the stub.
pmset_writes() { mr_calls pmset | grep '^-a ' || true; }

# --- the silent no-op class -------------------------------------------------

@test "a machine without autorestart is NOT written blind — it is reported" {
  # A portable: `-g cap` omits autorestart. Writing it anyway would look like
  # success and leave the host down after the next cut.
  mr_pmset_cap 'displaysleep
disksleep
sleep'
  converged || return 1
  pmset_writes | grep -q autorestart && {
    echo "wrote an unsupported key: $(pmset_writes)"; return 1; }
  echo "$output" | grep -q "'autorestart' absent from 'pmset -g cap'" || {
    echo "no warning for the missing feature"; return 1; }
  # The consequence has to be spelled out, not left as a key name.
  echo "$output" | grep -qi 'leave this host down' || {
    echo "warning does not say what it costs"; return 1; }
}

@test "an unsupported sleep key is skipped rather than written" {
  mr_pmset_cap 'sleep
autorestart'
  converged || return 1
  pmset_writes | grep -q disksleep && { echo "wrote unsupported disksleep"; return 1; }
  pmset_writes | grep -q displaysleep && { echo "wrote unsupported displaysleep"; return 1; }
  echo "$output" | grep -q "'disksleep' absent" || return 1
  pmset_writes | grep -q 'sleep 0' || { echo "dropped the supported key too"; return 1; }
}

@test "a write that is ACCEPTED and IGNORED is caught by the read-back" {
  # The failure pmset cannot report: exit 0, nothing changed.
  mr_pmset_unapplied
  converged || return 1
  echo "$output" | grep -q 'did not read back as' || {
    echo "read-back did not notice an ignored write: $output"; return 1; }
}

@test "a key the machine does not report reads as UNVERIFIED, not as wrong or ✓" {
  # `-g cap` advertises autorestart and pmset accepts the write, but
  # `-g custom` never surfaces the key — so the write may well have worked and
  # simply cannot be confirmed. That is a third outcome: calling it "not in
  # effect" invents a failure, calling it ✓ invents a success.
  mr_pmset_custom 'AC Power:
 displaysleep         10
 disksleep            10
 sleep                10'
  export STUB_PMSET_UNREPORTED="autorestart"
  converged || return 1
  echo "$output" | grep -qE '\? *autorestart not reported' || {
    echo "no unverified state for an unreported key: $output"; return 1; }
  echo "$output" | grep -q 'autorestart did not read back' && {
    echo "reported an unverifiable key as wrong"; return 1; }
  echo "$output" | grep -q 'autorestart=1 ✓' && {
    echo "claimed an unverifiable key as confirmed"; return 1; }
  # The keys that ARE reported still confirm normally.
  echo "$output" | grep -q 'sleep=0 ✓' || { echo "lost the verifiable keys"; return 1; }
}

@test "no passwordless sudo: never blocks, surfaces the command, still converges" {
  export STUB_SUDO_DENIED=1
  converged || return 1
  echo "$output" | grep -q 'pmset needs sudo' || { echo "no sudo hint"; return 1; }
  # The hint must be a runnable command, not a description of one.
  echo "$output" | grep -qE 'sudo pmset -a .*autorestart 1' || {
    echo "hint is not copy-pasteable: $output"; return 1; }
  # And it must not claim the settings are in effect.
  echo "$output" | grep -q 'did not read back as' || {
    echo "claimed success with no sudo"; return 1; }
}

@test "power configuration never fails the install" {
  # A host that supports nothing and has no sudo still gets a runner: CI
  # resilience is an improvement, not a precondition.
  mr_pmset_cap ''
  export STUB_SUDO_DENIED=1
  converged || return 1
  [ -f "$(mr_plist)" ] || { echo "plist missing — power config aborted the install"; return 1; }
}

# --- auto-login: the other half of the fix ----------------------------------

@test "auto-login OFF is called out — autorestart alone does not restore CI" {
  # The LaunchAgent only loads in an Aqua session, so a host that reboots to
  # the login window has no runner. A half-fix must be visible at install.
  mr_autologin_off
  converged || return 1
  echo "$output" | grep -q 'auto-login is OFF' || { echo "silent half-fix"; return 1; }
  echo "$output" | grep -qi 'login window with NO runner' || {
    echo "does not explain the consequence"; return 1; }
}

@test "auto-login is never enabled by the installer — only reported" {
  # It needs FileVault off and leaves a console logged in; that is the
  # operator's trade-off, so the installer must not write the pref.
  mr_autologin_off
  converged || return 1
  mr_calls defaults | grep -q 'write.*autoLoginUser' && {
    echo "installer enabled auto-login itself"; return 1; }
  mr_calls defaults | grep -q 'kcpassword' && { echo "touched kcpassword"; return 1; }
  return 0
}

@test "auto-login ON reports clean, with no warning left over" {
  mr_autologin_on
  converged || return 1
  echo "$output" | grep -q 'auto-login is ON' || return 1
  echo "$output" | grep -q 'auto-login is OFF' && { echo "contradicts itself"; return 1; }
  return 0
}

# --- the shipped default ----------------------------------------------------

@test "a desktop gets both halves: never sleeps AND boots after a power cut" {
  converged || return 1
  local writes; writes="$(pmset_writes)"
  for want in 'sleep 0' 'displaysleep 0' 'disksleep 0' 'autorestart 1'; do
    printf '%s' "$writes" | grep -q -- "$want" || {
      echo "missing '$want' in: $writes"; return 1; }
  done
  # Applied via sudo -n (non-interactive), never a bare interactive sudo.
  mr_calls sudo | grep -q -- '-n pmset' || { echo "not run through sudo -n"; return 1; }
  echo "$output" | grep -q 'autorestart=1 ✓' || { echo "no read-back confirmation"; return 1; }
}

@test "re-running is idempotent — the same settings, no second behaviour" {
  converged || return 1
  local first; first="$(pmset_writes)"
  : > "$MR_SANDBOX/state/pmset.calls"
  converged || return 1
  [ "$(pmset_writes)" = "$first" ] || {
    echo "second run differed:"; echo "1: $first"; echo "2: $(pmset_writes)"; return 1; }
}
