#!/bin/bash
set -e

echo "[*] Adding 1G swap..."
fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo "[*] Limiting journald memory usage..."
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/limits.conf <<EOF
[Journal]
Storage=volatile
SystemMaxUse=16M
RuntimeMaxUse=16M
EOF
systemctl restart systemd-journald

echo "[*] Disabling apt-daily timers..."
systemctl disable --now apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service

echo "[*] Purging unneeded packages..."
apt purge -y unattended-upgrades rsyslog man-db || true
apt autoremove -y
apt clean

echo "[*] Disabling extra TTYs..."
for n in 2 3 4 5 6; do
    systemctl disable getty@tty$n.service 2>/dev/null || true
done

echo "[*] Disabling systemd-networkd if unused..."
if ! systemctl is-active --quiet systemd-networkd; then
    systemctl disable --now systemd-networkd 2>/dev/null || true
fi

echo "[*] All done. Current memory usage:"
free -h
