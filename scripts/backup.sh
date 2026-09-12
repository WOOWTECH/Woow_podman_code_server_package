#!/usr/bin/env bash
# scripts/backup.sh: back up the code-server deployment into a new directory.
#
#   scripts/backup.sh [--dest DIR] [--include-secrets] [--stop]
#
#   --dest DIR          parent directory (default ~/backups/woow-code-server); a <timestamp>/
#                       subdirectory is created in it and printed on stdout
#   --include-secrets   also write the podman secrets (the login password, the tailscale auth
#                       key) into <dir>/secrets/ (0600 files in a 0700 directory)
#   --stop              stop code-server during the export, for a consistent pi state
#
# Contents: a podman volume export of woow-code-server-pi-data (pi login, sessions, skills),
# woow-code-server-ide (IDE settings) and, when it exists, woow-tailscale-code-server-state,
# each with a .sha256, plus a copy of the env file. Restore with scripts/restore.sh <dir>.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
APP=woow-code-server
ENV_FILE=$HOME/.config/$APP/$APP.env
VOLUMES=(woow-code-server-pi-data woow-code-server-ide woow-tailscale-code-server-state)
SECRETS=(code-server-config woow-code-server-ts-authkey)
UNIT='code-server.service'

dest=$HOME/backups/$APP include_secrets=0 stop=0
while (($#)); do
  case $1 in
    --dest) dest=${2:?--dest needs a directory}; shift ;;
    --include-secrets) include_secrets=1 ;;
    --stop) stop=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$APP
ql_require_rootless

found=()
for v in "${VOLUMES[@]}"; do
  if podman volume exists "$v"; then found+=("$v"); fi
done
((${#found[@]})) || ql_die "none of the volumes ${VOLUMES[*]} exists; nothing to back up"

base=$dest/$(date +%Y%m%d-%H%M%S) out=$dest/$(date +%Y%m%d-%H%M%S) n=2
while [[ -e $out ]]; do out=$base-$n; n=$((n + 1)); done
(umask 077 && mkdir -p -- "$out") || ql_die "cannot create $out"
chmod 700 "$out"

started=0
if ((stop)) && systemctl --user is-active --quiet "$UNIT"; then
  ql_info "stopping $UNIT for a consistent export"
  systemctl --user stop "$UNIT"
  started=1
fi
for v in "${found[@]}"; do ql_backup_volume "$v" "$out" >/dev/null; done
((started == 0)) || { ql_info "starting $UNIT again"; systemctl --user start "$UNIT"; }

if [[ -f $ENV_FILE ]]; then install -m 600 -- "$ENV_FILE" "$out/${ENV_FILE##*/}"; fi
if ((include_secrets)); then
  (umask 077 && mkdir -p -- "$out/secrets")
  for s in "${SECRETS[@]}"; do
    if podman secret exists "$s"; then
      # command substitution strips the trailing newline the template adds, so restoring the
      # file reproduces the secret byte for byte
      (umask 077 && printf '%s' "$(podman secret inspect --showsecret --format '{{.SecretData}}' "$s")" >"$out/secrets/$s")
    fi
  done
  ql_warn "$out/secrets/ holds the login password in plain text (0600): keep the backup private"
fi
ql_info "backup complete: $out"
printf '%s\n' "$out"
