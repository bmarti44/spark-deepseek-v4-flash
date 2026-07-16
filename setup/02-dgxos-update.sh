#!/usr/bin/env bash
# STEP 2 — run ONLY after Claude confirms the repo is scaffolded, verified,
# and pushed to GitHub:  sudo bash ~/sudo-step2-dgxos-update.sh
#
# Updates DGX OS packages to the current release (GPU driver 580.159.03 —
# NVIDIA release notes: "enhances Out-of-Memory (OOM) handling with GB10's
# unified memory architecture"), then reboots.
# Firmware/EC/UEFI are NOT touched by this (apt package updates only).
#
# The reboot ends the Claude Code session. Afterwards: relaunch claude and
# say "continue" — state persists in ~/spark-deepseek-v4-flash, the plan
# file, and Claude's memory.
set -euo pipefail

apt-get update
apt-get full-upgrade -y

echo ""
echo "Update complete. Rebooting in 15 seconds — Ctrl-C to abort."
sleep 15
reboot
