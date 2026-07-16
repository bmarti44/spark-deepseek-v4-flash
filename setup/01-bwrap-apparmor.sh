#!/usr/bin/env bash
# STEP 1 — run now:  sudo bash ~/sudo-step1-bwrap-apparmor.sh
#
# Allows bubblewrap (Codex CLI's sandbox) to create user namespaces on
# Ubuntu 24.04 via a TARGETED AppArmor profile, instead of disabling the
# global kernel.apparmor_restrict_unprivileged_userns protection.
# Persists across reboots. Reversible: sudo rm /etc/apparmor.d/bwrap &&
# sudo apparmor_parser -R /etc/apparmor.d/bwrap (before removing the file).
set -euo pipefail

cat > /etc/apparmor.d/bwrap <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF

apparmor_parser -r /etc/apparmor.d/bwrap
echo "OK: bwrap AppArmor profile installed and loaded."
