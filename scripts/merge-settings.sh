#!/bin/sh
# Run as coder inside code-server during install/upgrade. Preserve user settings and
# custom ACP agents while bringing the pinned Pi/Claude agents and trust settings up
# to the current image defaults. A named User volume otherwise hides new image seeds.
set -eu

seed=${SEED_PATH:-/etc/skel/.local/share/code-server/User/settings.json}
settings=${SETTINGS_PATH:-/home/coder/.local/share/code-server/User/settings.json}
test -f "$seed"
mkdir -p "$(dirname "$settings")"
if ! test -f "$settings"; then
    cp "$seed" "$settings"
    chmod 600 "$settings"
    printf 'changed\n'
    exit 0
fi

tmp=$(mktemp "${settings}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq -n --slurpfile defaults "$seed" --slurpfile current "$settings" '
  $defaults[0] as $d | $current[0] as $u |
  $u
  | .["acp.agents"] = (($u["acp.agents"] // {}) + $d["acp.agents"])
  | .["security.workspace.trust.enabled"] = $d["security.workspace.trust.enabled"]
  | .["security.workspace.trust.startupPrompt"] = $d["security.workspace.trust.startupPrompt"]
  | .["security.workspace.trust.banner"] = $d["security.workspace.trust.banner"]
  | .["security.workspace.trust.emptyWindow"] = $d["security.workspace.trust.emptyWindow"]
  | .["extensions.autoUpdate"] = $d["extensions.autoUpdate"]
' > "$tmp"
chmod 600 "$tmp"
if jq -e --slurpfile desired "$tmp" '. == $desired[0]' "$settings" >/dev/null; then
    printf 'unchanged\n'
else
    mv -f "$tmp" "$settings"
    printf 'changed\n'
fi
