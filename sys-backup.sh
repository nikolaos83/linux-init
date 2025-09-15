#!/bin/bash
set -euo pipefail

###########################
# CONFIGURATION
###########################

REMOTE="gdrive"
HOST=$(hostname -s)
REMOTE_PATH="$REMOTE:/servers/$HOST/backups"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
BACKUP_SCRIPT="/usr/local/bin/sys-backup.sh"
TIMER_FILE="/etc/systemd/system/sys-backup.timer"
LOG_FILE="/var/log/sys-backup.log"
KEEP_DAYS=60 # Keep backups for 60 days

# Directories to be backed up
BACKUP_DIRS=("/home" "/root" "/etc")

###########################
# FUNCTIONS
###########################

log() {
    echo "[$ (date -u +"%Y-%m-%dT%H-%M-%SZ")] $1" | tee -a "$LOG_FILE"
}

install_dependencies() {
    log "[INFO] Updating package lists..."
    apt-get update -y
    log "[INFO] Installing dependencies (rclone)..."
    apt-get install -y rclone
}

configure_rclone() {
    log "[INFO] Configuring rclone..."
    mkdir -p "$(dirname "$RCLONE_CONFIG")"
    # Fetch rclone config from a secure location (e.g., GitHub secrets)
    if ! curl -H "Authorization: token ${GITHUB_TOKEN}" -fsSL https://raw.githubusercontent.com/nikolaos83/secrets/refs/heads/main/rclone.conf -o "$RCLONE_CONFIG"; then
        log "[ERROR] Failed to fetch rclone.conf. Please configure it manually at $RCLONE_CONFIG."
        exit 1
    fi
    log "[INFO] rclone configured successfully."
}

###########################
# MAIN BACKUP SCRIPT LOGIC
###########################

# This section will be written into the actual backup script that the timer runs
create_backup_script() {
    cat > "$BACKUP_SCRIPT" << EOL
#!/bin/bash
set -euo pipefail

# Configuration is inherited from the installer script's variables
REMOTE="$REMOTE"
HOST="$HOST"
REMOTE_PATH="$REMOTE_PATH"
LOG_FILE="$LOG_FILE"
KEEP_DAYS=$KEEP_DAYS
BACKUP_DIRS=(${BACKUP_DIRS[@]})

log() {
    echo "[\$(date -u +"%Y-%m-%dT%H-%M-%SZ")] \$1" | tee -a "\$LOG_FILE"
}

log "[INFO] Starting system backup for \$HOST..."

# Create a temporary directory for the backup
TMP_DIR=\$(mktemp -d)
trap 'rm -rf "\$TMP_DIR"' EXIT

TIMESTAMP=\$(date -u +"%Y-%m-%dT%H-%M-%SZ")
ARCHIVE_NAME="sys-backup-\$TIMESTAMP.tar.gz"
ARCHIVE_PATH="\$TMP_DIR/\$ARCHIVE_NAME"

log "[INFO] Creating archive: \$ARCHIVE_NAME"
tar -czf "\$ARCHIVE_PATH" \
    --exclude='*.log' \
    --exclude='*.cache' \
    --exclude='*/tmp/*' \
    --exclude='*/node_modules/*' \
    \${BACKUP_DIRS[@]}

log "[INFO] Uploading archive to \$REMOTE_PATH..."
/usr/bin/rclone copy "\$ARCHIVE_PATH" "\$REMOTE_PATH/" --config="$RCLONE_CONFIG" --log-level=INFO

log "[INFO] Backup uploaded successfully."

log "[INFO] Pruning backups older than \$KEEP_DAYS days..."
/usr/bin/rclone delete "\$REMOTE_PATH/" --config="$RCLONE_CONFIG" --min-age \${KEEP_DAYS}d --log-level=INFO

log "[INFO] Backup and pruning finished."
EOL

    chmod +x "$BACKUP_SCRIPT"
}

###########################
# SYSTEMD TIMER SETUP
###########################

setup_systemd_timer() {
    log "[INFO] Setting up systemd timer..."

    cat > /etc/systemd/system/sys-backup.service << EOF
[Unit]
Description=Run System Backup to GDrive
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BACKUP_SCRIPT
EOF

    cat > "$TIMER_FILE" << EOF
[Unit]
Description=Daily System Backup to GDrive

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable sys-backup.timer
    systemctl start sys-backup.timer
    log "[INFO] Systemd timer enabled. Backup will run daily."
}

###########################
# SCRIPT EXECUTION
###########################

install_dependencies
configure_rclone
create_backup_script
setup_systemd_timer

log "[INFO] System backup script installed successfully."
log "[INFO] Triggering first backup now..."
systemctl start sys-backup.service
log "[INFO] First backup triggered. Monitor with: journalctl -u sys-backup.service -f"