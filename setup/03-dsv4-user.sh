#!/usr/bin/env bash
# STEP 3 — run when convenient (needed before Candidate A/B installs begin):
#   sudo bash ~/sudo-step3-dsv4-user.sh
#
# Sets up the isolation + service plumbing the plan requires:
#  1. Dedicated unprivileged user `dsv4` — all community inference code
#     (ds4-on-spark, llama.cpp) is built and run as this user, which has no
#     access to your SSH/GitHub/HuggingFace credentials.
#  2. Lets bmarti44 run commands as dsv4 WITHOUT a password (scoped sudoers
#     rule — only "run as dsv4", nothing else), so Claude can drive
#     build/serve/bench cycles unattended.
#  3. Adds bmarti44 to the dsv4 group (read access to build outputs).
#  4. /run/dsv4 runtime dir (inference lock lives here), recreated each boot.
#  5. /etc/deepseek-v4-flash config dir (API key lands here later, 0750).
#  6. Stops + disables ollama.service for the project duration (frees memory;
#     re-enable later with: sudo systemctl enable --now ollama).
set -euo pipefail

# 1. user
if ! id dsv4 >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /home/dsv4 --shell /bin/bash dsv4
fi

# 2. scoped passwordless run-as
cat > /etc/sudoers.d/dsv4-delegate <<'EOF'
bmarti44 ALL=(dsv4) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/dsv4-delegate
visudo -c -f /etc/sudoers.d/dsv4-delegate

# 3. group access
usermod -aG dsv4 bmarti44

# 4. runtime dir (persistent across boots via tmpfiles.d)
cat > /etc/tmpfiles.d/dsv4.conf <<'EOF'
d /run/dsv4 0770 dsv4 dsv4 -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/dsv4.conf

# 5. config dir
install -d -m 0750 -o root -g dsv4 /etc/deepseek-v4-flash

# 6. ollama off for project duration
systemctl disable --now ollama.service || true

echo "OK: dsv4 user, delegation, /run/dsv4, /etc/deepseek-v4-flash ready; ollama disabled."
