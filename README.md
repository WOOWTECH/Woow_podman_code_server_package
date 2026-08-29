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
chatting with pi from the right-hand panel of VS Code, with your existing
providers/skills/sessions carried over from the sibling
[`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
deployment.

---

## What you get

| | |
|---|---|
| **UI** | `http://<host>:8443` — password-gated, LAN-only |
| **IDE** | VS Code (via code-server 4.135.0), OpenVSX extensions |
| **Agent** | pi 0.83.0 available in the ACP right-side chat panel, and as `pi` on the terminal PATH |
| **Workspace** | Host `~/Desktop` bind-mounted at `/workspace` — edit files and they land back on the host owned by you |
| **Persistence** | Sessions/skills/providers live in the shared `pi-agent-data` podman volume; survives container recreate + reboots (see security note) |
| **Supervision** | `systemd --user` via Quadlet, 30s healthcheck timer |

---

## How the pi wiring works — 30 seconds

The ACP Client extension in VS Code invokes whatever command you list in
`acp.agents.<name>.command`. This image ships `/usr/local/bin/pi-code` as
that command, and `pi-code` does one job: re-scope `HOME` to
`/data/pi-agent/home` (the volume mount) and then `exec pi-acp`, which in
turn spawns `pi --mode rpc` on stdio.

```
VS Code (browser) → ACP extension → pi-code → pi-acp → pi --mode rpc
                                    │
                                    └─ export HOME=/data/pi-agent/home
```

Because the `HOME` re-scope happens inside the wrapper (not on the
code-server container level), the IDE's own state stays put and only the
pi subprocess sees the shared volume. That's the same pattern
[OD's `pi-od` wrapper](https://github.com/WOOWTECH/Woow_podman_opendesign/blob/main/pi-od)
uses on `.197`.

`docs/plans/2026-08-30-initial-package.md` has the full decision log.

---

## Install

Requires Podman ≥ 4.4 (Quadlet), rootless, on the user account that owns
the podman storage. Recommended: install
[`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
first so the shared `pi-agent-data` volume is populated (models, skills,
sessions). If you don't, this repo creates an empty one and pi has no
provider configured until you `pi login`.

```bash
git clone https://github.com/WOOWTECH/Woow_podman_code_server_package.git
cd Woow_podman_code_server_package

./scripts/install.sh
```

`install.sh`:
1. Verifies podman + Quadlet
2. Enables `loginctl` lingering (so the container survives logout)
3. `podman build` → `localhost/woow-code-server:latest`
4. Drops `quadlet/code-server.container` into `~/.config/containers/systemd/`
   and the two health units into `~/.config/systemd/user/`
5. `systemctl --user daemon-reload && start code-server && enable --now
   code-server-health.timer`
6. Waits for `/healthz` to return 200

Skip the image rebuild with `OD_SKIP_BUILD=1 ./scripts/install.sh`.

### First login

Open `http://<host>:8443` and enter the password. Default is `woowtech` —
**change it** by editing `Environment=PASSWORD=` in the quadlet file and
restarting the service. See [Security](#security).

The ACP Client extension is pre-installed with pi wired as the default
adapter. Bottom status bar shows `ACP: pi ACP adapter` in green when
things are working; right side panel opens the chat.

### Uninstall

```bash
./scripts/uninstall.sh
```

Stops + removes the container and units. The `pi-agent-data` volume is
**not** touched — it's owned by the sibling pi-agent-package.

---

## Layout

```
Containerfile              base codercom/code-server + Node 22 + pi + pi-acp + ACP extension
quadlet/
  code-server.container    the podman container definition + mounts + env
rootfs/
  usr/local/bin/pi-code    the HOME-scoping wrapper the ACP extension calls
  etc/skel/…/settings.json default VS Code settings wiring the ACP adapter
systemd/
  code-server-health.{service,timer}   30s healthcheck refresh
scripts/
  install.sh               build + install + start + wait for /healthz
  uninstall.sh             stop + remove (KEEPS pi-agent-data)
tests/
  smoke-container.sh       container up, /healthz 200, wrong password rejected
  smoke-pi-integration.sh  pi/pi-acp/pi-code present, /data/pi-agent visible
  smoke-acp.sh             extension installed, settings.json wired to pi-code
docs/plans/                dated design decisions for the changes that shaped this package
.github/workflows/build.yml    amd64 + arm64 CI, ghcr on push/release
```

---

## Verifying a deployment

```bash
# Cheap suite — no LLM calls, no cost. Runs on the host.
bash tests/smoke-container.sh          # /healthz + password gate
bash tests/smoke-pi-integration.sh     # pi + pi-acp + pi-code + shared volume
bash tests/smoke-acp.sh                # extension + settings.json
```

Expect **all three green** on a healthy deployment. `smoke-pi-integration.sh`
skips (not fails) the "sibling artefact visible" checks if `pi-agent-data`
was just created empty by this installer.

---

## Operating

```bash
podman ps --format '{{.Names}}\t{{.Status}}'      # health lives here
journalctl --user -u code-server -f               # systemd events
podman logs -f code-server                        # code-server output
podman exec -it code-server bash                  # shell in the IDE's environment
systemctl --user restart code-server              # restart (state persists in /data volume)
```

To rebuild the image with a newer upstream tag: bump
`ARG CODE_SERVER_VERSION=` in `Containerfile`, `./scripts/install.sh`
(which triggers a rebuild), then `systemctl --user restart code-server`.
Same drill for `PI_CODING_AGENT_VERSION` and `PI_ACP_VERSION` — but bump
`PI_CODING_AGENT_VERSION` in lockstep with the sibling pi-agent-package
so the two schemas stay compatible.

---

## Security

Stated plainly.

**Deliberate short-cuts.** The default `PASSWORD=woowtech` in the shipped
quadlet is fine on an office LAN behind a firewall. It is **not** fine
past that boundary — Basic-auth-equivalent password over plain HTTP
sends the credential in base64 on every request. If you want to expose
this past the trusted LAN:
- Front it with an authenticating reverse proxy (nginx / NPM / Cloudflare
  Access) that terminates TLS, and change `Environment=PASSWORD=` to a
  strong value.
- Or change `PublishPort=` to `127.0.0.1:8443:8080` and force everyone
  through the reverse proxy.

**Trusted HTTPS needed for the ACP chat webview.** The sidebar tree,
status bar, and pi-adapter connection work fine over plain HTTP. The
**chat webview panel** does not — VS Code delivers webview content via
ServiceWorker, which fails to register unless the origin is
"secure" (`localhost`, or a certificate the OS trusts). Self-signed
certificates users click through at the page level still fail at the
SW level. To get the chat panel rendering:
- Recommended: front this container with NPM / nginx / Cloudflare
  Access carrying a Let's Encrypt (or comparable OS-trusted) cert.
  This is the same pattern [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
  uses to expose pi-web.
- Alternative: use [`mkcert`](https://github.com/FiloSottile/mkcert)
  on each user machine (`mkcert -install` once, `mkcert 192.168.2.197`
  to issue), point code-server at the resulting cert, and the browser
  will trust it locally without a warning.
- Not enough: `code-server --cert` on its own. Confirmed on
  2026-08-30 live test — page loads with a warning-clickthrough, but
  the webview SW refuses to register on the self-signed cert.

**What the container can do.** `code-server` runs as `coder` (uid 1000)
inside a rootless user namespace mapped to the invoking host user.
`sudo` inside the container is enabled via `SUDO_PASSWORD` (also
`woowtech` by default) — turn it off (unset the env in the quadlet) if
you don't want users apt-installing things at runtime.

**Bind mounts.** `~/Desktop`, `~/.ssh`, `~/.gitconfig`, `~/.local/bin`
are all mounted from your host uid 1000. Anything with code-server
shell access can read those. `.ssh` is `:ro` on purpose — no worse than
what the invoking user already has.

**pi's provider keys.** Live on `/data/pi-agent/models.json` inside the
shared volume, mode 600. `code-server` (uid 1000) is the owner and can
read them — that's how the ACP panel gets configured providers
"for free". Anyone with a shell in this container therefore has those
keys too. Rotate via pi's Models UI as usual; do not commit keys to the
workspace repo.

---

## Related packages

- [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) — the pi-web sibling; both containers share the same `pi-agent-data` volume so a session started in either shows up in both
- [`Woow_podman_opendesign`](https://github.com/WOOWTECH/Woow_podman_opendesign) — OpenDesign with the same pi-agent-data volume sharing pattern
- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — the VS Code extension that renders the right-side agent chat panel
- [pi-acp](https://www.npmjs.com/package/pi-acp) — community bridge from ACP JSON-RPC to pi's `--mode rpc`

## License

MIT
