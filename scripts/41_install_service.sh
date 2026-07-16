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
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
SYSTEMD_DIR=$REPO_ROOT/configs/systemd
KEY_DIR=/etc/deepseek-v4-flash
KEY_FILE=$KEY_DIR/api-key
KEY_PREV=$KEY_DIR/api-key.prev
AUTH_HEADER=$KEY_DIR/auth-header
ENV_FILE=$KEY_DIR/env
CADDY_DROPIN_DIR=/etc/systemd/system/dsv4-caddy.service.d
CADDY_DROPIN=$CADDY_DROPIN_DIR/upstream.conf

for command_name in install openssl chown chmod mv systemctl getent id curl ss tailscale python3; do
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

install -o root -g dsv4auth -m 0640 /dev/null "$ENV_FILE"
printf 'API_KEY_FILE=%s\nSTACK=%s\n' "$KEY_FILE" "$stack" >"$ENV_FILE"

if [[ $stack == ds4 ]]; then
    engine_unit=deepseek-v4-flash-ds4.service
    other=llamacpp
    upstream_port=8012
else
    engine_unit=deepseek-v4-flash-llamacpp.service
    other=ds4
    upstream_port=8011
fi

[[ -x /usr/bin/caddy ]] || die '/usr/bin/caddy is missing; the orchestrator must install the apt package first'
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

install -o root -g root -m 0644 "$SYSTEMD_DIR/$engine_unit" /etc/systemd/system/
install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-authhelper.service" /etc/systemd/system/
install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-caddy.service" /etc/systemd/system/
install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-guard.service" /etc/systemd/system/
install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-guard.timer" /etc/systemd/system/
install -D -o root -g root -m 0644 "$REPO_ROOT/configs/caddy/Caddyfile" /etc/caddy/Caddyfile
install -D -o root -g root -m 0755 "$REPO_ROOT/scripts/40_auth_helper.py" \
    /usr/local/lib/deepseek-v4-flash/40_auth_helper.py
install -d -o root -g root -m 0755 "$CADDY_DROPIN_DIR"
install -o root -g root -m 0644 /dev/null "$CADDY_DROPIN"
printf '[Service]\nEnvironment=DSV4_UPSTREAM_PORT=%s\n' "$upstream_port" >"$CADDY_DROPIN"

DSV4_UPSTREAM_PORT=$upstream_port /usr/bin/caddy validate --config /etc/caddy/Caddyfile \
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
if grep -Eq '(^|[^0-9])(8011|8012)([^0-9]|$)' <<<"$tailscale_status"; then
    die 'DANGER: tailscale serve routes directly to engine port 8011/8012 and bypasses authentication; remove that route'
fi
(( tailscale_rc == 0 )) || printf 'WARNING: tailscale serve status exited %d; no direct engine port was reported.\n' "$tailscale_rc" >&2

printf 'Post-install verification passed: auth, models endpoint, loopback binds, and Tailscale route safety.\n'

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
