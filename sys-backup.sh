#!/bin/bash
set -euo pipefail

###########################
# CONFIGURATION
###########################

REMOTE="gdrive"
MOUNT_POINT="/mnt/gdrive/$(hostname -s)"
BACKUP_ROOT="$MOUNT_POINT/backups"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RCLONE_SCRIPT="/usr/local/bin/rclone-mount.sh"
BACKUP_SCRIPT="/usr/local/bin/backup-to-gdrive.sh"
SERVICE_FILE="/etc/systemd/system/rclone@.service"
TIMER_FILE="/etc/systemd/system/backup-to-gdrive.timer"
SERVICE_NAME="rclone@host"
HOST=$(hostname -s)
REMOTE_PATH="$REMOTE:/servers/$HOST/backups"

###########################
# INSTALL DEPENDENCIES
###########################

apt update
apt upgrade -y
apt install -y rclone rsync

mkdir -p "$(dirname "$RCLONE_CONFIG")"
mkdir -p "$BACKUP_ROOT"

# Fetch rclone config
if ! curl -H "Authorization: token ${GITHUB_TOKEN}" -fsSL https://raw.githubusercontent.com/nikolaos83/secrets/refs/heads/main/rclone.conf -o "$RCLONE_CONFIG"; then
    echo "[WARN] Failed to fetch rclone.conf"
fi

###########################
# RCLONE WRAPPER
###########################

cat > "$RCLONE_SCRIPT" << 'EOF'
#!/bin/bash
set -euo pipefail

REMOTE=${1:?remote required}
INSTANCE=${2:?instance required}
CONFIG=/root/.config/rclone/rclone.conf
MOUNT_POINT=/mnt/gdrive/$(hostname -s)

mkdir -p "$MOUNT_POINT"

exec /usr/bin/rclone mount \
    "$REMOTE:/servers/$(hostname -s)" "$MOUNT_POINT" \
    --config="$CONFIG" \
    --allow-other \
    --dir-cache-time=72h \
    --poll-interval=15s \
    --log-file=/var/log/rclone-$INSTANCE.log \
    --umask=002 \
    --log-level=INFO \
    --read-only
EOF

chmod +x "$RCLONE_SCRIPT"

###########################
# SYSTEMD UNIT FOR RCLONE
###########################

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Rclone Mount (%i)
Documentation=https://rclone.org/docs/
After=network-online.target
Wants=network-online.target
Requires=network-online.target

[Service]
Type=simple
ExecStart=$RCLONE_SCRIPT $REMOTE %i
ExecStop=/bin/bash -c '$(which fusermount) -uz /mnt/%i || echo "[WARN] Unmount failed for /mnt/%i"'
Restart=on-failure
RestartSec=10
TimeoutSec=60
StartLimitBurst=3
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

###########################
# BACKUP SCRIPT
###########################

cat > "$BACKUP_SCRIPT" << 'EOF'
#!/bin/bash
set -euo pipefail

HOST=$(hostname -s)
REMOTE="gdrive"
BACKUP_ROOT="/mnt/gdrive/$HOST/backups"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
KEEP_DAYS=60 # Keep backups for 14 days
REMOTE_PATH="$REMOTE:/servers/$HOST/backups"

mkdir -p "$BACKUP_DIR"
echo "[INFO] Starting backup for $HOST at $TIMESTAMP"

# Directories to backup
for DIR in /home /root; do
    DIR_NAME=$(basename "$DIR")
    echo "[INFO] Backing up $DIR to $REMOTE_PATH/$TIMESTAMP/$DIR_NAME/"
    /usr/bin/rclone copy "$DIR" "$REMOTE_PATH/$TIMESTAMP/$DIR_NAME/" --log-level=INFO
done

# Retention: delete backups older than KEEP_DAYS
echo "[INFO] Pruning backups older than $KEEP_DAYS days"
/usr/bin/rclone delete --min-age ${KEEP_DAYS}d "$REMOTE_PATH"

echo "[INFO] Backup finished"
EOF

chmod +x "$BACKUP_SCRIPT"

###########################
# SYSTEMD TIMER
###########################

cat > "$TIMER_FILE" << EOF
[Unit]
Description=Weekly Backup to GDrive

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/backup-to-gdrive.service << EOF
[Unit]
Description=Run Backup to GDrive

[Service]
Type=oneshot
ExecStart=$BACKUP_SCRIPT
EOF

systemctl daemon-reload
systemctl enable backup-to-gdrive.timer
systemctl start backup-to-gdrive.timer

echo "[INFO] Backup system installed and timer enabled"

###########################
# RUN FIRST BACKUP IMMEDIATELY
###########################

echo "[INFO] Triggering first backup now..."
systemctl start backup-to-gdrive.service
echo "[INFO] First backup triggered. You can monitor progress with:"
echo "  journalctl -u backup-to-gdrive.service -f"
