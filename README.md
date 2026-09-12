# Woow Podman code-server

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.9%20rootless-892CA0)](https://podman.io)
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
| **UI** | `http://127.0.0.1:18443` — password-gated, loopback by default (SSH forward, optional tailscale sidecar, or a proxy on the same host) |
| **IDE** | VS Code (via code-server 4.135.0), OpenVSX extensions |
| **Agent** | pi 0.83.0 available in the ACP right-side chat panel, and as `pi` on the terminal PATH |
| **Workspace** | Host `~/Desktop` bind-mounted at `/workspace` — edit files and they land back on the host owned by you |
| **Persistence** | pi state lives in the internal `woow-code-server-pi-data` volume; IDE settings live in `woow-code-server-ide`; both survive container recreate + reboots. **VS Code extensions and runtime `npm install -g` do not** — they live in the container's writable layer and are lost on recreate. For a package that must survive, install it with an explicit prefix on the state volume: `npm install -g --prefix /data/pi-agent/npm-global <pkg>` (that bin dir is already on `PATH`). |
| **Supervision** | `systemd --user` via Quadlet, `Restart=always`, 30s healthcheck timer |

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

Rootless Podman >= 4.9 with the Quadlet generator, on the user account that owns the podman
storage. Tested on Ubuntu 24.04 (podman 4.9.3, systemd 255) with linger enabled.

```bash
git clone https://github.com/WOOWTECH/Woow_podman_code_server_package.git
cd Woow_podman_code_server_package

scripts/install.sh                      # or: scripts/install.sh --port 8443 --bind 0.0.0.0
```

`scripts/install.sh` is idempotent: an unchanged re-run restarts nothing. It

1. checks the host (not root, podman >= 4.9, the Quadlet generator, a reachable
   `systemctl --user`) and enables linger, so the IDE survives logout and comes back at boot;
2. creates `~/.config/woow-code-server/woow-code-server.env` (mode 0600) from
   [`config/woow-code-server.env.example`](config/woow-code-server.env.example) on the first
   run. `--port N`, `--bind ADDR` and `--set KEY=VALUE` change a setting and save it there;
3. refuses to continue when a container named `code-server` exists that Quadlet does not
   manage (Quadlet starts containers with `podman run --replace`, which would delete it), or
   when the port is already taken;
4. renders the units in [`quadlet/`](quadlet/) from that env file (`@@VAR@@` tokens,
   whitelisted in `quadlet/render-vars`) and checks them with the podman 4.9.3 Quadlet
   generator and `systemd-analyze --user verify` **before** anything is installed;
5. creates the host bind sources that are missing (workspace, `~/.ssh` 0700, an empty
   gitconfig, `~/.local/bin`), seeds a git identity from `GIT_USER_NAME`/`GIT_USER_EMAIL` or
   by asking, and warns about a missing SSH key or dangling symlinks;
6. builds `localhost/woow-code-server:$(cat VERSION)` when that tag does not exist yet
   (`--rebuild` forces it, `--no-build` forbids it);
7. creates the podman secret `code-server-config` with a random 24-character password when it
   is missing (a pre-Quadlet `~/.config/woow-code-server/env` is adopted instead, so the
   password does not change under the users);
8. installs only the files that changed, restarts only the units whose files changed, and
   enables `code-server-health.timer`;
9. waits for the container to be healthy and runs `tests/smoke.sh --quick`.

`scripts/install.sh --dry-run` renders and validates everything and reports what it would
change, without changing anything.

### Settings

Edit `~/.config/woow-code-server/woow-code-server.env` and re-run `scripts/install.sh` (or pass
`--set KEY=VALUE`). The values are rendered into the unit, so a changed one restarts the
container and an unchanged one does not.

| Key | Default | Notes |
|---|---|---|
| `CODE_SERVER_BIND` | `127.0.0.1` | Publish address. A LAN IP or `0.0.0.0` puts a plain-HTTP password prompt on that network, and the ACP chat webview will not render there (see [Security](#security)). |
| `CODE_SERVER_PORT` | `18443` | Host port. The old default, `8443`, collides with the Caddy proxy in `Woow_podman_vpn_tailscale_package`. |
| `CODE_SERVER_WORKSPACE` | `%h/Desktop` | The folder that opens in the IDE, bind-mounted at `/workspace`. `%h` is the installing user's home. |
| `CODE_SERVER_SSH_DIR` | `%h/.ssh` | Mounted read-only at `/home/coder/.ssh`. |
| `CODE_SERVER_GITCONFIG` | `%h/.gitconfig` | Mounted read-only at `/etc/gitconfig` (git's system path). |
| `CODE_SERVER_HOST_BIN` | `%h/.local/bin` | Mounted read-only at `/mnt/host-local-bin`, first on `PATH`. |
| `PI_DEFAULT_PROVIDER` / `PI_DEFAULT_MODEL` | `openai-codex` / `gpt-5.6-sol` | Seeded into pi's `settings.json` only when it is absent. |
| `CODE_SERVER_TAILSCALE` | `no` | `yes` installs the optional sidecar below (`--with-tailscale`). |
| `CODE_SERVER_TS_HOSTNAME` | `woow-code-server` | The tailnet node name of that sidecar. |

### First run

```bash
scripts/show-password.sh                # the login password, from the podman secret
```

The password lives in the podman secret `code-server-config` as a small YAML config file that
code-server reads through `$CODE_SERVER_CONFIG`; it is never in a unit file, in
`podman inspect`, or in the container's environment. Rotate it with
`scripts/install.sh --rotate-password`.

Open the IDE at `http://127.0.0.1:18443` on the host itself, or forward it:

```bash
ssh -L 18443:127.0.0.1:18443 <host>     # then open http://localhost:18443
```

pi has **no credentials yet** in this deployment's internal store, so sign in once:

```bash
podman exec -it -u coder code-server sh -lc 'pi login'
```

Then in the IDE: the bottom status bar shows `ACP: pi ACP adapter` in green, and the right-side
chat panel uses that login.

> **Coming from an older install that used the shared `pi-agent-data` volume?** Run
> `scripts/migrate-pi-state.sh` to copy `settings.json` and your ACP session map (never
> `auth.json` — see the script's own warning, and prefer `pi login`).

### Optional: a tailnet front door (tailscale sidecar)

The ACP chat webview only renders on a browser-trusted origin (or on `localhost`). The sidecar
gives this deployment a tailnet HTTPS name with a real certificate, without publishing anything
on the LAN:

```bash
scripts/install.sh --with-tailscale --ts-authkey-file ~/ts.key   # a tagged, ephemeral, pre-approved key
```

It installs `quadlet/optional/woow-tailscale-code-server.*`: a userspace-mode tailscale node on
the host network that serves `http://127.0.0.1:<port>` at
`https://<CODE_SERVER_TS_HOSTNAME>.<tailnet>.ts.net/`, with the auth key in a podman secret and
the serve config rendered from `config/tailscale-serve.json.in`.
`scripts/install.sh --without-tailscale` removes the sidecar again (its node state volume is
kept). On a host whose node is already logged in, the existing state volume is adopted and no
key is needed.

### Upgrade

```bash
git pull
scripts/upgrade.sh
```

`upgrade.sh` snapshots the installed units, runs `scripts/backup.sh`, then `scripts/install.sh`
(which builds the new `VERSION` tag and restarts what changed) and the full `tests/smoke.sh`.
If anything fails it puts the previous units back, restarts them on the previous image tag
(which is still there) and exits 1. After a successful upgrade it keeps the current and the
previous image tag and removes older ones (`--keep-images` keeps all).

`VERSION` is `<code-server version>-<package revision>` and must match the unit's `Image=` tag
and the `ARG CODE_SERVER_VERSION` in the Containerfile; CI fails when they disagree. Bumping
pi/pi-acp/ACP versions is a separate, cross-platform change — see `PARITY_CONTRACT.md` §2.1.

### Backup and restore

```bash
scripts/backup.sh                       # -> ~/backups/woow-code-server/<timestamp>/
scripts/backup.sh --include-secrets     # also the login password and tailscale key, in secrets/
scripts/backup.sh --stop                # stop the IDE during the export, for a consistent pi state
scripts/restore.sh ~/backups/woow-code-server/<timestamp>      # asks first; --yes to skip
```

The backup exports `woow-code-server-pi-data` (pi login, sessions, skills),
`woow-code-server-ide` (IDE settings) and the sidecar state when it exists, each with a
`.sha256`, plus a copy of the env file. `restore.sh` stops the IDE, replaces those volumes,
starts it again and runs the smoke test.

### Uninstall

```bash
scripts/uninstall.sh                    # stop and remove the units; keep the volumes, the secret and the image
scripts/uninstall.sh --purge            # also delete the volumes (final backup first) and the secrets
scripts/uninstall.sh --purge-images     # also remove the localhost/woow-code-server:* images
```

`--purge` is the only way these scripts delete data; it asks you to type the app name (`--yes`
skips that, for scripts). A plain uninstall followed by `scripts/install.sh` adopts the same
volumes and the same password. Your workspace, `~/.ssh`, `~/.gitconfig`, `~/.local/bin` and the
env file are never touched.

### Migrating an existing deployment

A host that already runs the pre-conversion units (the hand-installed Quadlet files, e.g.
woowtechopenclaw):

1. Back up first: `scripts/backup.sh --include-secrets` needs the units installed, so instead
   run `podman volume export woow-code-server-pi-data -o ~/pi-data-pre-quadlet.tar` and the
   same for `woow-code-server-ide`, and keep a copy of the old unit files.
2. The old health units in `~/.config/systemd/user/` were not installed by these scripts, so
   `install.sh` refuses to overwrite them. Move them aside once:
   `systemctl --user disable --now code-server-health.timer` and
   `mv ~/.config/systemd/user/code-server-health.{service,timer} ~/backups/`.
3. `scripts/install.sh --port 18443` (or `--port 8443 --bind 0.0.0.0` to keep the old
   endpoint). The existing `code-server.container` and the two `*.volume` files are adopted
   after a backup copy into `~/.local/state/woow-quadlet/woow-code-server/replaced/`; the
   volumes keep their data; the password in `~/.config/woow-code-server/env` is adopted into
   the podman secret, so nobody is locked out.
4. Check the login, then delete `~/.config/woow-code-server/env` and any `env.bak-*`: they hold
   the password in plain text.
5. **The endpoint changes** from `0.0.0.0:8443` to `127.0.0.1:18443` unless you pass the old
   values. LAN users of `http://<host>:8443` lose direct access, and a hand-made tailscale
   `serve --tcp=8443` stops matching. Announce the new URL, or adopt the repo's sidecar
   (`--with-tailscale`), which keeps the node identity through the
   `woow-tailscale-code-server-state` volume and moves the URL to
   `https://<hostname>.<tailnet>.ts.net/`.

Rollback: `scripts/uninstall.sh`, put the old unit files back from
`~/.local/state/woow-quadlet/woow-code-server/replaced/<timestamp>/`, `daemon-reload`, start.

---

## Layout

```
VERSION                    <code-server version>-<package revision>; the image tag
Containerfile              base codercom/code-server + Node 22 + pi + pi-acp + ACP extension
quadlet/
  code-server.container      the container, its mounts and its health check (@@VAR@@ tokens)
  woow-code-server-pi.volume internal pi state volume
  woow-code-server-ide.volume internal IDE user-data volume
  render-vars                the variables install.sh may substitute
  optional/                  the tailscale sidecar, installed with --with-tailscale
config/
  woow-code-server.env.example  per-host settings -> ~/.config/woow-code-server/woow-code-server.env
  tailscale-serve.json.in       the sidecar's serve config, rendered with the port in effect
rootfs/
  usr/local/bin/pi-code     the HOME-scoping wrapper the ACP extension calls
  usr/local/bin/pi-seed     idempotent pi-state-store seeder (shared w/ HA + k3s)
  etc/profile.d/pi.sh       scopes terminal `pi` to the same store
  etc/skel/…/settings.json  default VS Code settings wiring the ACP adapter
  opt/SHA256SUMS            hashes of the three shared files above
systemd/
  code-server-health.{service,timer}   30s healthcheck refresh (bare `podman`)
scripts/
  lib/quadlet-lib.sh        the shared WOOWTECH Quadlet library (vendored, checksum-pinned)
  install.sh                render + validate + build + install + restart what changed
  upgrade.sh                snapshot + backup + install + smoke, with automatic rollback
  uninstall.sh              stop + remove (keeps data unless --purge)
  backup.sh / restore.sh    volume exports and imports
  show-password.sh          print the login password from the podman secret
  migrate-pi-state.sh       opt-in copy from an old shared pi-agent-data volume
tests/
  dryrun.sh                 render the units and check them with the 4.9.3 generator (+ dryrun.local.sh, fixtures/)
  smoke.sh                  the podman checks, then the parity suites below
  lib/parity.sh             portable adapter (PARITY_TARGET=podman|ha|k3s)
  smoke-container.sh        container up, /healthz 200, password gate
  smoke-pi-integration.sh   pi/pi-acp/pi-code present, internal store seeded
  smoke-acp.sh              extension installed, settings.json's required keys wired
  smoke-toolchain.sh        pip/venv, npm -g, git identity, pi on PATH in a login shell
docs/plans/                dated design decisions for the changes that shaped this package
.github/workflows/quadlet-ci.yml  vendored lib checksum + dry-run + shellcheck
.github/workflows/build.yml       amd64 + arm64 image build, ghcr on push/release
```

---

## Verifying a deployment

```bash
tests/smoke.sh            # the podman checks + all four parity suites below
tests/smoke.sh --quick    # the podman checks + smoke-container.sh (what install.sh runs)
tests/dryrun.sh           # no deployment needed: render the units and check them statically
```

`tests/smoke.sh` first checks what only the podman deployment can check — the unit and the
health timer are active, the container is healthy, `/healthz` answers 200, the port listens
**only** on the configured address, the login password from the podman secret is accepted, the
secret is mounted inside, and neither the container's environment nor the unit file carries a
`PASSWORD` — and then runs the four portable suites:

```bash
PARITY_TARGET=podman tests/smoke-container.sh          # /healthz + password gate
PARITY_TARGET=podman tests/smoke-pi-integration.sh     # pi + pi-acp + pi-code + internal store
PARITY_TARGET=podman tests/smoke-acp.sh                # extension + settings.json
PARITY_TARGET=podman tests/smoke-toolchain.sh          # pip/venv, npm -g, git identity, pi on PATH
```

Expect **all of them green** on a healthy deployment. `smoke-pi-integration.sh`
skips (not fails) the `auth.json` check until you run `pi login`, and
`smoke-toolchain.sh` skips the git checks until a git identity is available
(mounted at `/etc/gitconfig` by the quadlet, or seeded by `install.sh`).

`smoke-toolchain.sh` is new in this revision and every check in it exists
because the 2026-09 field test found it broken on a deployment that passed all
the other suites: pi could write a pytest suite it had no pip to run, could not
`npm install -g`, and could not `git commit`. `smoke-pi-integration.sh`
likewise gained a Unicode-path check — pi silently folded U+3000 to an ASCII
space on every read and write, so `Q1　報告.txt` resolved to `Q1 報告.txt`. See
`PARITY_CONTRACT.md` §H.

---

## Operating

```bash
podman ps --format '{{.Names}}\t{{.Status}}'      # health lives here
journalctl --user -u code-server -f               # systemd events
podman logs -f code-server                        # code-server output
podman exec -it code-server bash                  # shell in the IDE's environment
systemctl --user restart code-server              # restart (pi + IDE state persist in their volumes)
```

To rebuild the image with a newer upstream tag: bump `ARG CODE_SERVER_VERSION=` in
`Containerfile` **and** `VERSION` (and therefore the unit's `Image=` tag), then run
`scripts/upgrade.sh`, which backs up, builds, restarts and rolls back on a failed smoke test.
Same drill for `PI_CODING_AGENT_VERSION` / `PI_ACP_VERSION` / `ACP_CLIENT_VERSION` — but bump
these in lockstep across all three code-server deployments (podman, the HA add-on, the k3s
chart); see `PARITY_CONTRACT.md` §2.1 before changing any of them.

The image is built locally and never pushed (`Pull=never`). Publishing versioned images to
GHCR and switching the unit to them is future work; `build.yml` only produces `main-<sha>`
images today, which this deployment does not consume.

---

## Security

Stated plainly.

**Where the password lives.** A random 24-character password in the podman secret
`code-server-config`, mounted read-only at `/run/secrets/code-server-config.yaml` and read by
code-server through `$CODE_SERVER_CONFIG`. It is not in the unit file, not in
`systemctl --user cat`, not in the container's environment and not in `podman inspect` — which
matters on a host that also runs the podman MCP server, whose `inspect` tool would otherwise
hand it out. Print it with `scripts/show-password.sh`, rotate it with
`scripts/install.sh --rotate-password`.

**The default endpoint is loopback.** `127.0.0.1:18443`: only processes on the host reach it,
and a password over plain HTTP never crosses a network. The three supported ways in are an SSH
port-forward (`ssh -L 18443:127.0.0.1:18443 <host>`), the optional tailscale sidecar, or a
TLS-terminating proxy on the same host (NPM / nginx / cloudflared). Setting
`CODE_SERVER_BIND` to a LAN IP or `0.0.0.0` puts a plain-HTTP password prompt on that network
(the credential is sent base64-encoded on every request) and still does not make the chat
webview work: install.sh warns, and it is the right choice only behind a trusted proxy.

**Trusted HTTPS needed for the ACP chat webview.** The sidebar tree,
status bar, and pi-adapter connection work fine over plain HTTP. The
**chat webview panel** does not — VS Code delivers webview content via
ServiceWorker, which fails to register unless the origin is
"secure" (`localhost`, or a certificate the OS trusts). Self-signed
certificates users click through at the page level still fail at the
SW level. This is the one respect in which podman is **not** at parity
with the sibling HA add-on and k3s chart today: both of those sit behind
a browser-trusted origin (HA ingress; a Cloudflare Tunnel hostname) and
their chat webview is confirmed working. On podman, the ways to get the
chat panel rendering are:
- The optional tailscale sidecar (`scripts/install.sh --with-tailscale`):
  a tailnet HTTPS name with a browser-trusted certificate, and nothing
  published beyond loopback.
- Front this container with NPM / nginx / Cloudflare Access carrying a
  Let's Encrypt (or comparable OS-trusted) cert, on this host, and keep
  `CODE_SERVER_BIND=127.0.0.1`.
- Alternative: use [`mkcert`](https://github.com/FiloSottile/mkcert)
  on each user machine (`mkcert -install` once, `mkcert <host-ip>` to
  issue), point code-server at the resulting cert, and the browser will
  trust it locally without a warning.
- Zero-infrastructure alternative, and the default: SSH port-forward to
  the host (`ssh -L 18443:127.0.0.1:18443 <host>`) and browse
  `http://localhost:18443` — localhost is unconditionally a secure
  context, so the webview works with no cert at all. Observed working
  on this deployment (PARITY_CONTRACT.md P31).
- Not enough: `code-server --cert` on its own. Confirmed on
  2026-08-30 live test — page loads with a warning-clickthrough, but
  the webview SW refuses to register on the self-signed cert.

**A universal proxy gotcha, if you do front this with a reverse proxy:**
it must forward a `Host`/`Origin` header matching what the browser
actually used, or code-server 403s the WebSocket upgrade. This looks
exactly like the ServiceWorker/secure-context issue above but is a
different, unrelated failure mode — pass `--trusted-origins <hostname>`
to code-server (add an `Exec=` line to `quadlet/code-server.container`
and re-run `scripts/install.sh`) if you add a proxy and hit a dead
sidebar/terminal despite a valid cert.

**What the container can do.** `code-server` runs as `coder` (uid 1000)
inside a rootless user namespace mapped to the invoking host user.

**There is no root escalation inside the container, and `SUDO_PASSWORD`
does not give you one.** The quadlet sets `NoNewPrivileges=true`, so
`sudo` fails with *"The 'no new privileges' flag is set, which prevents
sudo from running as root"* no matter what password is set — verified.
An earlier revision of this README said the opposite, and the Containerfile
told you to `apt install` missing tools at runtime on that basis; both were
wrong, and one of them was the reason the image shipped without pip. Install
what the image needs **in the Containerfile**. `install.sh` no longer
generates a `SUDO_PASSWORD`: a credential that grants nothing is pure
liability. If you genuinely need root in there, drop `NoNewPrivileges` from
the quadlet yourself and understand what you are trading away.

**Bind mounts.** The workspace, the SSH directory, the gitconfig and the
host bin directory are mounted from the installing user (uid 1000 inside
the container maps back to that user). Anything with code-server shell
access can read those. `.ssh` is `:ro` on purpose — no worse than what
the invoking user already has. Each path is a setting, so a test or a
shared host can point them at a throwaway directory instead of the real
`~/.ssh`. On a fresh host they may not be usable until you populate them:
`install.sh` creates what is missing, seeds the git identity and warns
about the rest (no SSH private key, dangling symlinks in the bin dir).

`~/.gitconfig` lands at **`/etc/gitconfig`** inside the container, not at
`/home/coder/.gitconfig`. Two reasons, both found the hard way: the ACP
panel's pi runs with `HOME` re-pointed at the pi state volume, so a
`~/.gitconfig` was invisible to it and the panel committed as nobody while
the terminal committed as you; and a read-only single-file bind over
`~/.gitconfig` made `git config --global ...` — the exact command git's own
error message tells you to run — fail with `Device or resource busy`. At the
system path the identity applies whatever `HOME` is, and `~/.gitconfig`
stays an ordinary writable file that overrides it.

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
