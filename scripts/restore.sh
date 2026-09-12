#!/usr/bin/env bash
# scripts/restore.sh: restore a scripts/backup.sh directory into the installed units.
#
#   scripts/restore.sh <backup_dir> [--with-secrets] [--yes]
#
#   --with-secrets   also replace the podman secrets from <backup_dir>/secrets/ (the login
#                    password goes back to the one in the backup)
#   --yes            do not ask for confirmation
#
# Stops code-server, REPLACES every volume the backup contains (the current pi login, sessions
# and IDE settings are overwritten), starts it again and runs tests/smoke.sh --quick. Install
# the units first (scripts/install.sh).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
APP=woow-code-server
UNIT='code-server.service'
TS_UNIT=woow-tailscale-code-server.service
CONTAINER='code-server'
# volume -> the Quadlet unit that (re)creates it with its labels
declare -A VOLUME_UNIT=(
  [woow-code-server-pi-data]=woow-code-server-pi-volume.service
  [woow-code-server-ide]=woow-code-server-ide-volume.service
  [woow-tailscale-code-server-state]=woow-tailscale-code-server-volume.service
)

dir='' with_secrets=0 yes=0
while (($#)); do
  case $1 in
    --with-secrets) with_secrets=1 ;;
    --yes) yes=1 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $dir ]] || ql_die "one backup directory only"; dir=$1 ;;
  esac
  shift
done
[[ -n $dir && -d $dir ]] || ql_die "usage: scripts/restore.sh <backup_dir> [--with-secrets] [--yes]"
export QL_APP=$APP
ql_require_rootless
ql_require_user_systemd
ql_lock "$APP"
[[ $(systemctl --user show -p LoadState --value "$UNIT" 2>/dev/null) == loaded ]] \
  || ql_die "$UNIT is not installed; run scripts/install.sh first"

shopt -s nullglob
declare -A TARS=()
for v in "${!VOLUME_UNIT[@]}"; do
  found=("$dir/$v"-*.tar)
  ((${#found[@]} <= 1)) || ql_die "more than one $v-*.tar in $dir"
  ((${#found[@]} == 0)) || TARS[$v]=${found[0]}
done
((${#TARS[@]})) || ql_die "no volume export (*.tar) found in $dir"
for v in "${!TARS[@]}"; do
  t=${TARS[$v]}
  if [[ -f $t.sha256 ]]; then
    (cd -- "$dir" && sha256sum -c --quiet -- "${t##*/}.sha256") || ql_die "checksum mismatch for $t"
  else
    ql_warn "no ${t##*/}.sha256; restoring that volume without a checksum"
  fi
done
((with_secrets == 0)) || [[ -d $dir/secrets ]] || ql_die "--with-secrets: $dir/secrets/ not found"

if ((!yes)); then
  [[ -t 0 ]] || ql_die "restore replaces the volumes ${!TARS[*]}; add --yes to confirm non-interactively"
  read -r -p "Replace the volumes ${!TARS[*]} from ${dir}? Type '$APP' to continue: " answer
  [[ $answer == "$APP" ]] || ql_die "aborted; nothing was changed"
fi

ql_info "stopping $UNIT"
systemctl --user stop "$UNIT"
systemctl --user stop "$TS_UNIT" 2>/dev/null || true
for v in "${!TARS[@]}"; do
  unit=${VOLUME_UNIT[$v]}
  if podman volume exists "$v"; then
    podman volume rm "$v" >/dev/null || ql_die "cannot remove volume $v (still in use?)"
  fi
  if [[ $(systemctl --user show -p LoadState --value "$unit" 2>/dev/null) == loaded ]]; then
    systemctl --user restart "$unit" || ql_die "cannot recreate $v through $unit"
  else
    podman volume create "$v" >/dev/null || ql_die "cannot create $v"
  fi
  podman volume import "$v" "${TARS[$v]}" || ql_die "podman volume import failed for $v; it is empty now, re-run restore"
  ql_info "restored $v from ${TARS[$v]##*/}"
done

if ((with_secrets)); then
  for f in "$dir"/secrets/*; do
    [[ -f $f ]] || continue
    ql_secret_ensure "${f##*/}" "file:$f" --update
  done
fi

systemctl --user start "$UNIT"
ql_wait_container_healthy "$CONTAINER" 300 || ql_die "$CONTAINER did not become healthy after the restore"
"$REPO/tests/smoke.sh" --quick || ql_die "tests/smoke.sh --quick failed after the restore"
ql_info "restore complete"
