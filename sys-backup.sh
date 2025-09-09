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

# Email settings
EMAIL_FROM="${HOSTNAME}-${BACKUPS_EMAIL_FROM}"
EMAIL_TO="${BACKUPS_EMAIL_TO}"

###########################
# INSTALL DEPENDENCIES
###########################

apt update
apt upgrade -y
apt install -y rclone msmtp-mta mailutils

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
    --cache-dir=/var/cache/rclone \
    --vfs-cache-mode=writes \
    --vfs-cache-max-size=2G \
    --vfs-cache-max-age=12h
    --umask=002 \
    --log-file=/var/log/rclone-$INSTANCE.log \
    --log-level=INFO
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
BACKUP_ROOT="/mnt/gdrive/$HOST/backups"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
KEEP_WEEKLY=2
KEEP_MONTHLY=2

EMAIL_SUBJECT="backups@$HOST"

mkdir -p "$BACKUP_DIR"

echo "[INFO] Starting backup for $HOST at $TIMESTAMP"

# Directories to backup
for DIR in /home /root; do
    DIR_NAME=$(basename "$DIR")
    rsync -a --no-acls --no-xattrs --delete "$DIR/" "$BACKUP_DIR/$DIR_NAME/"
done

# Retention: weekly backups (last 2)
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name '????-??-??T??-??-??Z' \
    | sort | head -n -$KEEP_WEEKLY | xargs -r rm -rf

# Retention: monthly backups (keep last 2)
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name '????-??-??T??-??-??Z' \
    | sort -r | awk -F'T' '{print $1}' | uniq -d | tail -n +$(($KEEP_MONTHLY+1)) \
    | while read OLD; do rm -rf "$BACKUP_ROOT/$OLD"*; done

# Email report
REPORT="[INFO] Backup completed for $HOST at $TIMESTAMP"
echo -e "$REPORT" | mail -s "$EMAIL_SUBJECT" -r "$EMAIL_FROM" "$EMAIL_TO"

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
