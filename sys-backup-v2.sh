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
LOG_FILE="/var/log/sys-backup-v2.log"

###########################
# FUNCTIONS
###########################

log() {
    echo "[$ (date -u +"%Y-%m-%dT%H-%M-%SZ")] $1" | tee -a "$LOG_FILE"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_dependencies() {
    log "[INFO] Installing dependencies..."
    apt-get update -y
    if ! command_exists restic; then
        log "[INFO] Installing restic..."
        apt-get install -y restic
    else
        log "[INFO] restic is already installed."
    fi
    if ! command_exists rclone; then
        log "[INFO] Installing rclone..."
        apt-get install -y rclone
    else
        log "[INFO] rclone is already installed."
    fi
}

init_restic_repo() {
    if ! rclone lsjson "$ (dirname "$RESTIC_REPOSITORY")" --config /root/.config/rclone/rclone.conf | grep -q "$ (basename "$RESTIC_REPOSITORY")"; then
        log "[INFO] Restic repository not found. Initializing new repository at $RESTIC_REPOSITORY..."
        restic init
        log "[INFO] Restic repository initialized."
    else
        log "[INFO] Restic repository already exists."
    fi
}

backup_databases() {
    local DUMP_DIR=$1
    log "[INFO] Dumping databases..."

    # MySQL
    log "[INFO] Dumping MySQL databases..."
    docker exec mysql sh -c "mysqldump --all-databases -uroot -p'$DB_ROOT_PASS'" > "$DUMP_DIR/mysql-all-databases.sql"

    # PostgreSQL
    log "[INFO] Dumping PostgreSQL databases..."
    docker exec postgres sh -c "pg_dumpall -U postgresuser" > "$DUMP_DIR/postgres-all-databases.sql"
    export PGPASSWORD=$POSTGRES_PASS

    # ClickHouse
    log "[INFO] Dumping ClickHouse databases..."
    # We need to get a list of databases first
    databases=$(docker exec clickhouse clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASS" --query "SHOW DATABASES")
    for db in $databases; do
        if [[ "$db" != "system" && "$db" != "information_schema" && "$db" != "INFORMATION_SCHEMA" ]]; then
            log "[INFO] Dumping ClickHouse database: $db"
            docker exec clickhouse clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASS" --query=\"BACKUP DATABASE \`$db\` TO Disk('backups', '$db.zip')\"
            # This backups inside the container, we need to copy it out
            docker cp clickhouse:/var/lib/clickhouse/backups/default/ "$DUMP_DIR/clickhouse-$db"
        fi
    done

    log "[INFO] Database dumps complete."
}

run_backup() {
    log "[INFO] Starting restic backup..."

    local TMP_DUMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DUMP_DIR"' RETURN

    backup_databases "$TMP_DUMP_DIR"

    restic backup \
        --tag "system-backup" \
        --exclude-file="/etc/restic/exclude.patterns" \
        --verbose \
        "${BACKUP_DIRS[@]}" \
        "$TMP_DUMP_DIR"

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

install_dependencies
create_exclude_file
init_restic_repo
run_backup
apply_retention_policy

log "[INFO] Backup script finished successfully."
