# Scope any pi CLI process started from an interactive shell (code-server
# terminal → user types `pi`) at the shared /data/pi-agent volume, so
# provider auth and session history are the same view the ACP chat panel
# and the sibling pi-web addon already see.
#
# Only PI_CODING_AGENT_DIR is set — NOT HOME. Overriding HOME here would
# break code-server itself (extensions, config, .bashrc lookup) since
# /etc/profile.d/*.sh runs for every interactive login shell inside this
# container. PI_CODING_AGENT_DIR is the env pi CLI checks first for its
# state directory, and it takes precedence over ~/.pi when set.
#
# The companion symlink /home/coder/.pi -> /data/pi-agent/home/.pi in the
# Containerfile handles pi versions / code paths that ignore this env and
# fall back to $HOME/.pi.
export PI_CODING_AGENT_DIR=/data/pi-agent
export PI_TELEMETRY=0
export PI_SKIP_VERSION_CHECK=1
