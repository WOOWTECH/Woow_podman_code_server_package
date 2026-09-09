#!/usr/bin/env bash
# Remove the code-server Quadlet unit + health timer. Data volumes KEPT by
# default: woow-code-server-pi-data and woow-code-server-ide hold this
# deployment's own pi login/sessions and IDE settings — this repo no
# longer uses any sibling-owned volume at all, so there is nothing to
# leave alone on someone else's behalf any more. Pass --purge to delete
# them too, after a confirmation prompt.
set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
USER_UNIT_DIR="${HOME}/.config/systemd/user"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "Stopping services"
systemctl --user disable --now code-server-health.timer 2>/dev/null || true
systemctl --user stop code-server.service 2>/dev/null || true

say "Removing units"
rm -f "${QUADLET_DIR}/code-server.container" \
      "${QUADLET_DIR}/woow-code-server-pi.volume" \
      "${QUADLET_DIR}/woow-code-server-ide.volume"
rm -f "${USER_UNIT_DIR}/code-server-health.service" \
      "${USER_UNIT_DIR}/code-server-health.timer"
systemctl --user daemon-reload
podman rm -f code-server 2>/dev/null || true

if [ "${PURGE}" -eq 1 ]; then
    printf 'Delete woow-code-server-pi-data and woow-code-server-ide volumes? This removes the pi login and all IDE settings. [y/N] '
    read -r ans
    if [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]; then
        podman volume rm woow-code-server-pi-data woow-code-server-ide 2>/dev/null || true
        say "Volumes deleted."
    else
        say "Skipped — volumes kept."
    fi
else
    say "Done. woow-code-server-pi-data and woow-code-server-ide were NOT deleted."
    say "  podman volume rm woow-code-server-pi-data woow-code-server-ide   # to delete them"
    say "  (pi-agent-data, if it exists on this host, was never used by this repo and is untouched.)"
fi
