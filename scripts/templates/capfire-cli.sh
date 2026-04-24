#!/usr/bin/env bash
#
# Capfire admin CLI wrapper — installed at /usr/local/bin/capfire by
# scripts/install-server.sh.
#
# Re-invokes `bin/capfire` as the service user inside a login shell so
# RVM/rbenv/asdf auto-load and `bundle` resolves correctly. Works the same
# whether you invoke it from any user's shell (sudo prompts for password
# if needed).
#
# Override paths via env if your layout differs:
#   CAPFIRE_HOME=/custom/path  capfire tokens list
#   CAPFIRE_USER=deploy        capfire tokens list
set -euo pipefail

CAPFIRE_HOME="${CAPFIRE_HOME:-__CAPFIRE_HOME__}"
CAPFIRE_USER="${CAPFIRE_USER:-__CAPFIRE_USER__}"

# Escape user-provided args so they survive the child shell invocation.
ARGS="$(printf '%q ' "$@")"

# -H  → HOME=/home/$CAPFIRE_USER  (RVM/asdf look for config there)
# -lc → login shell → sources ~/.bash_profile → loads the Ruby manager
exec sudo -H -u "$CAPFIRE_USER" bash -lc "
  cd '$CAPFIRE_HOME'
  set -a
  [[ -r /etc/capfire/env ]] && . /etc/capfire/env
  set +a
  bundle exec bin/capfire $ARGS
"
