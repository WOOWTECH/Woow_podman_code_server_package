#!/usr/bin/env bash
# Opt-in migration from the old shared pi-agent-data volume into this
# deployment's internal woow-code-server-pi-data volume. Never run
# automatically by install.sh.
#
# usage: migrate-pi-state.sh [--with-auth]
#
# Default (no flag): copies only what is safe — settings.json,
# home/.pi/pi-acp/ (the file authored only by code-server), and
# sessions/--workspace-- (code-server's own transcripts). Does NOT copy
# auth.json.
#
# --with-auth: additionally copies auth.json, the OAuth credential pi
# rewrites on every token refresh. Once two deployments hold a copy,
# whichever refreshes first can invalidate the other — if pi-web or
# open-design later shows an unexpected login prompt, this is why.
# Prefer running `pi login` in the new container instead.
set -euo pipefail

WITH_AUTH=0
[ "${1:-}" = "--with-auth" ] && WITH_AUTH=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }
podman volume exists pi-agent-data || { echo "pi-agent-data volume not found — nothing to migrate." >&2; exit 1; }
podman volume exists woow-code-server-pi-data || { echo "woow-code-server-pi-data volume not found — run install.sh first." >&2; exit 1; }

if [ "${WITH_AUTH}" -eq 1 ]; then
    warn "Copying auth.json too. The credential is an OAuth pair with a"
    warn "refresh token. Once two deployments hold copies, whichever"
    warn "refreshes first may invalidate the other. If pi-web or"
    warn "open-design later shows a login prompt, this is why. Prefer"
    warn "'pi login' in the new container instead."
    printf 'Continue anyway? [y/N] '
    read -r ans
    [ "${ans}" = "y" ] || [ "${ans}" = "Y" ] || { echo "Aborted."; exit 1; }
fi

say "Copying safe state: settings.json, home/.pi/pi-acp/, sessions/--workspace--/"
podman run --rm \
    -v pi-agent-data:/old:ro \
    -v woow-code-server-pi-data:/new \
    docker.io/library/busybox:1.37.0 sh -c '
        set -e
        [ -f /old/settings.json ] && cp -an /old/settings.json /new/settings.json || true
        if [ -d /old/home/.pi/pi-acp ]; then
            mkdir -p /new/home/.pi
            cp -an /old/home/.pi/pi-acp /new/home/.pi/pi-acp
        fi
        if [ -d "/old/sessions/--workspace--" ]; then
            mkdir -p /new/sessions
            cp -an "/old/sessions/--workspace--" "/new/sessions/--workspace--"
        fi
    '

if [ "${WITH_AUTH}" -eq 1 ]; then
    say "Copying auth.json"
    podman run --rm \
        -v pi-agent-data:/old:ro \
        -v woow-code-server-pi-data:/new \
        docker.io/library/busybox:1.37.0 sh -c '
            [ -f /old/auth.json ] && cp -an /old/auth.json /new/auth.json && chmod 600 /new/auth.json || true
        '
fi

say "Done. pi-agent-data was only read, never modified."
