#!/usr/bin/env bash
# A persistent User volume must receive current required settings without losing
# the user's unrelated settings or additional ACP agents.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export SEED_PATH=$REPO/rootfs/etc/skel/.local/share/code-server/User/settings.json
export SETTINGS_PATH=$scratch/User/settings.json

[[ $(sh "$REPO/scripts/merge-settings.sh") == changed ]]
jq -e '.["acp.agents"].pi.command == "pi-code" and .["acp.agents"].claude.command == "claude-agent-acp" and .["acp.agents"].codex.command == "codex-code"' "$SETTINGS_PATH" >/dev/null

updated=$scratch/updated.json
jq '.["acp.agents"].custom = {"command":"my-agent"} |
    .["acp.agents"].pi.command = "stale-pi" |
    .["acp.agents"].codex.command = "stale-codex" |
    .["extensions.autoUpdate"] = "on" |
    .["my.setting"] = 42' "$SETTINGS_PATH" > "$updated"
mv "$updated" "$SETTINGS_PATH"

[[ $(sh "$REPO/scripts/merge-settings.sh") == changed ]]
jq -e '.["acp.agents"].pi.command == "pi-code" and
       .["acp.agents"].claude.command == "claude-agent-acp" and
       .["acp.agents"].codex.command == "codex-code" and
       .["acp.agents"].custom.command == "my-agent" and
       .["extensions.autoUpdate"] == "off" and
       .["security.workspace.trust.enabled"] == false and
       .["my.setting"] == 42' "$SETTINGS_PATH" >/dev/null

before=$(sha256sum "$SETTINGS_PATH")
[[ $(sh "$REPO/scripts/merge-settings.sh") == unchanged ]]
[[ $(sha256sum "$SETTINGS_PATH") == "$before" ]]
echo 'merge-settings: seeded, merged, preserved custom agents, and stayed idempotent'
