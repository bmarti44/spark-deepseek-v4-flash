#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SERVICE_USER=dsv4auth
AUTH_HEADER=/etc/deepseek-v4-flash/auth-header
LOCAL_URL=http://127.0.0.1:8010/v1/models

safe_log() {
    printf '42_verify_exposure.sh: %s\n' "$*" >&2
}

die() {
    safe_log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'EOF' >&2
Usage: scripts/42_verify_exposure.sh [--service-user USER] [--auth-header PATH]

Re-verify the local authentication endpoint and Tailscale Serve/Funnel routes.
The authenticated probe runs only as root, which delegates key-file access to
the configured service user. A non-root run skips that probe with a loud note.
EOF
    exit 2
}

while (( $# > 0 )); do
    case $1 in
        --service-user)
            (( $# >= 2 )) || usage
            SERVICE_USER=$2
            shift 2
            ;;
        --auth-header)
            (( $# >= 2 )) || usage
            AUTH_HEADER=$2
            shift 2
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[[ $SERVICE_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
    || die "invalid service user: $SERVICE_USER"
[[ $AUTH_HEADER == /* ]] || die 'auth-header path must be absolute'

for command_name in curl grep python3 tailscale; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command not found: $command_name"
done

unauth_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
    "$LOCAL_URL" || true)
[[ $unauth_code == 401 ]] \
    || die "unauthenticated local probe expected 401, got ${unauth_code:-curl-error}"
safe_log 'PASS local unauthenticated request returned 401'

if (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 || die 'required command not found: runuser'
    id -u "$SERVICE_USER" >/dev/null 2>&1 \
        || die "service user does not exist: $SERVICE_USER"
    [[ -f $AUTH_HEADER && ! -L $AUTH_HEADER ]] \
        || die "auth header is missing, non-regular, or a symlink: $AUTH_HEADER"
    auth_code=$(runuser -u "$SERVICE_USER" -- \
        curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
        -H "@$AUTH_HEADER" "$LOCAL_URL" || true)
    [[ $auth_code == 200 ]] \
        || die "service-user authenticated probe expected 200, got ${auth_code:-curl-error}"
    safe_log "PASS authenticated request returned 200 with key material read by $SERVICE_USER"
else
    safe_log "LOUD NOTE: not root; authenticated 200 probe skipped because key access must be delegated to $SERVICE_USER"
fi

set +e
tailscale_status=$(tailscale serve status 2>&1)
tailscale_rc=$?
set -e
printf '%s\n' "$tailscale_status"
(( tailscale_rc == 0 )) \
    || die "tailscale serve status exited $tailscale_rc; exposure is unverified"
python3 - "$tailscale_status" <<'PY' \
    || die 'Tailscale Serve status is unparseable or contains an unsafe route'
import re
import sys
from urllib.parse import urlsplit

status = sys.argv[1]
if re.search(r"(^|[^0-9])(8011|8012|8013|8014)([^0-9]|$)", status):
    raise SystemExit(1)
if re.search(r"no (serve )?config", status, re.IGNORECASE):
    raise SystemExit(0)
targets = re.findall(r"\bproxy\s+(\S+)", status, re.IGNORECASE)
if not targets:
    raise SystemExit(1)
for target in targets:
    parsed = urlsplit(target)
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.port != 8010
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise SystemExit(1)
PY
safe_log 'PASS every Tailscale Serve route targets http://127.0.0.1:8010 only'

set +e
funnel_status=$(tailscale funnel status 2>&1)
funnel_rc=$?
set -e
printf '%s\n' "$funnel_status"
(( funnel_rc == 0 )) \
    || die "tailscale funnel status exited $funnel_rc; cannot prove Funnel is off"
grep -Eiq 'no (serve|funnel) config' <<<"$funnel_status" \
    || die 'Tailscale Funnel is configured; disable it before exposing this service'
safe_log 'PASS Tailscale Funnel is off; exposure-chain verification complete'
