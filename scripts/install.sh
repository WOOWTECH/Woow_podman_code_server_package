#!/usr/bin/env bash
# scripts/install.sh: install or update code-server as rootless Quadlet units (podman >= 4.9,
# systemd --user, linger). Idempotent: an unchanged re-run restarts nothing.
#
#   scripts/install.sh [--port N] [--bind ADDR] [--set KEY=VALUE]...
#                      [--with-tailscale [--ts-authkey-file PATH] | --without-tailscale]
#                      [--rotate-password] [--rebuild | --no-build] [--no-start] [--dry-run] [--yes]
#
#   --port N               publish port (CODE_SERVER_PORT, default 18443); saved in the env file
#   --bind ADDR            publish address (CODE_SERVER_BIND, default 127.0.0.1); saved there too
#   --set KEY=VALUE        set any key of config/woow-code-server.env.example in the env file
#   --with-tailscale       also install the tailscale sidecar (saves CODE_SERVER_TAILSCALE=yes)
#   --without-tailscale    remove the sidecar again (saves CODE_SERVER_TAILSCALE=no; keeps its volume)
#   --ts-authkey-file F    one-time tailscale auth key, read from file F into a podman secret
#   --rotate-password      generate a new login password (the old one stops working)
#   --rebuild              rebuild the image even when the VERSION tag already exists
#   --no-build             never build; the image tag must already exist
#   --no-start             install the files and daemon-reload only
#   --dry-run              render, validate and report what would change; change nothing
#   --yes                  never prompt (the git identity question is skipped)
#
# Per-host values live in ~/.config/woow-code-server/woow-code-server.env (0600), created from
# config/woow-code-server.env.example on the first run. The login password is a podman secret.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"

# ---- per-repo settings -----------------------------------------------------------------
APP=woow-code-server
ENV_FILE=$HOME/.config/$APP/$APP.env
EXAMPLE=$REPO/config/$APP.env.example
VARS=$REPO/quadlet/render-vars
PODMAN_MIN=4.9
VERSION=$(<"$REPO/VERSION")
IMAGE=localhost/woow-code-server:$VERSION
CONTAINER='code-server'
UNIT='code-server.service'
TS_CONTAINER=woow-tailscale-code-server
TS_UNIT=woow-tailscale-code-server.service
TS_VOLUME=woow-tailscale-code-server-state
PW_SECRET='code-server-config'
TS_SECRET=woow-code-server-ts-authkey
# the pre-Quadlet env file (PASSWORD=...): its password is adopted once, never printed
LEGACY_ENV=$HOME/.config/$APP/env
QDIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
# ------------------------------------------------------------------------------------------

usage() { sed -n '2,24p' "$0"; }
sets=() build=auto no_start=0 rotate=0 yes=0 ts_keyfile=''
while (($#)); do
  case $1 in
    --port) sets+=("CODE_SERVER_PORT=${2:?--port needs a value}"); shift ;;
    --bind) sets+=("CODE_SERVER_BIND=${2:?--bind needs a value}"); shift ;;
    --set) sets+=("${2:?--set needs KEY=VALUE}"); shift ;;
    --with-tailscale) sets+=("CODE_SERVER_TAILSCALE=yes") ;;
    --without-tailscale) sets+=("CODE_SERVER_TAILSCALE=no") ;;
    --ts-authkey-file) ts_keyfile=${2:?--ts-authkey-file needs a path}; shift ;;
    --rotate-password) rotate=1 ;;
    --rebuild) build=always ;;
    --no-build) build=never ;;
    --no-start) no_start=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    --yes) yes=1 ;;
    -h | --help) usage; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$APP
DRY=${QL_DRY_RUN:-0}

# gen_password: 24 characters [A-Za-z0-9] from /dev/urandom (no SIGPIPE-prone pipes)
gen_password() {
  local out='' chunk
  while ((${#out} < 24)); do
    chunk=$(head -c 96 /dev/urandom | base64 -w0) || return 1
    out+=${chunk//[!A-Za-z0-9]/}
  done
  printf '%s' "${out:0:24}"
}
# set_config_yaml <password>: CODE_SERVER_CONFIG_YAML = code-server's config file. The password
# is a double-quoted string (valid JSON and YAML), so adopted passwords with symbols survive.
set_config_yaml() {
  local s=$1
  [[ ! $s =~ [[:cntrl:]] ]] || ql_die "the password contains a control character; rotate it with --rotate-password"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  CODE_SERVER_CONFIG_YAML=$(printf 'auth: password\npassword: "%s"\ncert: false' "$s")
}
# legacy_password: PASSWORD= from the pre-Quadlet env file (prints nothing when absent)
legacy_password() {
  local line
  [[ -f $LEGACY_ENV ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == PASSWORD=?* ]]; then printf '%s' "${line#PASSWORD=}"; return 0; fi
  done <"$LEGACY_ENV"
}

# ---- 1. host preflight ---------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
command -v curl >/dev/null 2>&1 || ql_die "curl not found (sudo apt-get install curl)"
ql_enable_linger
ql_lock "$APP"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- 2. per-host settings (D2: rendered from the env file at install time) -----------------
ql_env_ensure "$EXAMPLE" "$ENV_FILE"
# Settings are staged in a private copy and saved only after every check below passed, so a
# rejected --port/--bind/--set never lands in the env file. A dry run never saves them.
envsrc=$WORK/$APP.env
if [[ -f $ENV_FILE ]]; then cp -- "$ENV_FILE" "$envsrc"; else cp -- "$EXAMPLE" "$envsrc"; QL_ENV_CREATED=1; fi
chmod 600 "$envsrc"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "created $ENV_FILE with defaults; edit it and re-run to change them"
for kv in "${sets[@]}"; do
  [[ $kv == *=* ]] || ql_die "--set wants KEY=VALUE, got '$kv'"
  grep -q "^${kv%%=*}=" "$EXAMPLE" || ql_die "--set: ${kv%%=*} is not a setting of ${EXAMPLE##*/}"
  QL_DRY_RUN=0 ql_env_set "$envsrc" "${kv%%=*}" "${kv#*=}"
done
ql_env_load "$envsrc"

IPV4='(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}'
# a host path for Volume=: absolute or %h/..., no ':' (the Volume= separator), blanks or quotes
HOSTPATH='(/|%h/)[^:[:space:]"'"'"'\\]*|%h'
BIND=$(ql_env_get CODE_SERVER_BIND)
PORT=$(ql_env_get CODE_SERVER_PORT)
TAILSCALE=$(ql_env_get CODE_SERVER_TAILSCALE)
ql_assert_match CODE_SERVER_BIND "$BIND" "$IPV4"
ql_assert_match CODE_SERVER_PORT "$PORT" '[1-9][0-9]{0,4}'
((PORT <= 65535)) || ql_die "CODE_SERVER_PORT=$PORT is not a TCP port"
for k in CODE_SERVER_WORKSPACE CODE_SERVER_SSH_DIR CODE_SERVER_GITCONFIG CODE_SERVER_HOST_BIN; do
  ql_assert_match "$k" "$(ql_env_get "$k")" "$HOSTPATH"
done
ql_assert_match PI_DEFAULT_PROVIDER "$(ql_env_get PI_DEFAULT_PROVIDER)" '[A-Za-z0-9._/-]+'
ql_assert_match PI_DEFAULT_MODEL "$(ql_env_get PI_DEFAULT_MODEL)" '[A-Za-z0-9._/:-]+'
ql_assert_match CODE_SERVER_TAILSCALE "$TAILSCALE" 'yes|no'
ql_assert_match CODE_SERVER_TS_HOSTNAME "$(ql_env_get CODE_SERVER_TS_HOSTNAME)" '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
[[ $BIND == 127.0.0.1 ]] || ql_warn "CODE_SERVER_BIND=$BIND: the password prompt is reachable over plain HTTP from that network, and the ACP chat webview needs a secure context (README \"Security\")"
if [[ -n $ts_keyfile ]]; then
  [[ $TAILSCALE == yes ]] || ql_die "--ts-authkey-file only makes sense with --with-tailscale (CODE_SERVER_TAILSCALE=yes)"
  [[ -f $ts_keyfile && -r $ts_keyfile && -s $ts_keyfile ]] || ql_die "--ts-authkey-file: cannot read a non-empty $ts_keyfile"
fi
if [[ $TAILSCALE == yes && -z $ts_keyfile ]] && ! podman secret exists "$TS_SECRET" && ! podman volume exists "$TS_VOLUME"; then
  ql_die "the tailscale sidecar needs a one-time auth key for its new node: add --ts-authkey-file PATH (a tagged, ephemeral, pre-approved key from the tailscale admin console)"
fi

# ---- 3. legacy guards ------------------------------------------------------------------------
ql_check_container_collision "$CONTAINER" "$UNIT"
[[ $TAILSCALE != yes ]] || ql_check_container_collision "$TS_CONTAINER" "$TS_UNIT"
# The port must be free, unless our running container is the one already publishing it.
published=$(sed -n 's/^PublishPort=//p' "$QDIR/$CONTAINER.container" 2>/dev/null || true)
if [[ $published != "$BIND:$PORT:8080" || $(systemctl --user is-active "$UNIT" 2>/dev/null || true) != active ]] \
  && command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  ql_die "port $PORT is already in use on this host (ss -ltnp 'sport = :$PORT'); pick another with --port"
fi

# ---- 4. render the units and validate them against the podman 4.9.3 generator -------------
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/systemd/*.service "$REPO"/systemd/*.timer "$WORK/src/"
units=("$UNIT" code-server-health.timer)
if [[ $TAILSCALE == yes ]]; then
  cp -p "$REPO"/quadlet/optional/* "$WORK/src/"
  units+=("$TS_UNIT")
fi
ql_render "$WORK/src" "$envsrc" "$VARS" "$WORK/out"
if [[ $TAILSCALE == yes ]]; then
  mkdir -p "$WORK/out/config"
  ql_render "$REPO/config/tailscale-serve.json.in" "$envsrc" "$VARS" - >"$WORK/out/config/tailscale-serve.json"
  chmod 644 "$WORK/out/config/tailscale-serve.json"
fi
ql_dryrun "$WORK/out" --verify --ref-dir "$QDIR" || ql_die "the rendered units failed the dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  [[ -f $f ]] || continue
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# Every check passed: only now do new --port/--bind/--set values reach the env file.
if [[ $DRY != 1 ]] && ! cmp -s -- "$envsrc" "$ENV_FILE"; then
  install -m 600 -- "$envsrc" "$ENV_FILE" || ql_die "cannot update $ENV_FILE"
  ql_info "saved the new settings in $ENV_FILE"
fi

# ---- 5. bind-mount sources on the host ---------------------------------------------------------
# podman fails with "statfs: no such file or directory" on a missing bind source.
WS=$(ql_expand_home "$(ql_env_get CODE_SERVER_WORKSPACE)")
SSHD=$(ql_expand_home "$(ql_env_get CODE_SERVER_SSH_DIR)")
GITCFG=$(ql_expand_home "$(ql_env_get CODE_SERVER_GITCONFIG)")
HOSTBIN=$(ql_expand_home "$(ql_env_get CODE_SERVER_HOST_BIN)")
if [[ $DRY == 1 ]]; then
  for p in "$WS" "$SSHD" "$GITCFG" "$HOSTBIN"; do [[ -e $p ]] || ql_info "[dry-run] would create $p"; done
else
  [[ -e $WS ]] || { mkdir -p -- "$WS" && ql_info "created the workspace $WS"; }
  [[ -e $SSHD ]] || { mkdir -p -- "$SSHD" && chmod 700 -- "$SSHD" && ql_info "created $SSHD (mode 0700)"; }
  [[ -e $GITCFG ]] || { mkdir -p -- "${GITCFG%/*}" && touch -- "$GITCFG" && ql_info "created an empty $GITCFG"; }
  [[ -e $HOSTBIN ]] || { mkdir -p -- "$HOSTBIN" && ql_info "created $HOSTBIN"; }
fi
if [[ $DRY != 1 ]]; then
  [[ -d $WS ]] || ql_die "CODE_SERVER_WORKSPACE=$WS is not a directory"
  [[ -d $SSHD ]] || ql_die "CODE_SERVER_SSH_DIR=$SSHD is not a directory"
  [[ -f $GITCFG ]] || ql_die "CODE_SERVER_GITCONFIG=$GITCFG is not a file"
  [[ -d $HOSTBIN ]] || ql_die "CODE_SERVER_HOST_BIN=$HOSTBIN is not a directory"
  # git identity: seed it rather than warn about it. Without one, `git commit` inside the
  # container fails with an opaque exit 128. GIT_USER_NAME / GIT_USER_EMAIL make it scriptable.
  if command -v git >/dev/null 2>&1 && ! git config --file "$GITCFG" user.email >/dev/null 2>&1; then
    git_name=${GIT_USER_NAME:-} git_email=${GIT_USER_EMAIL:-}
    if [[ (-z $git_name || -z $git_email) && -t 0 ]] && ((!yes)); then
      ql_info "$GITCFG has no git identity: 'git commit' inside the container would fail"
      [[ -n $git_name ]] || read -r -p '  git user.name  (blank to skip): ' git_name
      [[ -n $git_email ]] || read -r -p '  git user.email (blank to skip): ' git_email
    fi
    if [[ -n $git_name && -n $git_email ]]; then
      git config --file "$GITCFG" user.name "$git_name"
      git config --file "$GITCFG" user.email "$git_email"
      ql_info "seeded the git identity into $GITCFG ($git_name <$git_email>)"
    else
      ql_warn "$GITCFG has no git identity: 'git commit' inside the container will fail with \"Please tell me who you are\" (re-run with GIT_USER_NAME/GIT_USER_EMAIL, or git config --file $GITCFG user.email ...)"
    fi
  fi
  if ! compgen -G "$SSHD/id_*" >/dev/null && ! compgen -G "$SSHD/*.pem" >/dev/null; then
    ql_warn "$SSHD has no private key: 'git push' over SSH from inside the container will not authenticate"
  fi
  for f in "$HOSTBIN"/*; do
    if [[ -L $f && ! -e $f ]]; then ql_warn "$f is a dangling symlink: it will not work inside the container either"; fi
  done
fi

# ---- 6. image and secrets, before any unit changes -------------------------------------------
built=0
if [[ $build == always ]] || ! podman image exists "$IMAGE"; then
  [[ $build != never ]] || ql_die "image $IMAGE does not exist and --no-build was given"
  if [[ $DRY == 1 ]]; then
    ql_info "[dry-run] would build $IMAGE"
  else
    ql_info "building $IMAGE (podman build --format=docker; 10-15 minutes on a small host)"
    podman build --format=docker -t "$IMAGE" -f "$REPO/Containerfile" "$REPO" || ql_die "podman build failed; nothing was changed"
    built=1
  fi
fi
if podman image exists "$IMAGE"; then ql_pull_images "$WORK/out"; fi

pw_changed=0
# shellcheck disable=SC2034 # read by ql_secret_ensure through env:CODE_SERVER_CONFIG_YAML
CODE_SERVER_CONFIG_YAML=''
if ((rotate)); then
  set_config_yaml "$(gen_password)"
  ql_secret_ensure "$PW_SECRET" env:CODE_SERVER_CONFIG_YAML --replace
  pw_changed=1
elif ! podman secret exists "$PW_SECRET"; then
  pw=$(legacy_password)
  if [[ -n $pw ]]; then
    ql_info "adopting the password from $LEGACY_ENV (it is not printed)"
  else
    pw=$(gen_password)
  fi
  set_config_yaml "$pw"
  pw=''
  ql_secret_ensure "$PW_SECRET" env:CODE_SERVER_CONFIG_YAML
else
  # exists: kept as it is (the random: source is never used); recorded for --purge
  ql_secret_ensure "$PW_SECRET" random:24
fi
unset CODE_SERVER_CONFIG_YAML
ts_changed=0
if [[ $TAILSCALE == yes ]]; then
  QL_SECRET_CHANGED=0
  if [[ -n $ts_keyfile ]]; then
    ql_secret_ensure "$TS_SECRET" "file:$ts_keyfile" --update
  elif podman secret exists "$TS_SECRET"; then
    ql_secret_ensure "$TS_SECRET" random:32 # kept; recorded for --purge
  else
    # Adopting a node that is already logged in (its state volume exists): TS_AUTH_ONCE=true
    # ignores the key, but the unit needs the secret to exist.
    # shellcheck disable=SC2034 # read by ql_secret_ensure through env:
    TS_AUTHKEY_PLACEHOLDER=adopted-node-no-authkey
    ql_secret_ensure "$TS_SECRET" env:TS_AUTHKEY_PLACEHOLDER
  fi
  [[ ${QL_SECRET_CHANGED:-0} != 1 ]] || ts_changed=1
fi

# ---- 7. install changed files, then start / restart only what changed -----------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if [[ $DRY == 1 ]]; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
if ((built || pw_changed)); then ql_mark_changed "$APP" "$UNIT"; fi
# a single-file bind keeps the old inode of a replaced file: the sidecar must restart
if ((ts_changed)) || grep -qx 'config/tailscale-serve.json' <<<"$changed"; then ql_mark_changed "$APP" "$TS_UNIT"; fi
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start ${units[*]}"
  exit 0
fi
ql_apply_units "$APP" "${units[@]}"

# ---- 8. health and smoke -----------------------------------------------------------------------
HOST=$BIND
[[ $HOST != 0.0.0.0 ]] || HOST=127.0.0.1
ql_wait_container_healthy "$CONTAINER" 300 \
  || ql_die "$CONTAINER did not become healthy; see: journalctl --user -u $UNIT -n 100"
ql_wait_http "http://$HOST:$PORT/healthz" '200' 120 || ql_die "http://$HOST:$PORT/healthz did not answer 200"
"$REPO/tests/smoke.sh" --quick || ql_die "tests/smoke.sh --quick failed; see the output above"

ts_line=''
if [[ $TAILSCALE == yes ]]; then
  ts_line="  Tailnet      https://$(ql_env_get CODE_SERVER_TS_HOSTNAME).<your-tailnet>.ts.net/ (podman logs $TS_CONTAINER shows a login URL if the node is new)"
fi
cat >&2 <<EOF

code-server $VERSION is installed and healthy.

  URL          http://$HOST:$PORT/   (loopback: ssh -L $PORT:127.0.0.1:$PORT <this host>, then http://localhost:$PORT)
  Password     $REPO/scripts/show-password.sh
  First run    podman exec -it -u coder $CONTAINER sh -lc 'pi login'
${ts_line:+$ts_line
}  Logs         journalctl --user -u $UNIT -f
  Settings     $ENV_FILE (edit, then re-run $0)

EOF
if [[ -f $LEGACY_ENV ]]; then
  ql_warn "$LEGACY_ENV (and any env.bak-*) from the pre-Quadlet install still holds the password in plain text; delete it once you have checked the login"
fi
