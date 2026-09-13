#!/usr/bin/env bash
# scripts/show-password.sh: print the code-server login password.
#
#   scripts/show-password.sh                 prints it (with a newline on a terminal)
#   scripts/show-password.sh | curl ... --data-urlencode password@- ...
#
# The password lives in the podman secret code-server-config (a YAML config file that
# code-server reads through $CODE_SERVER_CONFIG). Piped, it is printed without a trailing
# newline, so it can feed curl's @- as is. Rotate it with scripts/install.sh --rotate-password.
set -euo pipefail

yaml=$(podman secret inspect --showsecret --format '{{.SecretData}}' code-server-config 2>/dev/null) \
  || { echo "show-password: no podman secret code-server-config (run scripts/install.sh)" >&2; exit 1; }
line=''
while IFS= read -r l; do
  if [[ $l == 'password: '* ]]; then line=${l#password: }; break; fi
done <<<"$yaml"
if [[ ${#line} -lt 2 || $line != \"*\" ]]; then
  echo "show-password: no quoted 'password:' line in code-server-config" >&2
  exit 1
fi
# undo the \\ and \" escapes install.sh wrote
s=${line:1:${#line}-2} out='' i=0
while ((i < ${#s})); do
  c=${s:i:1}
  if [[ $c == "\\" ]]; then i=$((i + 1)); c=${s:i:1}; fi
  out+=$c
  i=$((i + 1))
done
if [[ -t 1 ]]; then printf '%s\n' "$out"; else printf '%s' "$out"; fi
