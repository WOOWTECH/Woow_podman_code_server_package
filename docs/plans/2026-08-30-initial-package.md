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

---

## 2026-09-xx — pi state made internal

Status: shipped, branch `feat/internal-pi-agent`.

WOOWTECH is now aligning three code-server deployments — this podman
package, a new Home Assistant add-on (`Woow_ha_code_server_add_on`), and
a new k3s Helm chart (`Woow_k3s_code_server_package`) — to an identical
pi/ACP feature set. See `PARITY_CONTRACT.md` for the full cross-platform
contract this section only summarizes.

Decision 2 above ("the shared volume schema must not drift") is
**superseded**: the lockstep partner for `PI_CODING_AGENT_VERSION` is now
the other two code-server deployments, not `Woow_podman_pi_agent_package`.
Decision retained for the historical record, not because it is still
true.

Changes made:
1. `/data/pi-agent` is now an **internal, deployment-private** named
   volume (`woow-code-server-pi-data`), no longer the external
   `pi-agent-data` volume shared with `Woow_podman_pi_agent_package` /
   `Woow_podman_opendesign`. Seeded from `/opt/pi-agent-skel` at image
   build time.
2. A new `rootfs/usr/local/bin/pi-seed` script performs the same
   idempotent seeding on the HA add-on (s6 oneshot) and k3s chart
   (initContainer) substrates — byte-identical file, see
   `rootfs/opt/SHA256SUMS`.
3. A new internal volume `woow-code-server-ide` for
   `/home/coder/.local/share/code-server/User` — previously unmounted,
   so IDE settings/extension state were silently lost on every container
   recreate. This was a pre-existing gap, not something the sibling
   volume change introduced.
4. `PASSWORD`/`SUDO_PASSWORD` moved out of the committed quadlet into
   `~/.config/woow-code-server/env` (gitignored, mode 600), generated by
   `install.sh` if absent.
5. `scripts/migrate-pi-state.sh` (new, opt-in, never run automatically):
   copies `settings.json` + the ACP session map + code-server's own
   session transcripts from the old shared volume. Does **not** copy
   `auth.json` unless `--with-auth` is passed with an explicit warning —
   `auth.json` is an OAuth pair that pi rewrites on refresh, and copying
   it into two live deployments risks one invalidating the other
   (including the still-running `pi-web` / `open-design` containers that
   keep using the old shared volume — this repo never deletes it).
6. `tests/lib/parity.sh` — a portable adapter (`PARITY_TARGET=podman|ha|k3s`)
   so the same smoke-test assertions run against all three deployments.

Rollback: `git revert` this change and reapply the old quadlet's
`Volume=pi-agent-data.volume:/data/pi-agent` line; the external volume
was never deleted by any part of this change, so nothing is lost by
reverting.
