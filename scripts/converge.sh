#!/usr/bin/env bash
# scripts/converge.sh: bring a HAND-INSTALLED code-server Quadlet deployment
# (woowtechopenclaw) onto the units this repo ships, with the evidence an operator needs.
#
#   scripts/converge.sh [--check] [--yes] [--bind ADDR] [--port N] [--no-auto-rollback]
#   scripts/converge.sh --rollback [--yes]
#   scripts/converge.sh --status
#
#   --check      pre-flight + drift report + a dry run of install.sh; changes nothing
#   --bind ADDR  publish address for the converged unit (default: the one in use today)
#   --port N     publish port (default: the one in use today)
#   --no-auto-rollback  leave a failed converge in place for inspection
#   --rollback   put the previous unit files back and restart code-server on them
#   --status     print what the last converge recorded
#
# THIS IS NOT A MIGRATION, and there is deliberately no migrate-legacy.sh here. The stack is
# already Quadlet: the container name (code-server), the volumes (woow-code-server-ide,
# woow-code-server-pi-data) and the optional tailscale sidecar that openclaw's hand-written
# units declare are exactly the ones this repo declares, so there is nothing to adopt by rename
# and no legacy container to keep for a rollback. Converging IS `scripts/install.sh`:
# ql_install_files backs up each foreign file with our name before writing ours, and
# ql_apply_units restarts only the units whose file actually changed. That is the path
# Woow_podman_pi_agent_package took on toypark1234 - a hand-edited pi-web.container with
# literal /home/<user> paths, repointed at %h/%t for 1.5 s of downtime - and its README calls
# it "Converging a hand-edited install".
#
# The drift on openclaw is exactly that shape, plus two more things:
#   - Volume=/home/woowtechopenclaw/Desktop:/workspace and .../.ssh where this repo writes
#     @@CODE_SERVER_WORKSPACE@@ / @@CODE_SERVER_SSH_DIR@@, rendered from %h. The unit is
#     account-specific; this repo's is not.
#   - Image=localhost/woow-code-server:latest + AutoUpdate=local, where the repo pins
#     :<VERSION> with Pull=never, and the login PASSWORD lives in a plaintext EnvironmentFile
#     where the repo mounts a podman secret. install.sh adopts that password itself, so the
#     login does not change.
#
# What this wrapper adds around that one command: a pre-flight that refuses instead of
# guessing, a named report of WHAT drifted, a checksummed backup of both volumes and every unit
# file taken BEFORE anything is overwritten, proof that the volumes were adopted rather than
# re-created (CreatedAt + mountpoint inode, before and after), a downtime measured from the
# outside every 100 ms, and --rollback.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=converge-lib.sh
. "$REPO/scripts/converge-lib.sh"

# ---- per-repo settings -------------------------------------------------------------------
CV_APP=woow-code-server
CV_STATE_DIR=${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/$CV_APP
CV_STATE=$CV_STATE_DIR/converge.state
CV_BACKUP_ROOT=$HOME/backups/$CV_APP
ENV_FILE=$HOME/.config/$CV_APP/$CV_APP.env
LEGACY_ENV=$HOME/.config/$CV_APP/env
DOC_URL='Documentation=https://github.com/WOOWTECH/Woow_podman_code_server_package'
CONTAINER='code-server'
TS_CONTAINER=woow-tailscale-code-server
OWN_VOLUMES=(woow-code-server-ide woow-code-server-pi-data)
PLAIN_UNITS=(code-server-health.service code-server-health.timer)
PODMAN_MIN=4.9
# ------------------------------------------------------------------------------------------

mode=converge bind='' port='' auto_rollback=1 ASSUME_YES=0
while (($#)); do
  case $1 in
    --check) mode=check ;;
    --bind) bind=${2:?--bind needs an address}; shift ;;
    --port) port=${2:?--port needs a number}; shift ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$CV_APP
confirm() {
  ((!ASSUME_YES)) || return 0
  [[ -t 0 ]] || ql_die "$1 (not a terminal: pass --yes)"
  local a
  read -r -p "$1. Continue? [y/N] " a
  [[ $a == [yY]* ]] || ql_die "aborted"
}
# spec_path <abs path>: %h/... so the converged unit works on any account
spec_path() {
  local p=$1
  [[ $p == "$HOME"/* ]] && p="%h/${p#"$HOME"/}"
  printf '%s' "$p"
}
mount_src() {
  podman inspect --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{println}}{{end}}' "$1" 2>/dev/null \
    | sed -n "s#^$2|##p" | tail -n1
}

if [[ $mode == status ]]; then
  if [[ -f $CV_STATE ]]; then cat "$CV_STATE"; else echo "no converge recorded in $CV_STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
ql_lock "$CV_APP"
export WOOW_QL_LOCK_HELD=$CV_APP

# =============================================================================================
# rollback
# =============================================================================================
if [[ $mode == rollback ]]; then
  bk=$(cv_state_get BACKUP)
  [[ -n $bk && -d $bk ]] || ql_die "no converge backup recorded in $CV_STATE"
  [[ $(cv_state_get STATUS) == converged || $(cv_state_get STATUS) == failed ]] \
    || ql_die "nothing to roll back (status: $(cv_state_get STATUS))"
  confirm "--rollback puts the unit files from $bk/units back and restarts code-server on them"
  t0=$(cv_now_ms)
  cv_restore_units "$bk"
  systemctl --user daemon-reload
  systemctl --user restart code-server.service
  if podman container exists "$TS_CONTAINER" && cv_unit_exists "$TS_CONTAINER.service"; then
    systemctl --user restart "$TS_CONTAINER.service" || ql_warn "could not restart $TS_CONTAINER.service"
  fi
  ql_wait_http "http://$(cv_state_get HOST):$(cv_state_get PORT)/healthz" '200' 300 \
    || ql_die "code-server did not answer /healthz after the rollback"
  t1=$(cv_now_ms)
  cv_state_set STATUS rolled-back
  ql_info "rolled back in $(((t1 - t0) / 1000)).$(printf '%03d' $(((t1 - t0) % 1000))) s; the previous unit files serve again"
  ql_info "the old :latest image is still on the host, so the restored unit starts on exactly what it ran before"
  exit 0
fi

# =============================================================================================
# 1. pre-flight (read-only)
# =============================================================================================
ql_info "step 1/5: pre-flight"
podman container exists "$CONTAINER" \
  || ql_die "container $CONTAINER does not exist: this host does not run code-server, so there is nothing to converge (a fresh host runs scripts/install.sh)"
label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$CONTAINER" 2>/dev/null || true)
[[ $label == code-server.service ]] \
  || ql_die "container $CONTAINER is not managed by the Quadlet unit code-server.service (PODMAN_SYSTEMD_UNIT='$label'); that is a migration, not a converge - resolve it by hand"
cv_running "$CONTAINER" || ql_die "container $CONTAINER is not running; start it first, so the converge can read its settings and prove the volumes are adopted"
for v in "${OWN_VOLUMES[@]}"; do
  podman volume exists "$v" \
    || ql_die "volume $v does not exist, but code-server is running: refusing to guess where the IDE and pi state are"
done

# Every value below is read off the running container, not defaulted from the repo: a converge
# must not move a workspace, a port or a key directory by accident.
WS=$(mount_src "$CONTAINER" /workspace)
SSHD=$(mount_src "$CONTAINER" /home/coder/.ssh)
GITCFG=$(mount_src "$CONTAINER" /etc/gitconfig)
HOSTBIN=$(mount_src "$CONTAINER" /mnt/host-local-bin)
[[ -n $WS ]] || ql_die "$CONTAINER has no /workspace mount; this converge does not know that shape"
for pair in "workspace:$WS" "ssh dir:$SSHD" "gitconfig:$GITCFG" "host bin:$HOSTBIN"; do
  v=${pair#*:}
  [[ -n $v ]] || ql_warn "${pair%%:*} is not mounted today; install.sh will add it from the env file's default"
done
pub=$(podman inspect --format '{{range $p, $b := .NetworkSettings.Ports}}{{$p}}|{{range $b}}{{.HostIP}}:{{.HostPort}} {{end}}{{println}}{{end}}' "$CONTAINER") \
  || ql_die "cannot read the published ports of $CONTAINER"
row=$(sed -n 's#^8080/tcp|##p' <<<"$pub" | tr ' ' '\n' | grep -m1 ':') \
  || ql_die "$CONTAINER publishes no host port for 8080/tcp"
cur_bind=${row%:*} cur_port=${row##*:}
[[ -n $cur_bind ]] || cur_bind=0.0.0.0
BIND=${bind:-$cur_bind} PORT=${port:-$cur_port}
HOST=$BIND
[[ $HOST != 0.0.0.0 ]] || HOST=127.0.0.1
if [[ $BIND != 127.0.0.1 ]]; then
  ql_warn "code-server stays published on $BIND:$PORT - the converge keeps today's exposure rather than changing it silently."
  ql_warn "That port is a password prompt over plain HTTP in front of a container that mounts ${SSHD:-~/.ssh} and ${WS}: narrow it with --bind 127.0.0.1 when a proxy is in front."
fi
if command -v ss >/dev/null 2>&1 && [[ $PORT != "$cur_port" ]] && [[ -n $(ss -ltnH "sport = :$PORT" 2>/dev/null || true) ]]; then
  ql_die "port $PORT is already in use on this host; pick another with --port"
fi
TAILSCALE=no
if podman container exists "$TS_CONTAINER"; then
  TAILSCALE=yes
  ql_info "the tailscale sidecar $TS_CONTAINER is present: it is converged too (its node identity lives in the volume and is kept)"
fi
PROVIDER=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | sed -n 's/^PI_DEFAULT_PROVIDER=//p' | tail -n1)
MODEL=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | sed -n 's/^PI_DEFAULT_MODEL=//p' | tail -n1)
if [[ -z $PROVIDER || -z $MODEL ]] && [[ -f $LEGACY_ENV ]]; then
  PROVIDER=${PROVIDER:-$(sed -n 's/^PI_DEFAULT_PROVIDER=//p' "$LEGACY_ENV" | tail -n1)}
  MODEL=${MODEL:-$(sed -n 's/^PI_DEFAULT_MODEL=//p' "$LEGACY_ENV" | tail -n1)}
fi
# The login password: install.sh adopts it from the pre-Quadlet env file into the podman
# secret, so the login does not change. Without either, the converge would rotate it silently.
if ! podman secret exists code-server-config 2>/dev/null; then
  if [[ ! -f $LEGACY_ENV ]] || ! grep -q '^PASSWORD=.' "$LEGACY_ENV"; then
    ql_die "no podman secret code-server-config and no PASSWORD= in $LEGACY_ENV: install.sh would generate a NEW login password. Put the current one in $LEGACY_ENV first, or accept the rotation with: scripts/install.sh --rotate-password"
  fi
  ql_info "the login password will be adopted from $LEGACY_ENV into the podman secret code-server-config (not printed)"
fi
ql_info "code-server publishes $cur_bind:$cur_port, workspace ${WS}, pi default ${PROVIDER:-?}/${MODEL:-?}, tailscale sidecar $TAILSCALE"

# =============================================================================================
# 2. drift report
# =============================================================================================
ql_info "step 2/5: what drifted (installed files vs this repo's shape)"
OWN_FILES=(code-server.container woow-code-server-ide.volume woow-code-server-pi.volume
  code-server-health.service code-server-health.timer)
[[ $TAILSCALE != yes ]] || OWN_FILES+=("$TS_CONTAINER.container" "$TS_CONTAINER.volume")
drifted=0
cv_drift_report "${OWN_FILES[@]}" || drifted=1
((drifted)) || ql_info "nothing drifted. install.sh is still the right command: it will report 0 changed files and restart nothing"

SETS=(--bind "$BIND" --port "$PORT")
[[ -z $PROVIDER ]] || SETS+=(--set "PI_DEFAULT_PROVIDER=$PROVIDER")
[[ -z $MODEL ]] || SETS+=(--set "PI_DEFAULT_MODEL=$MODEL")
[[ -z $WS ]] || SETS+=(--set "CODE_SERVER_WORKSPACE=$(spec_path "$WS")")
[[ -z $SSHD ]] || SETS+=(--set "CODE_SERVER_SSH_DIR=$(spec_path "$SSHD")")
[[ -z $GITCFG ]] || SETS+=(--set "CODE_SERVER_GITCONFIG=$(spec_path "$GITCFG")")
[[ -z $HOSTBIN ]] || SETS+=(--set "CODE_SERVER_HOST_BIN=$(spec_path "$HOSTBIN")")
if [[ $TAILSCALE == yes ]]; then SETS+=(--with-tailscale); else SETS+=(--without-tailscale); fi

if [[ $mode == check ]]; then
  ql_info "step 3/5 (--check): install.sh --dry-run"
  "$REPO/scripts/install.sh" --dry-run --yes "${SETS[@]}" \
    || ql_die "install.sh --dry-run failed; the converge would not have got past this point"
  ql_info "--check complete; nothing was changed"
  exit 0
fi

# =============================================================================================
# 3. backup first
# =============================================================================================
confirm "the converge restarts code-server (and the tailscale sidecar when its file changes)"
ql_info "step 3/5: backup (both volumes, the unit files, the inspect, the env files) with checksums"
bk=$(cv_new_backup_dir "$CV_BACKUP_ROOT/converge-$(date +%Y%m%d-%H%M%S)")
cv_backup_units "$bk" "${OWN_FILES[@]}"
podman inspect "$CONTAINER" >"$bk/inspect.json"
chmod 600 -- "$bk/inspect.json"
[[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$bk/$CV_APP.env"
[[ ! -f $LEGACY_ENV ]] || cp -p -- "$LEGACY_ENV" "$bk/legacy-env"
# The IDE volume holds unsaved settings and extension state; the pi volume holds the provider
# tokens. Export both while the container runs - neither is a database, so a hot copy is fine.
for v in "${OWN_VOLUMES[@]}"; do ql_backup_volume "$v" "$bk" >/dev/null; done
{
  printf 'publish: %s:%s\n' "$cur_bind" "$cur_port"
  printf 'workspace: %s\nssh: %s\ngitconfig: %s\nhost bin: %s\n' "$WS" "$SSHD" "$GITCFG" "$HOSTBIN"
  printf 'image: %s\n' "$(podman inspect --format '{{.ImageName}} {{.Image}}' "$CONTAINER")"
  printf 'tailscale sidecar: %s\n' "$TAILSCALE"
  for v in "${OWN_VOLUMES[@]}"; do printf 'volume %s: %s\n' "$v" "$(cv_volume_identity "$v")"; done
  printf 'healthz before: %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$HOST:$cur_port/healthz" || echo 000)"
} >"$bk/precheck.txt"
chmod 600 -- "$bk/precheck.txt"
cv_state_set BACKUP "$bk"
cv_state_set HOST "$HOST"
cv_state_set PORT "$PORT"
for v in "${OWN_VOLUMES[@]}"; do cv_state_set "VOLID_$v" "$(cv_volume_identity "$v")"; done
cv_write_checksums "$bk"
ql_info "backup in $bk (verify with: cd $bk && sha256sum -c SHA256SUMS)"

# The hand-installed plain health units are ours but in no manifest: move them aside so
# ql_install_files may write this repo's versions instead of refusing them as foreign.
mkdir -p "$bk/rendered"
cp -p "$REPO"/systemd/code-server-health.service "$REPO"/systemd/code-server-health.timer "$bk/rendered/"
cv_adopt_plain_units "$CV_APP" "$bk/rendered" "$DOC_URL" "${PLAIN_UNITS[@]}"

# =============================================================================================
# 4. the converge itself: scripts/install.sh
# =============================================================================================
ql_info "step 4/5: scripts/install.sh (the converge; it restarts only the units whose file changed)"
probe=$bk/downtime-probe.log
cv_probe_start "http://$HOST:$cur_port/healthz" "$probe"
T0=$(cv_now_ms)
failed=0
"$REPO/scripts/install.sh" --yes "${SETS[@]}" 2>&1 | tee "$bk/install.log" || failed=1
T1=$(cv_now_ms)
sleep 2 # let the probe record the first successes after the restart
cv_probe_stop

# =============================================================================================
# 5. verify
# =============================================================================================
if ((!failed)); then
  ql_info "step 5/5: verifying that the volumes were adopted"
  for v in "${OWN_VOLUMES[@]}"; do
    now=$(cv_volume_identity "$v") || now='unreadable'
    if [[ $now == "$(cv_state_get "VOLID_$v")" ]]; then
      ql_info "  $v adopted: $now"
    else
      ql_warn "  $v CHANGED: before='$(cv_state_get "VOLID_$v")' after='$now' - a new CreatedAt or inode means a fresh empty volume, not the data"
      failed=1
    fi
  done
  now=$(mount_src "$CONTAINER" /workspace)
  [[ $now == "$WS" ]] || { ql_warn "  the workspace moved: '$WS' -> '$now'"; failed=1; }
fi
changed_files=$(sed -n 's/^.*changed: //p' "$bk/install.log" | tail -n1)
restarted=$(grep -cE 'restarting |starting ' "$bk/install.log" || true)
down=$(cv_probe_downtime_ms "$probe")
cv_write_checksums "$bk"

if ((failed)); then
  cv_state_set STATUS failed
  if ((auto_rollback)); then
    ql_warn "the converge failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    ASSUME_YES=1 exec "$0" --rollback --yes
  fi
  ql_die "the converge failed; the new units are in place. Inspect, then run: $0 --rollback"
fi
cv_state_set STATUS converged
cv_state_set DOWNTIME_MS "$down"
cv_state_set CHANGED "${changed_files:-none}"
printf '\n' >&2
ql_info "converged."
ql_info "  files changed : ${changed_files:-none}"
ql_info "  units touched : $restarted start/restart line(s) in $bk/install.log"
if ((down < 0)); then
  ql_warn "  downtime      : the probe never saw a successful sample; check $probe by hand"
else
  ql_info "  downtime      : ${down} ms (probe every 100 ms against http://$HOST:$cur_port/healthz), wall clock $(((T1 - T0) / 1000)) s"
fi
ql_info "  backup        : $bk (sha256sum -c SHA256SUMS)"
ql_info "  rollback      : $0 --rollback"
ql_info "run $0 again: it must report 'files changed : none' and take no downtime. That is the property that says the host and the repo now agree."
[[ ! -f $LEGACY_ENV ]] \
  || ql_warn "$LEGACY_ENV still holds the login password in plain text; delete it once you have checked the login (the password now lives in the podman secret code-server-config)"
