# Woow code-server — browser IDE with the pi coding agent + ACP client wired in.
#
# Starts from the upstream codercom/code-server image (Debian slim, Node 18 baked
# in) and adds:
#   - Node 22.x from nodesource. code-server ships with a bundled Node used
#     only for the IDE process itself; the pi CLI runs as a subprocess and
#     needs a >=22 runtime, so we install a system Node next to the bundled one.
#   - Python 3, git, openssh-client, curl, jq — the "what you always end up
#     apt-get installing on the first day" minimum set for a dev sandbox.
#   - @earendil-works/pi-coding-agent (pi CLI, pinned to the same version the
#     sibling Woow_podman_pi_agent_package deployment uses so a session started
#     under pi-web is readable here and vice versa).
#   - pi-acp: the community bridge that translates ACP JSON-RPC (what the ACP
#     Client VS Code extension speaks) to pi's own `--mode rpc` protocol.
#   - The ACP Client extension itself, from open-vsx (code-server's default
#     registry — the Microsoft Marketplace ToS forbids code-server users).
#
# The pi-code wrapper in rootfs/ scopes HOME to /data/pi-agent/home for the
# pi subprocess only, without moving code-server's own HOME. That is what
# makes the sibling deployment's sessions/skills/models visible here.

ARG CODE_SERVER_VERSION=4.135.0
FROM codercom/code-server:${CODE_SERVER_VERSION}

# All apt / npm / extension work runs as root; the ENTRYPOINT drops back to
# coder before starting code-server.
USER root

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Taipei \
    PI_TELEMETRY=0 \
    PI_SKIP_VERSION_CHECK=1

# --- System packages -----------------------------------------------------
# Node 22 lives at /usr/bin/node after this block; code-server's bundled
# Node stays where it was, so the IDE itself is unaffected by the version
# bump. `git` + `openssh-client` are what makes the workspace usable at
# all — clone, commit, push. Python 3 covers script tooling users install
# via pip in the terminal.
#
# nodesource distributes their apt keyring separately from the repo
# definition; installing them together is the standard pattern documented
# by nodesource itself. We use apt over the "one-liner install script" so
# there is exactly one place that decides which repo we trust.
# Python 3 minimal only — Debian Trixie's python3-pip / python3-venv
# metadeps deadlock under --no-install-recommends inside this base. Users
# who need pip can `apt install python3-pip` at runtime (sudo works via
# SUDO_PASSWORD) or, better, install `pipx` per-user. Keeping this RUN
# minimal keeps the image reproducible.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq openssh-client \
      python3-minimal \
      tzdata \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- pi CLI + ACP adapter ------------------------------------------------
# pi is pinned to 0.83.0 to match Woow_podman_pi_agent_package v0.13.2 —
# the two must agree on session/skill/model schema because both write to
# the shared pi-agent-data volume. Bump both together.
#
# pi-acp is on 0.0.33 (current head; the package is 0.0.x, expect churn).
# It spawns `pi --mode rpc` internally and bridges to ACP JSON-RPC over
# stdio, which is what the ACP Client extension consumes.
ARG PI_CODING_AGENT_VERSION=0.83.0
ARG PI_ACP_VERSION=0.0.33
RUN npm install -g --omit=dev --no-fund --no-audit \
      "@earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION}" \
      "pi-acp@${PI_ACP_VERSION}" \
 && test "$(pi --version)" = "${PI_CODING_AGENT_VERSION}"

# --- Rootfs overlay ------------------------------------------------------
# Contains:
#   - /usr/local/bin/pi-code — the HOME-scoping wrapper used as the ACP
#     command in settings.json. Everything about how OD reaches pi-agent
#     on 197 collapses to this one wrapper.
#   - /etc/skel/.local/share/code-server/User/settings.json — first-boot
#     default VS Code settings pre-wiring the ACP Client extension to
#     the pi adapter. code-server copies /etc/skel into the coder user's
#     $HOME on first run.
COPY rootfs/ /
RUN chmod +x /usr/local/bin/pi-code

# --- ACP Client extension ------------------------------------------------
# Pinned version so a background upstream refresh cannot silently change
# the sidebar behaviour or the settings.json schema out from under a
# working deployment. Bump manually after verifying a new release.
#
# code-server hardcodes the OpenVSX registry — the Microsoft Marketplace
# ToS explicitly forbids third-party clients, so the environment overrides
# below are the correct-and-only way to fetch extensions from a public
# source in this image. Do NOT swap for marketplace.visualstudio.com.
ARG ACP_CLIENT_VERSION=0.2.0
USER coder
RUN SERVICE_URL=https://open-vsx.org/vscode/gallery \
    ITEM_URL=https://open-vsx.org/vscode/item \
    code-server --install-extension "formulahendry.acp-client@${ACP_CLIENT_VERSION}"

# Copy the pre-wired settings.json into the coder user's config dir. It
# gets set up by /etc/skel on a fresh $HOME, but users who mount their
# host $HOME as /home/coder skip /etc/skel entirely, so we also install
# it directly here. First-boot with an empty settings.json wins; a
# non-empty file is left alone (documented behaviour of code-server).
USER root
RUN mkdir -p /home/coder/.local/share/code-server/User \
 && cp /etc/skel/.local/share/code-server/User/settings.json \
       /home/coder/.local/share/code-server/User/settings.json \
 && chown -R coder:coder /home/coder/.local

# code-server's own ENTRYPOINT expects to run as coder.
USER coder

# --- Healthcheck ---------------------------------------------------------
# code-server exposes /healthz on its internal port (8080). Pointing at
# 127.0.0.1 inside the container is the correct target — the host publish
# maps 8443:8080 externally, but internally the server always binds 8080.
# The systemd timer in ../systemd/code-server-health.timer just re-triggers
# this check every 30s so `podman ps` STATUS is fresh between the built-in
# interval ticks.
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -sf http://127.0.0.1:8080/healthz || exit 1

# --- OCI labels ----------------------------------------------------------
ARG BUILD_VERSION=dev
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="Woow Podman code-server" \
      org.opencontainers.image.description="code-server + pi coding agent + ACP client, rootless-podman-friendly, sibling of Woow_podman_pi_agent_package" \
      org.opencontainers.image.source="https://github.com/WOOWTECH/Woow_podman_code_server_package" \
      org.opencontainers.image.vendor="WOOWTECH" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}"
