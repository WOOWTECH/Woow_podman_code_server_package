# Initial package — code-server + pi ACP adapter

Status: shipped, main HEAD 2026-08-30.

## Motivation

The `.197` podman host already runs `pi-web` (via [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)) and `open-design` (via [`Woow_podman_opendesign`](https://github.com/WOOWTECH/Woow_podman_opendesign)). Both bundle the pi CLI internally and share a single `pi-agent-data` podman volume so a session started in one shows up in the other — the "OD sees pi-agent" pattern documented in that repo's plan doc.

This repo extends the pattern to a browser IDE: `code-server` + the [ACP Client](https://open-vsx.org/extension/formulahendry/acp-client) VS Code extension, wired so the right-side chat panel talks to `pi` through `pi-acp` — the same shared `/data/pi-agent/` volume, so the user's providers/skills/sessions carry over.

## Decisions

1. **Quadlet, single container.** No sidecar (code-server has its own auth + WebSocket support). Matches `Woow_podman_pi_agent_package`'s deployment shape.
2. **Upstream `codercom/code-server:4.135.0` as base image**, with our own overlay for Node 22 + pi + pi-acp + the ACP extension. We ship pi 0.83.0 to match the sibling pi-agent-package version — the shared volume schema must not drift.
3. **Only `pi-acp` bundled** (not Claude Code / Codex / Gemini adapters). The sidebar in the ACP extension will show them as installable, but only pi is connected out of the box. Adding more adapters is a follow-up when there's demand.
4. **`pi-code` wrapper is the ACP command**, not raw `pi-acp`. The wrapper re-scopes `HOME` to `/data/pi-agent/home` for the pi subprocess only, without moving code-server's own `HOME`. This is the same trick OD's `pi-od` wrapper uses. See `rootfs/usr/local/bin/pi-code` for the actual script.
5. **LAN publish `0.0.0.0:8443`** with a shared `PASSWORD=woowtech` for the initial deploy. Deliberate short-cut: the users are on the office LAN, TLS terminates elsewhere (NPM or CF Tunnel if we front it). Documenting explicitly that this is only safe on a trusted LAN.
6. **Workspace = host `~/Desktop`** bind-mounted at `/workspace`. Files edited in code-server land back on the host owned by uid 1000, so a `git push` from the host terminal against the same repo works without permission gymnastics. Also mount host `~/.ssh` (ro) and `~/.gitconfig` (ro) so `git commit` and `git push` over SSH work out of the box.
7. **`amd64 + aarch64`** CI matrix, ghcr push on main + release. Same shape as pi-agent-package.

## Files

```
Containerfile              base + Node 22 + pi + pi-acp + ACP extension
quadlet/code-server.container    LAN publish, shared /data/pi-agent mount, git identity mounts
rootfs/
  usr/local/bin/pi-code    HOME re-scoping wrapper -> pi-acp -> pi --mode rpc
  etc/skel/.local/share/code-server/User/settings.json
                           default settings.json wiring the ACP extension to pi-code
systemd/
  code-server-health.{service,timer}   30s podman healthcheck refresh
scripts/install.sh         build image, install units, start, wait for /healthz
scripts/uninstall.sh       stop units, remove container (KEEPS pi-agent-data)
tests/
  smoke-container.sh       container up, /healthz 200, password gate
  smoke-pi-integration.sh  pi/pi-acp/pi-code present, /data/pi-agent visible
  smoke-acp.sh             extension installed, settings.json wired
.github/workflows/build.yml  amd64 + arm64, ghcr push on main + release
```

## Rollback

`./scripts/uninstall.sh` removes the container + units. The `pi-agent-data` volume is external (owned by `Woow_podman_pi_agent_package`) and is never touched by this repo's teardown. So a rollback loses the code-server container instance but nothing pi-side.
