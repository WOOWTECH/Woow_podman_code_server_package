#!/usr/bin/env bash
# Smoke test: container is up, /healthz is 200, PASSWORD gate is enforced.
# Zero cost, no LLM calls. Fail loud if any of the above regresses.
set -uo pipefail

HOST="${CODE_SERVER_HOST:-127.0.0.1}"
PORT="${CODE_SERVER_PORT:-8443}"
PASS="${CODE_SERVER_PASSWORD:-woowtech}"
BASE="http://${HOST}:${PORT}"
PASS_N=0; FAIL_N=0

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS_N=$((PASS_N+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL_N=$((FAIL_N+1)); }

echo "== Container liveness =="
if podman inspect code-server >/dev/null 2>&1; then
    STATUS="$(podman inspect --format '{{.State.Health.Status}}' code-server 2>/dev/null || echo unknown)"
    [ "${STATUS}" = "healthy" ] && ok "container health = healthy" || bad "container health = ${STATUS}"
else
    bad "code-server container not found"
fi

echo
echo "== HTTP surface =="
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${BASE}/healthz" 2>&1)"
[ "${CODE}" = "200" ] && ok "/healthz -> 200" || bad "/healthz -> ${CODE}"

# Root without login redirects to /login (302) or shows the login page (200).
# Anything else is a regression — code-server's built-in auth should be on.
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${BASE}/")"
case "${CODE}" in
    200|302) ok "/ -> ${CODE} (login page)" ;;
    *)       bad "/ -> ${CODE}" ;;
esac

# code-server re-renders the login page (HTTP 200) with an error banner
# rather than returning 401. So we assert on the body containing an error
# string, which is the actually-testable behavior — a "silently accept
# anything" regression would render the workspace HTML instead.
BODY="$(curl -sS --max-time 5 -X POST \
    --data-urlencode "password=deliberately-wrong-$$" \
    "${BASE}/login")"
if echo "${BODY}" | grep -qiE 'incorrect password|missing password|invalid password'; then
    ok "wrong password rejected (login page re-rendered with error)"
else
    bad "wrong password NOT rejected — body did not carry an error banner"
    echo "${BODY}" | head -c 300 | sed 's/^/       /'
fi

# Right password redirects (302) to the workbench.
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    --data-urlencode "password=${PASS}" \
    "${BASE}/login")"
case "${CODE}" in
    302|200) ok "correct password -> ${CODE}" ;;
    *)       bad "correct password -> ${CODE}" ;;
esac

echo
printf '  %d passed, %d failed\n\n' "${PASS_N}" "${FAIL_N}"
[ "${FAIL_N}" -eq 0 ] || exit 1
