#!/usr/bin/env bash
# Install standard Ubuntu security update services, without BSP dist-upgrades.
set -Eeuo pipefail
if [[ "${1:-}" == "--check" ]]; then
  dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' || exit 1
  [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] || exit 1
  grep -Eq 'APT::Periodic::Unattended-Upgrade "[1-9][0-9]*"' /etc/apt/apt.conf.d/20auto-upgrades || exit 1
  exit 0
fi
if [[ $EUID -ne 0 ]]; then
  echo "Run sudo bash setup-autoupdates.sh (requires root)" >&2
  exit 1
fi
apt-get update
apt-get install -y unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Default Ubuntu unattended-upgrades origin policy handles security updates.
# Do not enable automatic release upgrades or unattended BSP transitions.
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
echo "Ubuntu unattended security updates enabled; NVIDIA BSP release upgrades remain manual."
