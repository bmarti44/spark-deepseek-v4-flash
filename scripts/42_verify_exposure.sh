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

# Tailscale Serve forwards the original tailnet Host, not 127.0.0.1:8010. A
# host-specific Caddy site matcher would drop those requests to Caddy's empty
# default handler (HTTP 200, no auth) instead of the auth proxy. Probe with a
# non-loopback Host: it must still be challenged with 401.
proxied_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
    -H 'Host: tailnet-host.example.ts.net' "$LOCAL_URL" || true)
[[ $proxied_code == 401 ]] \
    || die "forwarded-Host unauthenticated probe expected 401, got ${proxied_code:-curl-error} (Caddy site matcher likely too specific; the tailnet path would bypass the auth proxy)"
safe_log 'PASS forwarded-Host unauthenticated request returned 401'

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

# Funnel state must come from the authoritative serve config, not funnel-status
# text: with Serve enabled, `tailscale funnel status` prints the tailnet-only
# serve routes (no "no config" line), which naive text matching misreads as
# Funnel being on. AllowFunnel is empty/absent exactly when Funnel is off.
set +e
serve_json=$(tailscale serve status --json 2>&1)
serve_rc=$?
set -e
(( serve_rc == 0 )) \
    || die "tailscale serve status --json exited $serve_rc; cannot prove Funnel is off"
python3 - "$serve_json" <<'PY' \
    || die 'Tailscale Funnel is enabled; disable it (tailscale funnel reset) before exposing this service'
import json
import sys

try:
    document = json.loads(sys.argv[1])
except (ValueError, IndexError):
    raise SystemExit(1)


def any_funnel(config):
    # Tailscale ServeConfig.IsFunnelOn is recursive: Funnel can be enabled at the
    # top level OR inside any Foreground session config. Checking only top-level
    # AllowFunnel misses a `tailscale funnel` run held open in a foreground shell.
    if not isinstance(config, dict):
        return False
    if any((config.get("AllowFunnel") or {}).values()):
        return True
    foreground = config.get("Foreground") or {}
    if isinstance(foreground, dict):
        return any(any_funnel(session) for session in foreground.values())
    return False


raise SystemExit(1 if any_funnel(document) else 0)
PY
safe_log 'PASS Tailscale Funnel is off; exposure-chain verification complete'
