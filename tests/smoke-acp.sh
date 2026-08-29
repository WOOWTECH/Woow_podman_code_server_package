#!/usr/bin/env bash
# Smoke test: the ACP Client extension is installed and the coder-user
# settings.json wires it to the pi-code wrapper we ship. This is what
# makes the right-side chat panel light up as "pi ACP adapter" on first
# login, without the user editing anything.
set -uo pipefail

EXPECTED_EXT="formulahendry.acp-client"
PASS_N=0; FAIL_N=0

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS_N=$((PASS_N+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL_N=$((FAIL_N+1)); }

CX() { podman exec -u coder code-server "$@"; }

echo "== ACP Client extension =="
EXT_LIST="$(CX code-server --list-extensions 2>/dev/null || true)"
if echo "${EXT_LIST}" | grep -qi "^${EXPECTED_EXT}$"; then
    ok "extension installed: ${EXPECTED_EXT}"
else
    bad "extension NOT installed. Got:"
    echo "${EXT_LIST}" | sed 's/^/       /'
fi

echo
echo "== settings.json wiring =="
SETTINGS_PATH=/home/coder/.local/share/code-server/User/settings.json
if CX test -f "${SETTINGS_PATH}"; then
    ok "settings.json exists at ${SETTINGS_PATH}"
    if CX cat "${SETTINGS_PATH}" | jq -e '.["acp.agents"].pi.command == "pi-code"' >/dev/null 2>&1; then
        ok "acp.agents.pi.command = pi-code"
    else
        bad "acp.agents.pi.command NOT wired to pi-code"
        CX cat "${SETTINGS_PATH}" | sed 's/^/       /'
    fi
else
    bad "settings.json missing at ${SETTINGS_PATH}"
fi

echo
printf '  %d passed, %d failed\n\n' "${PASS_N}" "${FAIL_N}"
[ "${FAIL_N}" -eq 0 ] || exit 1
