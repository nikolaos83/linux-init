#!/bin/sh
# install-chmod-watchdog.sh
# Installs a systemd service that chmod +x any new file in /home/scripts/

WATCHDIR="/home/scripts"
SERVICE_NAME="scripts-watchdog"

# Ensure watch directory exists
mkdir -p "$WATCHDIR"
chmod 700 "$WATCHDIR"

# 1. Create the watchdog script
WATCHDOG_SCRIPT="/usr/local/bin/${SERVICE_NAME}.sh"

cat > "$WATCHDOG_SCRIPT" << 'EOF'
#!/bin/sh
WATCHDIR="/home/scripts"

# Use inotifywait if available, else fallback to polling
if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -m -e create "$WATCHDIR" | while read path action file; do
        chmod +x "$path$file"
        echo "Made $file executable."
    done
else
    while true; do
        find "$WATCHDIR" -type f ! -perm -u+x -exec chmod +x {} \;
        sleep 5
    done
fi
EOF

chmod +x "$WATCHDOG_SCRIPT"

# 2. Create the systemd service unit
SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

cat > "$SERVICE_UNIT" << EOF
[Unit]
Description=Watch /home/scripts and chmod +x new files
After=network.target

[Service]
ExecStart=$WATCHDOG_SCRIPT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# 3. Enable and start the service
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo "Systemd service '$SERVICE_NAME' installed and started."
echo "Watching $WATCHDIR for new files."
