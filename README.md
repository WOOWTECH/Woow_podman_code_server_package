# Woow Podman code-server

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![code-server](https://img.shields.io/badge/code--server-4.135.0-blueviolet)](https://github.com/coder/code-server)
[![pi-coding-agent](https://img.shields.io/badge/pi--coding--agent-0.83.0-blue)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
[![ACP](https://img.shields.io/badge/ACP%20client-formulahendry.acp--client%400.2.0-green)](https://open-vsx.org/extension/formulahendry/acp-client)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

[`code-server`](https://github.com/coder/code-server) (the browser IDE) on
rootless Podman, packaged with the [pi coding agent](https://github.com/earendil-works/pi)
and the [ACP Client](https://open-vsx.org/extension/formulahendry/acp-client)
extension pre-wired. Open the sidebar, click the ACP tree, hit `pi` — you're
chatting with pi from the right-hand panel of VS Code.

pi's state (login, sessions, skills, model config) is **internal to this
deployment** — it is not shared with any sibling package. This mirrors the
WOOWTECH Home Assistant add-on and k3s chart, which each keep their own pi
state too; see [`PARITY_CONTRACT.md`](PARITY_CONTRACT.md) for the full
cross-platform contract.

---

## What you get

| | |
|---|---|
| **UI** | `http://<host>:8443` — password-gated, LAN-only |
| **IDE** | VS Code (via code-server 4.135.0), OpenVSX extensions |
| **Agent** | pi 0.83.0 available in the ACP right-side chat panel, and as `pi` on the terminal PATH |
| **Workspace** | Host `~/Desktop` bind-mounted at `/workspace` — edit files and they land back on the host owned by you |
| **Persistence** | pi state lives in the internal `woow-code-server-pi-data` volume; IDE settings live in `woow-code-server-ide`; both survive container recreate + reboots |
| **Supervision** | `systemd --user` via Quadlet, 30s healthcheck timer |

---

## How the pi wiring works — 30 seconds

The ACP Client extension in VS Code invokes whatever command you list in
`acp.agents.<name>.command`. This image ships `/usr/local/bin/pi-code` as
that command, and `pi-code` does one job: re-scope `HOME` to
`/data/pi-agent/home` (the internal volume mount) and then `exec pi-acp`,
which in turn spawns `pi --mode rpc` on stdio.

```
VS Code (browser) → ACP extension → pi-code → pi-acp → pi --mode rpc
                                    │
                                    └─ export HOME=/data/pi-agent/home
```

Because the `HOME` re-scope happens inside the wrapper (not on the
code-server container level), the IDE's own state stays put and only the
pi subprocess sees `/data/pi-agent`. `pi-code`, `/etc/profile.d/pi.sh`
(which scopes the terminal's plain `pi` the same way) and the new
`pi-seed` script are byte-identical across podman/HA/k3s — see
`rootfs/opt/SHA256SUMS`.

`docs/plans/2026-08-30-initial-package.md` has the original decision log,
plus a `2026-09-xx` addendum for the internal-pi-state change.

---

## Install

Requires Podman ≥ 4.4 (Quadlet), rootless, on the user account that owns
the podman storage.

```bash
git clone https://github.com/WOOWTECH/Woow_podman_code_server_package.git
cd Woow_podman_code_server_package

./scripts/install.sh
```

`install.sh`:
1. Verifies podman + Quadlet
2. Enables `loginctl` lingering (so the container survives logout)
3. Warns (does not fail) if `~/.gitconfig` is empty, `~/.ssh` has no
   private key, or `~/.local/bin` has dangling symlinks — the four host
   mounts below only work once these are real on the host
4. Creates `~/.config/woow-code-server/env` (mode 600) with a generated
   `PASSWORD`/`SUDO_PASSWORD` if one doesn't already exist — this keeps
   the credential out of git
5. `podman build` → `localhost/woow-code-server:latest`
6. Drops `quadlet/code-server.container`, the two `*.volume` units, and
   the two health units into the right `~/.config/...` directories
7. `systemctl --user daemon-reload && start code-server && enable --now
   code-server-health.timer`
8. Waits for `/healthz` to return 200

Skip the image rebuild with `OD_SKIP_BUILD=1 ./scripts/install.sh`.

### First run

Open `http://<host>:8443` and enter the password printed at the end of
`install.sh` (also in `~/.config/woow-code-server/env`).

pi has **no credentials yet** in this deployment's internal store — sign
in once:

```bash
podman exec -it -u coder code-server sh -lc 'pi login'
```

Then in the IDE: bottom status bar shows `ACP: pi ACP adapter` in green;
the right-side chat panel now uses that login.

> **Migrating from an older install that used the shared `pi-agent-data`
> volume?** Run `./scripts/migrate-pi-state.sh` to copy over
> `settings.json` and your ACP session map (never `auth.json` — see the
> script's own warning and prefer `pi login` instead).

### Uninstall

```bash
./scripts/uninstall.sh            # keeps woow-code-server-pi-data + -ide
./scripts/uninstall.sh --purge    # also deletes them, after a y/N prompt
```

---

## Layout

```
Containerfile              base codercom/code-server + Node 22 + pi + pi-acp + ACP extension
quadlet/
  code-server.container      the podman container definition + mounts + env
  woow-code-server-pi.volume internal pi state volume
  woow-code-server-ide.volume internal IDE user-data volume
rootfs/
  usr/local/bin/pi-code     the HOME-scoping wrapper the ACP extension calls
  usr/local/bin/pi-seed     idempotent pi-state-store seeder (shared w/ HA + k3s)
  etc/profile.d/pi.sh       scopes terminal `pi` to the same store
  etc/skel/…/settings.json  default VS Code settings wiring the ACP adapter
  opt/SHA256SUMS            hashes of the three shared files above
systemd/
  code-server-health.{service,timer}   30s healthcheck refresh
scripts/
  install.sh                build + install + start + wait for /healthz
  uninstall.sh               stop + remove (keeps pi/ide volumes by default)
  migrate-pi-state.sh        opt-in copy from an old shared pi-agent-data volume
tests/
  lib/parity.sh              portable adapter (PARITY_TARGET=podman|ha|k3s)
  smoke-container.sh         container up, /healthz 200, wrong password rejected
  smoke-pi-integration.sh    pi/pi-acp/pi-code present, internal store seeded
  smoke-acp.sh                extension installed, settings.json's 6 required keys wired
docs/plans/                dated design decisions for the changes that shaped this package
.github/workflows/build.yml    amd64 + arm64 CI, ghcr on push/release
```

---

## Verifying a deployment

```bash
# Cheap suite — no LLM calls, no cost. Runs on the host.
bash tests/smoke-container.sh          # /healthz + password gate
bash tests/smoke-pi-integration.sh     # pi + pi-acp + pi-code + internal store
bash tests/smoke-acp.sh                # extension + settings.json
```

Expect **all three green** on a healthy deployment. `smoke-pi-integration.sh`
skips (not fails) the `auth.json` check until you run `pi login`.

---

## Operating

```bash
podman ps --format '{{.Names}}\t{{.Status}}'      # health lives here
journalctl --user -u code-server -f               # systemd events
podman logs -f code-server                        # code-server output
podman exec -it code-server bash                  # shell in the IDE's environment
systemctl --user restart code-server              # restart (pi + IDE state persist in their volumes)
```

To rebuild the image with a newer upstream tag: bump
`ARG CODE_SERVER_VERSION=` in `Containerfile`, `./scripts/install.sh`
(which triggers a rebuild), then `systemctl --user restart code-server`.
Same drill for `PI_CODING_AGENT_VERSION` / `PI_ACP_VERSION` /
`ACP_CLIENT_VERSION` — but bump these in lockstep across all three
code-server deployments (podman, the HA add-on, the k3s chart); see
`PARITY_CONTRACT.md` §2.1 before changing any of them.

---

## Security

Stated plainly.

**Deliberate short-cuts.** The generated `PASSWORD` in
`~/.config/woow-code-server/env` is fine on an office LAN behind a
firewall. It is **not** fine past that boundary — Basic-auth-equivalent
password over plain HTTP sends the credential in base64 on every
request. If you want to expose this past the trusted LAN:
- Front it with an authenticating reverse proxy (nginx / NPM / Cloudflare
  Access) that terminates TLS, and set a strong `PASSWORD` in the env file.
- Or change `PublishPort=` to `127.0.0.1:8443:8080` and force everyone
  through the reverse proxy.

**Trusted HTTPS needed for the ACP chat webview.** The sidebar tree,
status bar, and pi-adapter connection work fine over plain HTTP. The
**chat webview panel** does not — VS Code delivers webview content via
ServiceWorker, which fails to register unless the origin is
"secure" (`localhost`, or a certificate the OS trusts). Self-signed
certificates users click through at the page level still fail at the
SW level. This is the one respect in which podman is **not** at parity
with the sibling HA add-on and k3s chart today: both of those sit behind
a browser-trusted origin (HA ingress; a Cloudflare Tunnel hostname) and
their chat webview is confirmed working, while podman's default LAN
exposure is plain HTTP. To get the chat panel rendering here too:
- Recommended: front this container with NPM / nginx / Cloudflare
  Access carrying a Let's Encrypt (or comparable OS-trusted) cert, and
  change `PublishPort=` to `127.0.0.1:8443:8080`.
- Alternative: use [`mkcert`](https://github.com/FiloSottile/mkcert)
  on each user machine (`mkcert -install` once, `mkcert <host-ip>` to
  issue), point code-server at the resulting cert, and the browser will
  trust it locally without a warning.
- Zero-infrastructure alternative: SSH port-forward to the host
  (`ssh -L 8443:localhost:8443 <host>`) and browse
  `http://localhost:8443` — localhost is unconditionally a secure
  context, so the webview works with no cert at all.
- Not enough: `code-server --cert` on its own. Confirmed on
  2026-08-30 live test — page loads with a warning-clickthrough, but
  the webview SW refuses to register on the self-signed cert.

**A universal proxy gotcha, if you do front this with a reverse proxy:**
it must forward a `Host`/`Origin` header matching what the browser
actually used, or code-server 403s the WebSocket upgrade. This looks
exactly like the ServiceWorker/secure-context issue above but is a
different, unrelated failure mode — pass `--trusted-origins <hostname>`
to code-server (via `Exec=` in the quadlet) if you add a proxy and hit a
dead sidebar/terminal despite a valid cert.

**What the container can do.** `code-server` runs as `coder` (uid 1000)
inside a rootless user namespace mapped to the invoking host user.
`sudo` inside the container is enabled via `SUDO_PASSWORD` — turn it off
(unset the env in `~/.config/woow-code-server/env`) if you don't want
users apt-installing things at runtime.

**Bind mounts.** `~/Desktop`, `~/.ssh`, `~/.gitconfig`, `~/.local/bin`
are all mounted from your host uid 1000. Anything with code-server
shell access can read those. `.ssh` is `:ro` on purpose — no worse than
what the invoking user already has. Note: on a fresh host these may not
actually be usable until you populate them — `install.sh` warns about
this explicitly (empty `.gitconfig`, no SSH private key, dangling
symlinks in `.local/bin`).

**pi's credential.** The only credential pi holds is an OAuth pair
(`auth.json`, mode 600) written by `pi login` — access token, refresh
token, expiry, account id. There is **no API key** anywhere by default
(`models.json` is `{"providers":{}}` unless you set
`PI_PROVIDER_KEYS_JSON`). `auth.json` lives on the internal
`woow-code-server-pi-data` volume; anyone with a shell in this container
has it. pi **rewrites** the refresh token on every refresh, which is
exactly why this repo does not copy `auth.json` between deployments —
copy it into two places and whichever refreshes first can invalidate the
other. Run `pi login` fresh in each deployment instead.

---

## Related packages

- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — the VS Code extension that renders the right-side agent chat panel
- [pi-acp](https://www.npmjs.com/package/pi-acp) — community bridge from ACP JSON-RPC to pi's `--mode rpc`
- [`Woow_ha_code_server_add_on`](https://github.com/WOOWTECH/Woow_ha_code_server_add_on) — the same pi/ACP wiring, packaged as a Home Assistant add-on
- [`Woow_k3s_code_server_package`](https://github.com/WOOWTECH/Woow_k3s_code_server_package) — the same image, deployed on k3s via Helm + Cloudflare Tunnel

## License

MIT
