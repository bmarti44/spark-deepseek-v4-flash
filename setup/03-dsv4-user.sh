#!/usr/bin/env bash
# STEP 3 — run when convenient (needed before Candidate A/B installs begin):
#   sudo bash ~/sudo-step3-dsv4-user.sh
#
# Sets up the isolation + service plumbing the plan requires:
#  1. Dedicated unprivileged user `dsv4` — all community inference code
#     (ds4-on-spark, llama.cpp) is built and run as this user, which has no
#     access to your SSH/GitHub/HuggingFace credentials.
#  2. Lets the owner of DSV4_REPO run commands as dsv4 WITHOUT a password (scoped sudoers
#     rule — only "run as dsv4", nothing else), so Claude can drive
#     build/serve/bench cycles unattended.
#  3. Adds that repository owner to the dsv4 group (read access to build outputs).
#  4. /run/dsv4 runtime dir (inference lock lives here), recreated each boot.
#  5. /etc/deepseek-v4-flash config dir (API key lands here later, 0750).
#  6. Stops + disables ollama.service for the project duration (frees memory;
#     re-enable later with: sudo systemctl enable --now ollama).
#  7. Activates the repository's tracked secret-scanning Git hooks.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DSV4_REPO=${DSV4_REPO:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}
[[ -d $DSV4_REPO && $DSV4_REPO == /* ]] || { printf 'invalid DSV4_REPO: %s\n' "$DSV4_REPO" >&2; exit 1; }
REPO_OWNER=$(stat -c %U -- "$DSV4_REPO")
[[ $REPO_OWNER =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid repository owner: %s\n' "$REPO_OWNER" >&2; exit 1; }

# 1. user
if ! id dsv4 >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /home/dsv4 --shell /bin/bash dsv4
fi

# 2. scoped passwordless run-as
printf '%s ALL=(dsv4) NOPASSWD: ALL\n' "$REPO_OWNER" > /etc/sudoers.d/dsv4-delegate
chmod 440 /etc/sudoers.d/dsv4-delegate
visudo -c -f /etc/sudoers.d/dsv4-delegate

# 3. group access
usermod -aG dsv4 "$REPO_OWNER"

# 4. runtime dir (persistent across boots via tmpfiles.d)
cat > /etc/tmpfiles.d/dsv4.conf <<'EOF'
d /run/dsv4 0770 dsv4 dsv4 -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/dsv4.conf

# 5. config dir
install -d -m 0750 -o root -g dsv4 /etc/deepseek-v4-flash

# 6. ollama off for project duration
systemctl disable --now ollama.service || true

# 7. repository hooks
git -C "$DSV4_REPO" config core.hooksPath .githooks
echo "Configured core.hooksPath=.githooks in $DSV4_REPO."

echo "OK: dsv4 user, delegation, runtime/config dirs, and Git hooks ready; ollama disabled."
