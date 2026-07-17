#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die() {
    printf '04-production-hardening.sh: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || die 'must run as root'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
    || die 'cannot resolve setup directory'
DSV4_REPO=${DSV4_REPO:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}
[[ -d $DSV4_REPO && $DSV4_REPO == /* ]] || die "invalid DSV4_REPO: $DSV4_REPO"

for command_name in getent groupadd id useradd install chown chmod gpasswd stat; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
REPO_OWNER=$(stat -c %U -- "$DSV4_REPO") || die "cannot determine owner of DSV4_REPO: $DSV4_REPO"
[[ $REPO_OWNER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid repository owner: $REPO_OWNER"

if ! getent group dsv4auth >/dev/null; then
    groupadd --system dsv4auth
    printf 'Created system group dsv4auth.\n'
else
    printf 'System group dsv4auth already exists.\n'
fi

if ! id -u dsv4auth >/dev/null 2>&1; then
    useradd --system --gid dsv4auth --home-dir /nonexistent --no-create-home \
        --shell /usr/sbin/nologin dsv4auth
    printf 'Created no-login system user dsv4auth without a home directory.\n'
else
    printf 'System user dsv4auth already exists.\n'
fi

install -d -o root -g dsv4auth -m 0750 /etc/deepseek-v4-flash
if [[ -e /etc/deepseek-v4-flash/api-key ]]; then
    [[ ! -L /etc/deepseek-v4-flash/api-key ]] || die 'refusing symlink API key'
    [[ -f /etc/deepseek-v4-flash/api-key ]] || die 'API key is not a regular file'
    chown root:dsv4auth /etc/deepseek-v4-flash/api-key
    chmod 0640 /etc/deepseek-v4-flash/api-key
    printf 'Restricted the production API key to root:dsv4auth mode 0640.\n'
else
    printf 'Production API key is not present yet; the installer will create it as root:dsv4auth mode 0640.\n'
fi

# Repository ACLs already grant dsv4 read access; the repository owner operates dsv4 only
# through the scoped sudoers rule and does not need dsv4 group membership.
gpasswd -d "$REPO_OWNER" dsv4 || true
printf 'Ensured %s is not a member of the dsv4 group.\n' "$REPO_OWNER"
