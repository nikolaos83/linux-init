#!/bin/bash
set -euo pipefail

###########################
# CONFIGURATION
###########################

# --- Restic Configuration ---
# !!! IMPORTANT !!!
# You MUST create a password file for your restic repository.
# Run the following command and enter a strong password:
#   echo "YOUR_STRONG_PASSWORD_HERE" > /root/.config/restic/password
#   chmod 600 /root/.config/restic/password
export RESTIC_PASSWORD_FILE="/root/.config/restic/password"

# The rclone remote and path where the restic repository will be stored.
export RESTIC_REPOSITORY="rclone:gdrive:/restic"

# --- Docker & Database Configuration ---
DB_ROOT_PASS='8TK9p2M&&&89pj!!M+98jM8%%%+jM&98jMp2C&%XMg'
POSTGRES_PASS='387hjd38++1!!37hj%%&dhjdhk3783hjdhk3783'
CLICKHOUSE_PASS='XXX2M9pjM93813dlldjlkjdlkjbpv7dlkjdlhjdh7hXXX'
CLICKHOUSE_USER='niko'

# --- Backup Configuration ---
BACKUP_DIRS=('/home' '/root' '/etc')
LOG_FILE="/var/log/sys-backup-v3.log"

###########################
# FUNCTIONS
###########################

log() {
    echo "[$(date -u +"%Y-%m-%dT%H-%M-%SZ")] $1" | tee -a "$LOG_FILE"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_os_and_install_dependencies() {
    log "[INFO] Detecting OS and installing dependencies..."
    local PKG_MANAGER=""
    local INSTALL_CMD=""

    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "$ID" in
            debian|ubuntu) 
                PKG_MANAGER="apt-get"
                INSTALL_CMD="update -y && $PKG_MANAGER install -y"
                ;; 
            alpine)
                PKG_MANAGER="apk"
                INSTALL_CMD="add"
                ;; 
            centos|rhel|fedora)
                if command_exists dnf; then
                    PKG_MANAGER="dnf"
                elif command_exists yum; then
                    PKG_MANAGER="yum"
                fi
                INSTALL_CMD="install -y"
                ;; 
            *)
                log "[ERROR] Unsupported distribution: $ID"
                exit 1
                ;; 
        esac
    else
        log "[ERROR] Cannot detect the operating system."
        exit 1
    fi

    log "[INFO] Using package manager: $PKG_MANAGER"
    
    DEPS_TO_INSTALL=""
    if ! command_exists restic; then DEPS_TO_INSTALL="$DEPS_TO_INSTALL restic"; fi
    if ! command_exists rclone; then DEPS_TO_INSTALL="$DEPS_TO_INSTALL rclone"; fi

    if [ -n "$DEPS_TO_INSTALL" ]; then
        log "[INFO] Installing: $DEPS_TO_INSTALL"
        # shellcheck disable=SC2086
        $PKG_MANAGER $INSTALL_CMD $DEPS_TO_INSTALL
    else
        log "[INFO] All dependencies (restic, rclone) are already installed."
    fi
}

init_restic_repo() {
    if ! rclone lsjson "$(dirname "$RESTIC_REPOSITORY")" --config /root/.config/rclone/rclone.conf | grep -q "$(basename "$RESTIC_REPOSITORY")"; then
        log "[INFO] Restic repository not found. Initializing new repository at $RESTIC_REPOSITORY..."
        restic init
        log "[INFO] Restic repository initialized."
    else
        log "[INFO] Restic repository already exists."
    fi
}

run_backup() {
    log "[INFO] Starting restic backup..."

    # 1. Backup filesystem paths
    log "[INFO] Backing up configured directories: ${BACKUP_DIRS[*]}"
    restic backup \
        --tag "system-files" \
        --exclude-file="/etc/restic/exclude.patterns" \
        --verbose \
        "${BACKUP_DIRS[@]}"
    log "[INFO] Filesystem backup complete."

    # 2. Stream MySQL backup
    log "[INFO] Streaming MySQL database dump to restic..."
    docker exec mysql sh -c "mysqldump --all-databases -uroot -p'$DB_ROOT_PASS'" | restic backup \
        --tag "databases" --tag "mysql" \
        --stdin --stdin-filename "mysql-all-databases.sql" \
        --verbose
    log "[INFO] MySQL backup complete."

    # 3. Stream PostgreSQL backup
    log "[INFO] Streaming PostgreSQL database dump to restic..."
    export PGPASSWORD=$POSTGRES_PASS
    docker exec postgres sh -c "pg_dumpall -U postgresuser" | restic backup \
        --tag "databases" --tag "postgres" \
        --stdin --stdin-filename "postgres-all-databases.sql" \
        --verbose
    log "[INFO] PostgreSQL backup complete."

    # 4. Backup ClickHouse databases (requires temporary local file)
    log "[INFO] Backing up ClickHouse databases..."
    local TMP_CH_DIR
    TMP_CH_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_CH_DIR"' RETURN

    databases=$(docker exec clickhouse clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASS" --query "SHOW DATABASES")
    for db in $databases; do
        if [[ "$db" != "system" && "$db" != "information_schema" && "$db" != "INFORMATION_SCHEMA" ]]; then
            local backup_filename="$db.zip"
            log "[INFO] Dumping ClickHouse database: $db"
            docker exec clickhouse clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASS" --query="BACKUP DATABASE \`$db\` TO Disk('backups', '$backup_filename')"
            
            log "[INFO] Copying dump from container and backing up to restic..."
            docker cp "clickhouse:/var/lib/clickhouse/backups/$backup_filename" "$TMP_CH_DIR/"
            
            restic backup \
                --tag "databases" --tag "clickhouse" --tag "clickhouse-$db" \
                --verbose \
                "$TMP_CH_DIR/$backup_filename"

            log "[INFO] Cleaning up local and container files for $db..."
            docker exec clickhouse rm "/var/lib/clickhouse/backups/$backup_filename"
            rm "$TMP_CH_DIR/$backup_filename"
        fi
    done
    log "[INFO] ClickHouse backup complete."

    log "[INFO] Restic backup finished."
}

apply_retention_policy() {
    log "[INFO] Applying retention policy..."
    restic forget \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        --prune \
        --verbose

    log "[INFO] Retention policy applied."
}

create_exclude_file() {
    mkdir -p /etc/restic
    cat > /etc/restic/exclude.patterns << 'EOL'
# Exclude common cache and temporary directories
**/*.cache
**/[Cc]ache*
/var/cache/*
/tmp/*
/var/tmp/*

# Exclude logs
/var/log/*

# Exclude docker data that can be rebuilt
/var/lib/docker/overlay2/*
/var/lib/docker/containers/*
/var/lib/docker/image/*

# Exclude node_modules
**/node_modules/*
EOL
}

###########################
# SCRIPT EXECUTION
###########################

# Check for password file first
if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    log "[ERROR] Restic password file not found at $RESTIC_PASSWORD_FILE."
    log "[ERROR] Please create it with your repository password."
    exit 1
fi

detect_os_and_install_dependencies
create_exclude_file
init_restic_repo
run_backup
apply_retention_policy

log "[INFO] Backup script finished successfully."
