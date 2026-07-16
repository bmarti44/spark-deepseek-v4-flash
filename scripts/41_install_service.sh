#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    printf 'Usage: %s <ds4|llamacpp>\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf '41_install_service.sh: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || die 'must run as root'
(( $# == 1 )) || usage
stack=$1
[[ $stack == ds4 || $stack == llamacpp ]] || usage

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
SYSTEMD_DIR=$REPO_ROOT/configs/systemd
KEY_DIR=/etc/deepseek-v4-flash
KEY_FILE=$KEY_DIR/api-key
ENV_FILE=$KEY_DIR/env

for command_name in install openssl chown chmod systemctl getent id; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
getent group dsv4 >/dev/null || die 'required group does not exist: dsv4'
id -u dsv4 >/dev/null 2>&1 || die 'required user does not exist: dsv4'

install -d -o root -g dsv4 -m 0750 "$KEY_DIR"
if [[ -L $KEY_FILE ]]; then
    die "refusing symlink API key: $KEY_FILE"
fi
if [[ ! -e $KEY_FILE ]]; then
    openssl rand -hex 32 >"$KEY_FILE"
fi
[[ -f $KEY_FILE ]] || die "API key is not a regular file: $KEY_FILE"
chown root:dsv4 "$KEY_FILE"
chmod 0640 "$KEY_FILE"

install -o root -g dsv4 -m 0640 /dev/null "$ENV_FILE"
printf 'API_KEY_FILE=%s\n' "$KEY_FILE" >"$ENV_FILE"

if [[ $stack == ds4 ]]; then
    [[ -x /usr/bin/caddy ]] || die '/usr/bin/caddy is missing; the orchestrator must install the apt package first'
    for source in \
        "$SYSTEMD_DIR/deepseek-v4-flash-ds4.service" \
        "$SYSTEMD_DIR/dsv4-authhelper.service" \
        "$SYSTEMD_DIR/dsv4-caddy.service" \
        "$REPO_ROOT/configs/caddy/Caddyfile" \
        "$REPO_ROOT/scripts/40_auth_helper.py"; do
        [[ -f $source ]] || die "missing production artifact: $source"
    done
    install -o root -g root -m 0644 "$SYSTEMD_DIR/deepseek-v4-flash-ds4.service" /etc/systemd/system/
    install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-authhelper.service" /etc/systemd/system/
    install -o root -g root -m 0644 "$SYSTEMD_DIR/dsv4-caddy.service" /etc/systemd/system/
    install -D -o root -g root -m 0644 "$REPO_ROOT/configs/caddy/Caddyfile" /etc/caddy/Caddyfile
    /usr/bin/caddy validate --config /etc/caddy/Caddyfile || die 'Caddyfile failed validation'
    install -D -o root -g root -m 0755 "$REPO_ROOT/scripts/40_auth_helper.py" \
        /usr/local/lib/deepseek-v4-flash/40_auth_helper.py

    systemctl daemon-reload
    # The apt package supplies the binary, but its generic unit must not expose
    # a second listener or compete with the hardened dsv4-caddy.service.
    if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        systemctl disable --now caddy.service
    fi
    systemctl enable deepseek-v4-flash-ds4.service dsv4-authhelper.service dsv4-caddy.service
    systemctl start dsv4-authhelper.service
    systemctl start deepseek-v4-flash-ds4.service
    systemctl start dsv4-caddy.service

    cat <<'EOF'
Installed ds4 production services. Verification commands:
  systemctl status deepseek-v4-flash-ds4.service dsv4-authhelper.service dsv4-caddy.service
  curl -i http://127.0.0.1:8010/v1/models
  KEY=$(cat /etc/deepseek-v4-flash/api-key); curl -i -H "Authorization: Bearer $KEY" http://127.0.0.1:8010/v1/models
  tailscale serve status
EOF
else
    unit=$SYSTEMD_DIR/deepseek-v4-flash-llamacpp.service
    [[ -f $unit ]] || die "missing production artifact: $unit"
    install -o root -g root -m 0644 "$unit" /etc/systemd/system/

    systemctl daemon-reload
    systemctl enable deepseek-v4-flash-llamacpp.service
    systemctl start deepseek-v4-flash-llamacpp.service

    cat <<'EOF'
Installed llama.cpp production service. Verification commands:
  systemctl status deepseek-v4-flash-llamacpp.service
  curl -i http://127.0.0.1:8011/health
  KEY=$(cat /etc/deepseek-v4-flash/api-key); curl -i -H "Authorization: Bearer $KEY" http://127.0.0.1:8011/v1/models
  tailscale serve status

Clients must replace the gate-phase key with this NEW production key.
EOF
fi
