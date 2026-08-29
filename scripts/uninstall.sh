#!/usr/bin/env bash
# Remove the code-server Quadlet unit + health timer. Data volume KEPT by
# default: `pi-agent-data` is shared with the sibling pi-agent-package and
# never touched here; code-server's own /home/coder state lives inside the
# container (tmpfs unless explicitly mounted) so uninstalling here loses
# nothing users typed against the IDE anyway.
set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
USER_UNIT_DIR="${HOME}/.config/systemd/user"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "Stopping services"
systemctl --user disable --now code-server-health.timer 2>/dev/null || true
systemctl --user stop code-server.service 2>/dev/null || true

say "Removing units"
rm -f "${QUADLET_DIR}/code-server.container"
rm -f "${USER_UNIT_DIR}/code-server-health.service" \
      "${USER_UNIT_DIR}/code-server-health.timer"
systemctl --user daemon-reload
podman rm -f code-server 2>/dev/null || true

say "Done. pi-agent-data volume was NOT touched (owned by sibling package)."
