RCLONE_SERVICE_FILE="/etc/systemd/system/rclone@.service"

apt update
apt upgrade -y
apt install rclone -y

mkdir -p /root/.config/rclone/
mkdir -p /root/.cache/rclone
mkdir -p /mnt/gdrive/common
mkdir -p /mnt/gdrive/${HOSTNAME}

curl -H "Authorization: token ${GITHUB_TOKEN}" -fsSL https://raw.githubusercontent.com/nikolaos83/secrets/refs/heads/main/rclone.conf -o /root/.config/rclone/rclone.conf || echo "Failed to fetch rclone.conf"

cat > /usr/local/bin/rclone-mount.sh << 'EOF'
#!/bin/bash
set -euo pipefail

REMOTE=${1:?remote required}
INSTANCE=${2:?instance required}
CONFIG=/root/.config/rclone/rclone.conf

# Check rclone config exists
if [ ! -f "$CONFIG" ]; then
    echo "[ERROR] rclone config not found at $CONFIG"
    exit 1
fi

# Determine mount point and remote path
# Determine mount point and remote path
if [ "$INSTANCE" = "backups" ]; then
    MOUNT_POINT=/mnt/backups
    REMOTE_PATH=$REMOTE:/backups
elif [ "$INSTANCE" = "hosts" ]; then
    MOUNT_POINT=/mnt/hosts/
    REMOTE_PATH=$REMOTE:/hosts/
fi

mkdir -p "$MOUNT_POINT"

echo "[INFO] Mounting $REMOTE_PATH → $MOUNT_POINT"
logger -t rclone "[INFO] Mounting $REMOTE_PATH → $MOUNT_POINT"

# Pre-check remote availability
if ! /usr/bin/rclone lsd "$REMOTE_PATH" --config="$CONFIG" &>/dev/null; then
    echo "[WARN] Remote $REMOTE_PATH not accessible"
    logger -t rclone "[WARN] Remote $REMOTE_PATH not accessible"
fi

# Mount rclone
exec /usr/bin/rclone mount \
    "$REMOTE_PATH" "$MOUNT_POINT" \
    --config="$CONFIG" \
    --allow-other \
    --dir-cache-time=72h \
    --poll-interval=15s \
    --log-file=/var/log/rclone-$INSTANCE.log \
    --umask=002 \
    --log-level=INFO \
    --read-only
EOF

chmod +x /usr/local/bin/rclone-mount.sh

cat > "$RCLONE_SERVICE_FILE" << 'EOF'
[Unit]
Description=Rclone Mount (%i)
Documentation=https://rclone.org/docs/
After=network-online.target
Wants=network-online.target
Requires=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rclone-mount.sh gdrive %i
ExecStop=/bin/bash -c '$(which fusermount) -uz /mnt/%i || echo "[WARN] Unmount failed for /mnt/%i"'
Restart=on-failure
RestartSec=10
TimeoutSec=60
StartLimitBurst=3
#StartLimitIntervalSec=60
# Optional: notify systemd that the service is ready
# NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl start rclone@backups
systemctl start rclone@hosts

systemctl enable rclone@backups
systemctl enable rclone@hosts

journalctl -u rclone@backups -f
journalctl -u rclone@hosts -f
