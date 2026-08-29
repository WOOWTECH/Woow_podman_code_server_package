#!/usr/bin/env bash
# Smoke test: pi CLI is on PATH, right version, HOME-scoped wrapper works,
# and the shared /data/pi-agent volume is mounted with the sibling package's
# state visible from inside the container.
set -uo pipefail

EXPECTED_PI_VERSION="${EXPECTED_PI_VERSION:-0.83.0}"
PASS_N=0; FAIL_N=0

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS_N=$((PASS_N+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL_N=$((FAIL_N+1)); }
skip(){ printf '  \033[90mSKIP\033[0m  %s\n' "$*"; }

CX() { podman exec code-server "$@"; }

echo "== pi CLI =="
if V="$(CX pi --version 2>&1)"; then
    [ "${V}" = "${EXPECTED_PI_VERSION}" ] \
        && ok "pi --version = ${V}" \
        || bad "pi --version = ${V} (expected ${EXPECTED_PI_VERSION})"
else
    bad "pi not on PATH inside container"
fi

if CX which pi-acp >/dev/null 2>&1; then
    ok "pi-acp on PATH"
else
    bad "pi-acp not on PATH"
fi

if CX test -x /usr/local/bin/pi-code; then
    ok "pi-code wrapper installed + executable"
else
    bad "pi-code wrapper missing"
fi

echo
echo "== Shared volume =="
if CX test -d /data/pi-agent; then
    ok "/data/pi-agent mounted"
    # A live sibling deployment writes these; presence proves the volume
    # is really the one pi-web/OD share, not a fresh empty create.
    for f in models-store.json home sessions; do
        if CX test -e "/data/pi-agent/${f}"; then
            ok "  sees sibling artefact /data/pi-agent/${f}"
        else
            skip "  /data/pi-agent/${f} absent (sibling package not deployed here?)"
        fi
    done
else
    bad "/data/pi-agent NOT mounted — pi state will be lost on container restart"
fi

echo
echo "== pi-code HOME re-scoping =="
# Run pi-code with a no-op arg and check it exports the right HOME.
# We use `--help` so no session/auth is required.
if OUT="$(CX env -i PATH=/usr/local/bin:/usr/bin:/bin PI_AGENT_DATA_DIR=/data/pi-agent \
             sh -c 'HOME=/nope /usr/local/bin/pi-code --help >/dev/null 2>&1 || true; \
                    # spawn a probe that logs whatever HOME pi-code exported
                    HOME=/nope /usr/local/bin/pi-code </dev/null >/dev/null 2>&1 & \
                    sleep 0.2; kill -0 $! 2>/dev/null && kill $! 2>/dev/null; \
                    # simpler: just source the export lines
                    grep -E "^export HOME" /usr/local/bin/pi-code' 2>&1)"; then
    if echo "${OUT}" | grep -q 'PI_AGENT_DATA_DIR}/home'; then
        ok "pi-code exports HOME=\${PI_AGENT_DATA_DIR}/home"
    else
        bad "pi-code HOME export missing or wrong: ${OUT}"
    fi
else
    bad "could not inspect pi-code wrapper: ${OUT}"
fi

echo
printf '  %d passed, %d failed\n\n' "${PASS_N}" "${FAIL_N}"
[ "${FAIL_N}" -eq 0 ] || exit 1
