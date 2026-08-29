#!/usr/bin/env bash
# Install the code-server Quadlet unit + systemd health timer on a rootless
# podman host. Builds the image locally with podman build.
#
#   ./scripts/install.sh                       # build + install + start
#   OD_SKIP_BUILD=1 ./scripts/install.sh       # keep the current image
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${HOME}/.config/containers/systemd"
USER_UNIT_DIR="${HOME}/.config/systemd/user"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run this as root. Rootless podman is the design."
command -v podman >/dev/null || die "podman not found"

say "Checking Podman + Quadlet"
podman --version
GEN=""
for p in /usr/lib/systemd/user-generators/podman-user-generator \
         /usr/libexec/podman/quadlet \
         /usr/lib/systemd/system-generators/podman-system-generator; do
    [ -x "$p" ] && { GEN="$p"; break; }
done
[ -n "${GEN}" ] || die "Quadlet generator not found. Podman >= 4.4 required."
say "  Quadlet generator: ${GEN}"

say "Enabling lingering so the container survives logout"
loginctl enable-linger "$(id -un)" || warn "enable-linger failed"

# Pre-flight: the external pi-agent-data volume from the sibling package.
# Create empty if missing so the container starts standalone; if the sibling
# is installed it already owns the volume and we do nothing.
if ! podman volume exists pi-agent-data 2>/dev/null; then
    warn "External volume pi-agent-data missing — creating an empty one."
    warn "Install Woow_podman_pi_agent_package too if you want a shared"
    warn "pi state (sessions, models, skills) with pi-web."
    podman volume create pi-agent-data >/dev/null
fi

if [ "${OD_SKIP_BUILD:-0}" != "1" ]; then
    say "Building localhost/woow-code-server:latest from Containerfile"
    podman build --format=docker -t localhost/woow-code-server:latest \
        -f "${REPO_DIR}/Containerfile" "${REPO_DIR}"
fi

say "Installing units"
mkdir -p "${QUADLET_DIR}" "${USER_UNIT_DIR}"
install -m 0644 "${REPO_DIR}/quadlet/code-server.container" \
        "${QUADLET_DIR}/code-server.container"
for unit in code-server-health.service code-server-health.timer; do
    install -m 0644 "${REPO_DIR}/systemd/${unit}" "${USER_UNIT_DIR}/${unit}"
done

say "Reloading systemd + starting"
systemctl --user daemon-reload
systemctl --user enable --now podman.socket
systemctl --user start code-server.service
systemctl --user enable --now code-server-health.timer

say "Waiting for code-server to answer /healthz"
for i in $(seq 1 30); do
    if curl -sSf -o /dev/null http://127.0.0.1:8443/healthz 2>/dev/null; then
        say "  ready after ~$((i*2))s"
        break
    fi
    [ "$i" -eq 30 ] && warn "still not ready after 60s — check: podman logs code-server"
    sleep 2
done

cat <<EOF

$(say "Done")

  UI          http://$(hostname -I | awk '{print $1}'):8443   password: (see quadlet)
  Logs        podman logs -f code-server
  Shell       podman exec -it code-server bash
  Stop        systemctl --user stop code-server
  Status      podman ps --format '{{.Names}}\t{{.Status}}'
              systemctl --user status code-server-health.timer

  In the IDE: bottom-left status bar → ACP: pi ACP adapter (should be green)
  Right-side chat panel → send a message → uses pi with your existing
  provider from /data/pi-agent/models.json (shared with the pi-web addon).

EOF

warn "PASSWORD=woowtech is baked into the quadlet. Change it in"
warn "~/.config/containers/systemd/code-server.container then restart."
