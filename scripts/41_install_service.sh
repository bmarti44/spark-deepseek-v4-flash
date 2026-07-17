#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    printf 'Usage: %s <ds4|llamacpp> [--keep-key]\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf '41_install_service.sh: %s\n' "$*" >&2
    exit 1
}

stack=
keep_key=false
while (( $# > 0 )); do
    case $1 in
        ds4|llamacpp)
            [[ -z $stack ]] || usage
            stack=$1
            ;;
        --keep-key)
            "$keep_key" && usage
            keep_key=true
            ;;
        *) usage ;;
    esac
    shift
done
[[ -n $stack ]] || usage
(( EUID == 0 )) || die 'must run as root'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DSV4_REPO=${DSV4_REPO:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}
[[ $DSV4_REPO =~ ^/[A-Za-z0-9._/+:-]+$ && -d $DSV4_REPO ]] \
    || die "DSV4_REPO must be an existing absolute path using safe path characters: $DSV4_REPO"
REPO_ROOT=$(cd -- "$DSV4_REPO" && pwd -P)
SYSTEMD_DIR=$REPO_ROOT/configs/systemd
KEY_DIR=/etc/deepseek-v4-flash
KEY_FILE=$KEY_DIR/api-key
KEY_PREV=$KEY_DIR/api-key.prev
AUTH_HEADER=$KEY_DIR/auth-header
ENV_FILE=$KEY_DIR/env

for command_name in install openssl chown chmod mv systemctl getent id curl ss tailscale python3 sed grep mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
getent group dsv4 >/dev/null || die 'required group does not exist: dsv4'
getent group dsv4auth >/dev/null || die 'required group does not exist: dsv4auth'
id -u dsv4 >/dev/null 2>&1 || die 'required user does not exist: dsv4'
id -u dsv4auth >/dev/null 2>&1 || die 'required user does not exist: dsv4auth'

install -d -o root -g dsv4auth -m 0750 "$KEY_DIR"
[[ ! -L $KEY_FILE ]] || die "refusing symlink API key: $KEY_FILE"
[[ ! -e $KEY_FILE || -f $KEY_FILE ]] || die "API key is not a regular file: $KEY_FILE"
[[ ! -L $KEY_PREV ]] || die "refusing symlink previous API key: $KEY_PREV"
[[ ! -e $KEY_PREV || -f $KEY_PREV ]] || die "previous API key is not a regular file: $KEY_PREV"

if "$keep_key" && [[ -e $KEY_FILE ]]; then
    printf 'Keeping existing production API key (--keep-key).\n'
else
    if [[ -e $KEY_FILE ]]; then
        install -o root -g root -m 0600 "$KEY_FILE" "$KEY_PREV"
        printf 'Backed up the previous production API key to %s (root-only).\n' "$KEY_PREV"
    fi
    temporary=$KEY_DIR/.api-key.new.$$
    trap 'rm -f -- "$temporary"' EXIT
    openssl rand -hex 32 >"$temporary"
    chown root:dsv4auth "$temporary"
    chmod 0640 "$temporary"
    mv -f -- "$temporary" "$KEY_FILE"
    trap - EXIT
    printf 'Generated a new production API key (default rotation).\n'
fi
chown root:dsv4auth "$KEY_FILE"
chmod 0640 "$KEY_FILE"

[[ ! -L $AUTH_HEADER ]] || die "refusing symlink auth header: $AUTH_HEADER"
[[ ! -e $AUTH_HEADER || -f $AUTH_HEADER ]] || die "auth header is not a regular file: $AUTH_HEADER"
header_temporary=$KEY_DIR/.auth-header.new.$$
trap 'rm -f -- "$header_temporary"' EXIT
printf 'Authorization: Bearer ' >"$header_temporary"
cat -- "$KEY_FILE" >>"$header_temporary"
chown root:dsv4auth "$header_temporary"
chmod 0640 "$header_temporary"
mv -f -- "$header_temporary" "$AUTH_HEADER"
trap - EXIT

if [[ $stack == ds4 ]]; then
    engine_unit=deepseek-v4-flash-ds4.service
    other=llamacpp
    upstream_port=8012
else
    engine_unit=deepseek-v4-flash-llamacpp.service
    other=ds4
    upstream_port=8011
fi

install -o root -g dsv4auth -m 0640 /dev/null "$ENV_FILE"
printf 'API_KEY_FILE=%s\nSTACK=%s\nUPSTREAM_HOST=127.0.0.1\nUPSTREAM_PORT=%s\nLISTEN_PORT=8014\n' \
    "$KEY_FILE" "$stack" "$upstream_port" >"$ENV_FILE"

[[ -x /usr/bin/caddy ]] || die '/usr/bin/caddy is missing; the orchestrator must install the apt package first'
caddy_version=$(/usr/bin/caddy version) || die 'cannot determine installed Caddy version'
[[ ${caddy_version#v} == 2.6.2* ]] \
    || die "unsupported Caddy version $caddy_version; install pinned 2.6.2 package"
for source in \
    "$SYSTEMD_DIR/$engine_unit" \
    "$SYSTEMD_DIR/dsv4-authhelper.service" \
    "$SYSTEMD_DIR/dsv4-caddy.service" \
    "$SYSTEMD_DIR/dsv4-guard.service" \
    "$SYSTEMD_DIR/dsv4-guard.timer" \
    "$REPO_ROOT/configs/caddy/Caddyfile" \
    "$REPO_ROOT/scripts/40_auth_helper.py"; do
    [[ -f $source ]] || die "missing production artifact: $source"
done

install_unit() {
    local source=$1 destination=/etc/systemd/system/${1##*/} temporary
    temporary=$(mktemp)
    sed "s|@DSV4_REPO@|$REPO_ROOT|g" "$source" >"$temporary"
    grep -F '@DSV4_REPO@' "$temporary" >/dev/null \
        && { rm -f -- "$temporary"; die "unexpanded DSV4_REPO placeholder in $source"; }
    install -o root -g root -m 0644 "$temporary" "$destination"
    rm -f -- "$temporary"
}

install_unit "$SYSTEMD_DIR/$engine_unit"
install_unit "$SYSTEMD_DIR/dsv4-authhelper.service"
install_unit "$SYSTEMD_DIR/dsv4-caddy.service"
install_unit "$SYSTEMD_DIR/dsv4-guard.service"
install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-guard.timer" /etc/systemd/system/
install -D -o root -g root -m 0644 "$REPO_ROOT/configs/caddy/Caddyfile" /etc/caddy/Caddyfile
install -D -o root -g root -m 0755 "$REPO_ROOT/scripts/40_auth_helper.py" \
    /usr/local/lib/deepseek-v4-flash/40_auth_helper.py
/usr/bin/caddy validate --config /etc/caddy/Caddyfile \
    || die 'Caddyfile failed validation'

systemctl daemon-reload
# The apt package supplies the binary, but its generic unit must not expose a
# second listener or compete with the hardened dsv4-caddy.service.
systemctl disable --now caddy.service 2>/dev/null || true
systemctl disable --now "deepseek-v4-flash-$other.service" 2>/dev/null || true
systemctl enable "$engine_unit" dsv4-authhelper.service dsv4-caddy.service dsv4-guard.timer
systemctl restart dsv4-authhelper.service
systemctl restart "$engine_unit"
systemctl restart dsv4-caddy.service
systemctl start dsv4-guard.timer

printf 'Waiting up to 600 seconds for authenticated readiness...\n'
deadline=$((SECONDS + 600))
ready=false
while (( SECONDS < deadline )); do
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
        -H "@$AUTH_HEADER" http://127.0.0.1:8010/v1/models || true)
    if [[ $code == 200 ]]; then
        ready=true
        break
    fi
    sleep 2
done
"$ready" || die 'readiness timed out after 600 seconds'

unauth_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
    http://127.0.0.1:8010/v1/models || true)
[[ $unauth_code == 401 ]] \
    || die "post-install auth rejection failed: expected 401, got ${unauth_code:-curl-error}"
auth_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
    -H "@$AUTH_HEADER" http://127.0.0.1:8010/v1/models || true)
[[ $auth_code == 200 ]] \
    || die "post-install authenticated request failed: expected 200, got ${auth_code:-curl-error}"

ss_output=$(ss -H -tlnp) || die 'ss failed during loopback-listener verification'
python3 - "$upstream_port" 3<<<"$ss_output" <<'PY' \
    || die 'ports 8010-8014 are not restricted to the required loopback listeners'
import sys

expected = {8010, int(sys.argv[1]), 8014}
seen = set()
for line in open(3, encoding="utf-8"):
    fields = line.split()
    if len(fields) < 4 or ":" not in fields[3]:
        continue
    address, port_text = fields[3].rsplit(":", 1)
    try:
        port = int(port_text)
    except ValueError:
        continue
    if 8010 <= port <= 8014:
        address = address.strip("[]")
        if address != "127.0.0.1":
            print(f"non-loopback listener: {fields[3]}", file=sys.stderr)
            raise SystemExit(1)
        seen.add(port)
missing = expected - seen
if missing:
    print(f"missing loopback listeners: {sorted(missing)}", file=sys.stderr)
    raise SystemExit(1)
PY

set +e
tailscale_status=$(tailscale serve status 2>&1)
tailscale_rc=$?
set -e
printf '%s\n' "$tailscale_status"
(( tailscale_rc == 0 )) \
    || die "INSTALL FAILED: tailscale serve status exited $tailscale_rc; installation remains unverified and services must not be exposed"
python3 - "$tailscale_status" <<'PY' \
    || die 'INSTALL FAILED: Tailscale Serve routes must proxy to loopback port 8010 only; remove unsafe routes'
import re
import sys
from urllib.parse import urlsplit

status = sys.argv[1]
if re.search(r"(^|[^0-9])(8011|8012)([^0-9]|$)", status):
    raise SystemExit(1)
if re.search(r"no (serve )?config", status, re.IGNORECASE):
    raise SystemExit(0)
targets = re.findall(r"\bproxy\s+(\S+)", status, re.IGNORECASE)
if not targets:
    raise SystemExit(1)
for target in targets:
    parsed = urlsplit(target)
    if parsed.hostname not in {"127.0.0.1", "localhost"} or parsed.port != 8010:
        raise SystemExit(1)
PY

set +e
funnel_status=$(tailscale funnel status 2>&1)
funnel_rc=$?
set -e
printf '%s\n' "$funnel_status"
(( funnel_rc == 0 )) \
    || die "INSTALL FAILED: tailscale funnel status exited $funnel_rc; cannot prove Funnel is disabled"
grep -Eiq 'no (serve|funnel) config' <<<"$funnel_status" \
    || die 'INSTALL FAILED: Tailscale Funnel is configured; disable Funnel before exposing this service'

printf 'Post-install verification passed: Caddy-to-helper-to-engine auth chain, loopback-only engine bind, and Tailscale Serve/Funnel safety.\n'

cat <<EOF
Installed $stack production services behind the authenticated proxy.
Verification commands:
  systemctl status $engine_unit dsv4-authhelper.service dsv4-caddy.service
  curl -i http://127.0.0.1:8010/v1/models
  curl -i -H @/etc/deepseek-v4-flash/auth-header http://127.0.0.1:8010/v1/models
  tailscale serve status

The installer rotates the production key by default. Deliver the current key
to authorized laptops out-of-band; use --keep-key only for intentional reuse.
EOF
