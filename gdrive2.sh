#!/bin/bash

# Create the rclone mount script
cat << 'EOF' > /usr/local/bin/rclone-gdrive.sh
#!/bin/bash
set -euo pipefail

CONFIG="/root/.config/rclone/rclone.conf"
MOUNT_POINT="/mnt/gdrive"
REMOTE_PATH="gdrive:"
TS_IP=$(ip -4 addr show dev tailscale0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Check rclone config exists
if [ ! -f "$CONFIG" ]; then
    echo "[ERROR] rclone config not found at $CONFIG"
    exit 1
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
    --dir-cache-time=240h \
    --poll-interval=1m \
    --log-file=/var/log/rclone-$INSTANCE.log \
    --umask=002 \
    --log-level=INFO \
    --buffer-size=256M \
    --vfs-cache-mode=full \
    --vfs-cache-max-size=4G \
    --vfs-cache-max-age=240h \
    --vfs-read-chunk-size=128M \
    --vfs-read-chunk-size-limit=2G
EOF

# Create the systemd service file
cat << 'EOF' > /etc/systemd/system/rclone@.service
[Unit]
Description=Rclone Mount
Documentation=https://rclone.org/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rclone-gdrive.sh
ExecStop=/bin/bash -c '/usr/bin/fusermount -uz /mnt/gdrive || echo "[WARN] Unmount failed for /mnt/gdrive"'
Restart=on-failure
RestartSec=5
TimeoutSec=60
StartLimitBurst=3
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
EOF

# Make the mount script executable
chmod +x /usr/local/bin/rclone-gdrive.sh

# Reload the systemd daemon
systemctl daemon-reload

# Enable and start the rclone service
systemctl enable rclone-gdrive.service
systemctl start rclone-gdrive.service
