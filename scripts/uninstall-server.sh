#!/usr/bin/env bash
#
# Capfire server uninstaller.
#
# Stops and removes the systemd unit + the admin CLI symlink. Optionally wipes
# /opt/capfire and /etc/capfire too (destructive — gated behind --purge).
# Never touches the database or the apps root: both can hold user data.
#
# Usage:
#   sudo ./scripts/uninstall-server.sh
#   sudo ./scripts/uninstall-server.sh --purge
#
# Options:
#   --purge      Also remove /opt/capfire and /etc/capfire/env
#   --dir DIR    Install prefix (default: /opt/capfire)
#   -h, --help   Show this help

set -euo pipefail

CAPFIRE_HOME="/opt/capfire"
PURGE=false

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=true; shift ;;
    --dir)   CAPFIRE_HOME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }

echo "› stopping and disabling capfire.service"
systemctl stop capfire.service 2>/dev/null || true
systemctl disable capfire.service 2>/dev/null || true
rm -f /etc/systemd/system/capfire.service
systemctl daemon-reload

echo "› removing /usr/local/bin/capfire symlink"
if [[ -L /usr/local/bin/capfire ]]; then
  rm -f /usr/local/bin/capfire
fi

if [[ "$PURGE" == true ]]; then
  echo "› purging $CAPFIRE_HOME and /etc/capfire"
  rm -rf "$CAPFIRE_HOME" /etc/capfire
  echo "✓ purge complete"
else
  cat <<EOF
✓ service removed.
  The following were intentionally kept — remove them by hand if you need to:
    - $CAPFIRE_HOME   (source, vendored gems)
    - /etc/capfire    (config / JWT secret)
    - \$CAPFIRE_APPS_ROOT (cloned apps)
    - Postgres DB pointed to by DATABASE_URL
  Run again with --purge to blow away $CAPFIRE_HOME and /etc/capfire.
EOF
fi
