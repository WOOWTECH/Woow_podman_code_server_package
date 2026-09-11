# shellcheck shell=bash
# tests/dryrun.local.sh: repo-specific checks, sourced at the end of tests/dryrun.sh (which
# defines REPO, WORK, APP, VARS, failures and run_variant). CI runs it through tests/dryrun.sh.
# shellcheck disable=SC2154 # REPO, WORK, VARS and failures come from tests/dryrun.sh

local_fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# One version in three places: VERSION (<code-server version>-<package revision>), the unit's
# Image= tag and the Containerfile ARG the image is built from.
ver=$(<"$REPO/VERSION")
img_tag=$(sed -n 's|^Image=localhost/woow-code-server:||p' "$REPO/quadlet/code-server.container")
cf_ver=$(sed -n 's/^ARG CODE_SERVER_VERSION=//p' "$REPO/Containerfile" | tail -n1)
if [[ $ver == "$img_tag" && ${ver%-*} == "$cf_ver" ]]; then
  echo "ok   versions agree (VERSION=$ver, code-server $cf_ver)"
else
  local_fail "versions disagree: VERSION=$ver Image= tag=$img_tag Containerfile ARG=$cf_ver"
fi

# Loopback by default: the password prompt must not be published to a network out of the box.
if grep -qx 'CODE_SERVER_BIND=127.0.0.1' "$REPO/config/$APP.env.example"; then
  echo "ok   example binds 127.0.0.1"
else
  local_fail "config/$APP.env.example must default to CODE_SERVER_BIND=127.0.0.1"
fi

# The optional sidecar's serve config renders to valid JSON, points at the configured port and
# keeps ${TS_CERT_DOMAIN} for tailscale itself to expand.
serve=$WORK/tailscale-serve.json
if (ql_render "$REPO/config/tailscale-serve.json.in" "$REPO/config/$APP.env.example" "$VARS" - >"$serve"); then
  port=$(sed -n 's/^CODE_SERVER_PORT=//p' "$REPO/config/$APP.env.example")
  # shellcheck disable=SC2016 # ${TS_CERT_DOMAIN} is a literal tailscale placeholder, not a shell variable
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); k="${TS_CERT_DOMAIN}:443"; assert d["Web"][k]["Handlers"]["/"]["Proxy"] == "http://127.0.0.1:" + sys.argv[2], d' "$serve" "$port"; then
    echo "ok   tailscale-serve.json renders to valid JSON (proxy -> 127.0.0.1:$port)"
  else
    local_fail "tailscale-serve.json.in does not render the expected JSON"
  fi
else
  local_fail "tailscale-serve.json.in failed to render"
fi
