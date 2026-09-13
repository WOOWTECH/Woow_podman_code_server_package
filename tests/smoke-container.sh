#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Smoke test: container/pod is up, /healthz is 200, PASSWORD gate is
# enforced (podman/k3s — HA delegates auth to its ingress session cookie,
# see PARITY_CONTRACT.md, so the password-gate checks below are skipped
# there, not failed).
# Zero cost, no LLM calls. Fail loud if any of the above regresses.
set -uo pipefail

# shellcheck source=lib/parity.sh
. "$(dirname "$0")/lib/parity.sh"

PASS_N=0; FAIL_N=0

# The password for the "correct password" check is streamed into curl's stdin, never put in
# argv or printed. podman: scripts/show-password.sh reads the podman secret. k3s: set
# CODE_SERVER_PASSWORD in the environment (there is no default); unset, the check is skipped.
password_stream() {
    if [ "${PARITY_TARGET}" = podman ]; then
        "$(dirname "$0")/../scripts/show-password.sh"
    else
        printf '%s' "${CODE_SERVER_PASSWORD}"
    fi
}

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS_N=$((PASS_N+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL_N=$((FAIL_N+1)); }
skip() { printf '  \033[90mSKIP\033[0m  %s\n' "$*"; }

echo "== Container/pod liveness (PARITY_TARGET=${PARITY_TARGET}) =="
STATUS="$(LIVENESS)"
case "${PARITY_TARGET}" in
podman) if [ "${STATUS}" = "healthy" ]; then ok "container health = healthy"; else bad "container health = ${STATUS:-unknown}"; fi ;;
ha)     if [ "${STATUS}" = "running" ]; then ok "add-on container status = running"; else bad "add-on container status = ${STATUS:-unknown}"; fi ;;
k3s)    if [ "${STATUS:-0}" -ge 1 ] 2>/dev/null; then ok "deployment readyReplicas = ${STATUS}"; else bad "deployment readyReplicas = ${STATUS:-0}"; fi ;;
esac

if [ -n "${BASE}" ]; then
    echo
    echo "== HTTP surface (${BASE}) =="
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${BASE}/healthz" 2>&1)"
    if [ "${CODE}" = "200" ]; then ok "/healthz -> 200"; else bad "/healthz -> ${CODE}"; fi
else
    skip "HTTP surface — no direct BASE for PARITY_TARGET=${PARITY_TARGET} (reached via ingress/tunnel; check manually)"
fi

if [ "${PARITY_TARGET}" = "ha" ]; then
    echo
    skip "password-gate checks — HA delegates auth to the ingress session cookie, code-server itself runs --auth none"
else
    echo
    echo "== Password gate =="
    # Root without login redirects to /login (302) or shows the login page (200).
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${BASE}/")"
    case "${CODE}" in
        200|302) ok "/ -> ${CODE} (login page)" ;;
        *)       bad "/ -> ${CODE}" ;;
    esac

    # code-server re-renders the login page (HTTP 200) with an error banner
    # rather than returning 401. So we assert on the body containing an
    # error string, which is the actually-testable behavior — a "silently
    # accept anything" regression would render the workspace HTML instead.
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
    if [ "${PARITY_TARGET}" != podman ] && [ -z "${CODE_SERVER_PASSWORD:-}" ]; then
        skip "correct password: set CODE_SERVER_PASSWORD for PARITY_TARGET=${PARITY_TARGET}"
    else
        CODE="$(password_stream | curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
            --data-urlencode "password@-" "${BASE}/login")"
        case "${CODE}" in
            302|200) ok "correct password -> ${CODE}" ;;
            *)       bad "correct password -> ${CODE}" ;;
        esac
    fi
fi

echo
printf '  %d passed, %d failed\n\n' "${PASS_N}" "${FAIL_N}"
[ "${FAIL_N}" -eq 0 ] || exit 1
