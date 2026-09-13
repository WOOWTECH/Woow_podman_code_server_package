#!/usr/bin/env bash
# tests/smoke.sh: post-install checks of the running code-server deployment (podman). No LLM
# calls; the full run installs one npm package inside the container (smoke-toolchain.sh).
#
#   tests/smoke.sh            podman checks, then smoke-container, -acp, -pi-integration and
#                             -toolchain with PARITY_TARGET=podman
#   tests/smoke.sh --quick    podman checks + smoke-container.sh (what scripts/install.sh runs)
#   SMOKE_FORCE_FAIL=1 ...    fail on purpose (exercises scripts/upgrade.sh's rollback)
#
# Reads the bind address and port from ~/.config/woow-code-server/woow-code-server.env. The
# password comes from scripts/show-password.sh and is piped into curl: never printed, never in
# argv.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
export QL_LOG_PREFIX=smoke
APP=woow-code-server
C='code-server'
UNIT='code-server.service'
ENV_FILE=$HOME/.config/$APP/$APP.env

quick=0
case ${1:-} in
  '') ;;
  --quick) quick=1 ;;
  -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
  *) echo "smoke: unknown option $1" >&2; exit 2 ;;
esac

pass=0 fail=0
ok() { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
check() { # check <description> <command...>
  local d=$1
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

[[ -f $ENV_FILE ]] || { echo "smoke: $ENV_FILE not found (not installed?)" >&2; exit 1; }
ql_env_load "$ENV_FILE"
BIND=$(ql_env_get CODE_SERVER_BIND)
PORT=$(ql_env_get CODE_SERVER_PORT)
HOST=$BIND
[[ $HOST != 0.0.0.0 ]] || HOST=127.0.0.1
BASE=http://$HOST:$PORT

echo "== podman deployment at $BASE"
check "unit $UNIT is active" systemctl --user is-active --quiet "$UNIT"
check "code-server-health.timer is active" systemctl --user is-active --quiet code-server-health.timer
check "container health is healthy" test "$(podman inspect --format '{{.State.Health.Status}}' "$C" 2>/dev/null)" = healthy
check "GET /healthz -> 200" test "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/healthz" 2>/dev/null)" = 200

listeners=$(ss -ltnH "sport = :$PORT" 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')
check "port $PORT listens only on $BIND:$PORT (got: ${listeners:-none})" test "${listeners% }" = "$BIND:$PORT"

code=$("$REPO/scripts/show-password.sh" 2>/dev/null \
  | curl -s -o /dev/null -w '%{http_code}' -m 10 --data-urlencode password@- "$BASE/login" 2>/dev/null)
check "POST /login with the password from the podman secret -> 302" test "$code" = 302
check "the config secret is readable by coder inside the container" \
  podman exec -u coder "$C" test -r /run/secrets/code-server-config.yaml
check "no PASSWORD / HASHED_PASSWORD in the container's Config.Env" \
  test "$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$C" 2>/dev/null | grep -cE '^(HASHED_)?PASSWORD=')" = 0
check "no password= in the generated unit (systemctl --user cat)" \
  test "$(systemctl --user cat "$UNIT" 2>/dev/null | grep -ci 'password=')" = 0
if [[ $(ql_env_get CODE_SERVER_TAILSCALE no) == yes ]]; then
  check "tailscale sidecar woow-tailscale-code-server.service is active" \
    systemctl --user is-active --quiet woow-tailscale-code-server.service
fi
if [[ ${SMOKE_FORCE_FAIL:-0} == 1 ]]; then bad "SMOKE_FORCE_FAIL=1 (forced failure)"; fi

export PARITY_TARGET=podman CODE_SERVER_HOST=$HOST CODE_SERVER_PORT=$PORT
suites=(smoke-container.sh)
((quick)) || suites+=(smoke-acp.sh smoke-pi-integration.sh smoke-toolchain.sh)
for s in "${suites[@]}"; do
  echo
  echo "== tests/$s"
  check "tests/$s" "$REPO/tests/$s"
done

echo
echo "== $pass passed, $fail failed"
((fail == 0))
