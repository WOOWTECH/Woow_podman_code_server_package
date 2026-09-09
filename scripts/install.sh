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

# pi state is an internal named volume now (woow-code-server-pi-data),
# declared by quadlet/woow-code-server-pi.volume and installed below —
# systemd creates it the first time the unit starts, no pre-flight needed.

# Pre-flight: bind-mount sources on the host. Podman errors out with
# `statfs: no such file or directory` when a bind mount source is
# missing (rather than silently creating a directory in its place, which
# is the default for older podman versions — either failure mode is
# worse than pre-creating the files here). Only touch what could
# plausibly be absent; ~/Desktop existence is on the operator.
[ -e "${HOME}/.gitconfig" ] || {
    say "Creating empty ~/.gitconfig (bind mount source)"
    touch "${HOME}/.gitconfig"
}
[ -e "${HOME}/.ssh" ] || {
    say "Creating ~/.ssh (bind mount source)"
    mkdir -m 0700 "${HOME}/.ssh"
}
[ -e "${HOME}/.local/bin" ] || {
    say "Creating ~/.local/bin (bind mount source)"
    mkdir -p "${HOME}/.local/bin"
}
[ -e "${HOME}/Desktop" ] || die "\${HOME}/Desktop is missing — the workspace mount points at it. Create it or edit quadlet/code-server.container to point elsewhere."

# Honest warnings about the four host mounts kept from the original design.
# These are non-fatal: the container starts fine either way, but git
# operations inside it will not work until the operator fixes them.
[ -s "${HOME}/.gitconfig" ] || warn "~/.gitconfig is empty — 'git commit' inside the container will fail with \"Please tell me who you are\" until you run 'git config --global user.name/user.email' on the host."
if [ -d "${HOME}/.ssh" ] && ! ls "${HOME}/.ssh"/id_* >/dev/null 2>&1 && ! ls "${HOME}/.ssh"/*.pem >/dev/null 2>&1; then
    warn "~/.ssh has no private key — 'git push' over SSH from inside the container will not authenticate until you add one."
fi
for f in "${HOME}/.local/bin"/*; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && [ ! -e "$f" ] && warn "~/.local/bin/$(basename "$f") is a dangling symlink — it will not work inside the container either."
done

EnvFile="${HOME}/.config/woow-code-server/env"
if [ ! -e "${EnvFile}" ]; then
    say "Creating ${EnvFile} (mode 600) — PASSWORD/SUDO_PASSWORD live here, not in git"
    mkdir -p "$(dirname "${EnvFile}")"
    GenPassword="${PASSWORD:-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"
    umask 077
    cat > "${EnvFile}" <<ENVEOF
PASSWORD=${GenPassword}
SUDO_PASSWORD=${GenPassword}
PI_DEFAULT_PROVIDER=openai-codex
PI_DEFAULT_MODEL=gpt-5.6-sol
ENVEOF
    chmod 600 "${EnvFile}"
    say "  Generated PASSWORD — see the closing banner below, or: cat ${EnvFile}"
else
    say "Reusing existing ${EnvFile}"
fi

if [ "${OD_SKIP_BUILD:-0}" != "1" ]; then
    say "Building localhost/woow-code-server:latest from Containerfile"
    podman build --format=docker -t localhost/woow-code-server:latest \
        -f "${REPO_DIR}/Containerfile" "${REPO_DIR}"
fi

say "Installing units"
mkdir -p "${QUADLET_DIR}" "${USER_UNIT_DIR}"
for f in code-server.container woow-code-server-pi.volume woow-code-server-ide.volume; do
    install -m 0644 "${REPO_DIR}/quadlet/${f}" "${QUADLET_DIR}/${f}"
done
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

  UI          http://$(hostname -I | awk '{print $1}'):8443   password: $(awk -F= '/^PASSWORD=/{print $2}' "${EnvFile}")
  Logs        podman logs -f code-server
  Shell       podman exec -it code-server bash
  Stop        systemctl --user stop code-server
  Status      podman ps --format '{{.Names}}\t{{.Status}}'
              systemctl --user status code-server-health.timer

  First run — pi has no credentials yet in this deployment's internal
  store (it is no longer shared with any sibling package). Sign in once:

    podman exec -it -u coder code-server sh -lc 'pi login'

  Then in the IDE: bottom-left status bar → ACP: pi ACP adapter (should
  be green); the right-side chat panel now uses that login.

  NOTE: the ACP chat webview only renders from a browser-trusted secure
  context. Over this LAN's plain HTTP it will stay blank in most browsers
  — use http://localhost:8443 (via an SSH port-forward to this host) or
  front the container with a trusted-cert reverse proxy. See
  README.md#security.

EOF
