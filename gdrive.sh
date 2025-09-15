#!/bin/bash

# Create the rclone mount script
cat << 'EOF' > /usr/local/bin/rclone-mount.sh
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
if [ "$INSTANCE" = "backups" ]; then
    MOUNT_POINT=/mnt/backups
    REMOTE_PATH=$REMOTE:/backups
elif [ "$INSTANCE" = "hosts" ]; then
    MOUNT_POINT=/mnt/hosts
    REMOTE_PATH=$REMOTE:/hosts/
elif [ "$INSTANCE" = "netdata" ]; then
    MOUNT_POINT=/mnt/netdata
    REMOTE_PATH=$REMOTE:/netdata/
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
    --buffer-size=256M \
    --vfs-cache-mode=writes \
    --vfs-read-chunk-size=128M \
    --vfs-read-chunk-size-limit=2G
EOF

# Create the systemd service file
cat << 'EOF' > /etc/systemd/system/rclone@.service
[Unit]
Description=Rclone Mount (%i)
Documentation=https://rclone.org/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rclone-mount.sh gdrive %i
ExecStop=/bin/bash -c '/usr/bin/fusermount -uz /mnt/%i || echo "[WARN] Unmount failed for /mnt/%i"'
Restart=on-failure
RestartSec=5
TimeoutSec=60
StartLimitBurst=3
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
EOF

# Make the mount script executable
chmod +x /usr/local/bin/rclone-mount.sh

# Reload the systemd daemon
systemctl daemon-reload

# Enable and start the rclone services
systemctl enable rclone@backups.service
systemctl enable rclone@hosts.service
systemctl enable rclone@netdata.service
systemctl start rclone@backups.service
systemctl start rclone@hosts.service
systemctl start rclone@netdata.service
