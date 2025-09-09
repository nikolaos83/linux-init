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
REMOTE=${1:?remote required}
INSTANCE=${2:?instance required}
CONFIG=/root/.config/rclone/rclone.conf

if [ "$INSTANCE" = "common" ]; then
    MOUNT_POINT=/mnt/gdrive/common
    REMOTE_PATH=$REMOTE:/servers/common
else
    MOUNT_POINT=/mnt/gdrive/$(hostname -s)
    REMOTE_PATH=$REMOTE:/servers/$(hostname -s)
fi

mkdir -p "$MOUNT_POINT"

exec /usr/bin/rclone mount \
    "$REMOTE_PATH" "$MOUNT_POINT" \
    --config="$CONFIG" \
    --allow-other \
    --dir-cache-time=72h \
    --poll-interval=15s \
    --vfs-cache-mode=full \
    --vfs-cache-max-size=10G \
    --vfs-cache-max-age=24h \
    --umask=002 \
    --log-file=/var/log/rclone-$INSTANCE.log \
    --log-level=INFO
EOF

chmod +x /usr/local/bin/rclone-mount.sh

cat > "$RCLONE_SERVICE_FILE" << 'EOF'
[Unit]
Description=Rclone Mount (%i)
Documentation=https://rclone.org/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rclone-mount.sh gdrive %i
ExecStop=/bin/bash -c '$(which fusermount) -uz /mnt/%i'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rclone@host
systemctl enable rclone@common
systemctl start rclone@host
systemctl start rclone@common
