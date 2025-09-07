#!/bin/bash
set -e

SERVICE_NAME="batt-collector.service"
BIN_DIR="$HOME/bin"
SCRIPT="$BIN_DIR/batt-collector.sh"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/$SERVICE_NAME"

install_collector() {
    echo "[*] Installing battery collector..."

    # Ask user for sysfs path
    read -rp "Enter battery sysfs path [/sys/class/power_supply/battery]: " BAT_PATH
    BAT_PATH="${BAT_PATH:-/sys/class/power_supply/battery}"

    if [ ! -d "$BAT_PATH" ]; then
        echo "[!] Error: Path $BAT_PATH does not exist"
        exit 1
    fi

    mkdir -p "$BIN_DIR" "$SYSTEMD_USER_DIR"

    cat > "$SCRIPT" <<EOF
#!/bin/bash
BAT_PATH="$BAT_PATH"
STATE_FILE="\$HOME/.cache/batt-state"
LOG_FILE="\$HOME/.cache/batt-log.csv"

mkdir -p "\$(dirname "\$STATE_FILE")"

# Add CSV header if missing
[ -f "\$LOG_FILE" ] || echo "timestamp,voltage(V),current(mA),capacity(%),status" > "\$LOG_FILE"

while true; do
    V=\$(awk '{printf "%.2f", \$1/1e6}' "\$BAT_PATH/voltage_now" 2>/dev/null || echo "0")
    I=\$(awk '{printf "%.0f", \$1/1e3}' "\$BAT_PATH/current_now" 2>/dev/null || echo "0")
    C=\$(cat "\$BAT_PATH/capacity" 2>/dev/null || echo "0")
    S=\$(cat "\$BAT_PATH/status" 2>/dev/null || echo "Unknown")

    {
        echo "BAT_V=\$V"
        echo "BAT_I=\$I"
        echo "BAT_C=\$C"
        echo "BAT_S=\$S"
    } > "\$STATE_FILE"

    echo "\$(date +%s),\$V,\$I,\$C,\$S" >> "\$LOG_FILE"

    sleep 5
done
EOF

    chmod +x "$SCRIPT"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Battery info collector

[Service]
ExecStart=$SCRIPT
Restart=always

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"

    echo "[+] Installed and started $SERVICE_NAME"
    echo "[i] Battery path set to: $BAT_PATH"
}

uninstall_collector() {
    echo "[*] Uninstalling battery collector..."

    systemctl --user stop "$SERVICE_NAME" || true
    systemctl --user disable "$SERVICE_NAME" || true
    rm -f "$SERVICE_FILE" "$SCRIPT"

    echo "[+] Removed service and script"
    echo "[i] Cache files left in ~/.cache (remove manually if you want)"
}

case "$1" in
    install)
        install_collector
        ;;
    uninstall)
        uninstall_collector
        ;;
    *)
        echo "Usage: $0 {install|uninstall}"
        exit 1
        ;;
esac
