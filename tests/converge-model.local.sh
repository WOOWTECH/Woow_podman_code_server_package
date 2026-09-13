# shellcheck shell=bash
# tests/converge-model.local.sh: code-server-specific assertions, sourced at the end of
# tests/converge-model.sh (which defines REPO, run, npass, nfail and FAILED).
# shellcheck disable=SC2154 # REPO, npass, nfail, FAILED come from tests/converge-model.sh
# shellcheck disable=SC2016 # the greps look for literal shell text in another script

local_ok() { npass=$((npass + 1)); printf 'ok    %s\n' "$1"; }
local_fail() { nfail=$((nfail + 1)); FAILED+=("$1"); printf 'FAIL  %s\n      | %s\n' "$1" "$2"; }
local_check() { if [[ -z $2 ]]; then local_ok "$1"; else local_fail "$1" "$2"; fi; }

# A converge must not move the workspace, the port or the key directories: every one of them is
# read off the running container, and the only defaults come from --bind / --port.
msg=''
for kv in "WS:/workspace" "SSHD:/home/coder/.ssh" "GITCFG:/etc/gitconfig" "HOSTBIN:/mnt/host-local-bin"; do
  grep -qE "^${kv%%:*}=\\\$\\(mount_src \"\\\$CONTAINER\" ${kv#*:}\\)\$" "$REPO/scripts/converge.sh" \
    || msg="$msg; ${kv%%:*} is not read off the running container's ${kv#*:} mount"
done
grep -qF 'BIND=${bind:-$cur_bind} PORT=${port:-$cur_port}' "$REPO/scripts/converge.sh" \
  || msg="$msg; the publish address and port are not taken from the running container"
local_check t_local_every_path_and_port_comes_from_the_running_container "${msg#; }"

# The login password. install.sh generates a new one when neither the secret nor the legacy env
# file has it - which would lock the user out of a converge they were told is a no-op.
msg=''
grep -q 'would generate a NEW login password' "$REPO/scripts/converge.sh" \
  || msg='converge.sh does not refuse a silent password rotation'
grep -q 'code-server-config' "$REPO/scripts/converge.sh" || msg="$msg; the password secret is not checked"
local_check t_local_a_silent_password_rotation_is_refused "$msg"

# Nothing here may remove a volume or run a bulk podman command: woow-code-server-pi-data holds
# the provider tokens and woow-code-server-ide the IDE state.
msg=''
grep -nE 'podman volume (rm|prune)' "$REPO/scripts/converge.sh" && msg='converge.sh removes a volume'
grep -nE 'podman (system prune|system reset|stop -a|rm -a)' "$REPO/scripts/converge.sh" \
  && msg="$msg; converge.sh runs an unqualified bulk command"
grep -q 'cv_volume_identity' "$REPO/scripts/converge.sh" || msg="$msg; the volumes are not fingerprinted"
grep -q 'cv_write_checksums' "$REPO/scripts/converge.sh" || msg="$msg; the backup is not checksummed"
grep -q 'DOWNTIME_MS' "$REPO/scripts/converge.sh" || msg="$msg; the downtime is not recorded"
local_check t_local_no_volume_is_ever_removed "$msg"

# The tailscale sidecar carries a tailnet node identity in its state volume. The converge may
# only include it when the container is already there, and must never ask for a new auth key.
msg=''
grep -qF 'TAILSCALE=no' "$REPO/scripts/converge.sh" || msg='the sidecar is not off by default'
# -F with an embedded newline is TWO patterns to grep, and either one matching would pass:
# read the line after the `if` instead.
grep -A1 -F 'if podman container exists "$TS_CONTAINER"; then' "$REPO/scripts/converge.sh" \
  | grep -qF 'TAILSCALE=yes' || msg="$msg; TAILSCALE=yes is not gated on the container existing"
grep -qF 'if [[ $TAILSCALE == yes ]]; then SETS+=(--with-tailscale); else SETS+=(--without-tailscale); fi' \
  "$REPO/scripts/converge.sh" || msg="$msg; install.sh is not told which of the two the host has"
grep -q 'ts-authkey-file' "$REPO/scripts/converge.sh" && msg="$msg; the converge passes an auth key"
local_check t_local_the_tailscale_sidecar_is_detected_not_assumed "$msg"

# Found on toypark1234: converge.sh takes ql_lock and then runs install.sh, whose own ql_lock
# aborted the run. install.sh must skip the lock when the caller already holds it.
msg=''
grep -qF '[[ ${WOOW_QL_LOCK_HELD:-} == "$APP" ]] || ql_lock "$APP"' "$REPO/scripts/install.sh" \
  || msg='install.sh takes the lock unconditionally; the converge would deadlock on itself'
grep -qF 'export WOOW_QL_LOCK_HELD=$CV_APP' "$REPO/scripts/converge.sh" \
  || msg="$msg; converge.sh does not announce that it holds the lock"
local_check t_local_install_sh_honours_the_lock_the_converge_holds "${msg#; }"
