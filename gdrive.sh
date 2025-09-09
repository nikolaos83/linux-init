RCLONE_SERVICE_FILE="/etc/systemd/system/rclone@.service"

apt update
apt upgrade -y
apt install rclone -y

mkdir -p /root/.config/rclone/
mkdir -p /root/.cache/rclone
mkdir -p /mnt/gdrive/common
mkdir -p /mnt/gdrive/${HOSTNAME}

curl -H "Authorization: token ${GITHUB_TOKEN}" -fsSL https://raw.githubusercontent.com/nikolaos83/secrets/refs/heads/main/rclone.conf -o /root/.config/rclone/rclone.conf || echo "Failed to fetch rclone.conf"

cat > "$RCLONE_SERVICE_FILE" << 'EOF'
[Unit]
Description=Rclone Mount (%i)
Documentation=https://rclone.org/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

# If instance is "common", mount remote:/servers/common → /mnt/gdrive/common
# Otherwise, mount remote:/servers/%H → /mnt/gdrive/%H

ExecStart=/bin/bash -lc '
    remote="gdrive"
    if [ "%i" = "common" ]; then
        /usr/bin/rclone mount \
            ${remote}:/servers/common /mnt/gdrive/common \
            --config=/root/.config/rclone/rclone.conf \
            --allow-other \
            --dir-cache-time=72h \
            --poll-interval=15s \
            --vfs-cache-mode=full \
            --vfs-cache-max-size=10G \
            --vfs-cache-max-age=24h \
            --umask=002 \
            --log-file=/var/log/rclone-%i.log \
            --log-level=INFO
    else
        /usr/bin/rclone mount \
            ${remote}:/servers/%H /mnt/gdrive/%H \
            --config=/root/.config/rclone/rclone.conf \
            --allow-other \
            --dir-cache-time=72h \
            --poll-interval=15s \
            --vfs-cache-mode=full \
            --vfs-cache-max-size=10G \
            --vfs-cache-max-age=24h \
            --umask=002 \
            --log-file=/var/log/rclone-%i.log \
            --log-level=INFO
    fi
'
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
