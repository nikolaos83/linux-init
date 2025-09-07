#!/bin/bash
set -euo pipefail

COLLECTOR_NAME="batt-collector"
TITLE_NAME="battery-title"
BIN_DIR="$HOME/.local/bin"
SERVICE_DIR="$HOME/.config/systemd/user"
CACHE_DIR="$HOME/.cache"
CACHE_FILE="$CACHE_DIR/batt-state"
LOG_FILE="$CACHE_DIR/batt-log.csv"
BAT_PATH="/sys/class/power_supply/qcom-battery"

install_all() {
    echo "[*] Installing battery monitor services…"
    mkdir -p "$BIN_DIR" "$SERVICE_DIR" "$CACHE_DIR"

    #### Collector script ####
    cat > "$BIN_DIR/${COLLECTOR_NAME}.sh" <<EOF
#!/bin/bash
BAT_PATH="$BAT_PATH"
STATE_FILE="$CACHE_FILE"
LOG_FILE="$LOG_FILE"

mkdir -p "\$(dirname "\$STATE_FILE")"
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
    chmod +x "$BIN_DIR/${COLLECTOR_NAME}.sh"

    #### Title updater script ####
    cat > "$BIN_DIR/${TITLE_NAME}-daemon.sh" <<'EOF'
#!/bin/bash
cache="$HOME/.cache/batt-state"

while true; do
    if [ -f "$cache" ]; then
        # shellcheck disable=SC1090
        source "$cache"
        icon="🔋"
        [ "$BAT_S" = "Charging" ] && icon="🔌"
        printf '\033]0;%s\033\\' "${icon}${BAT_C}% $USER@$HOSTNAME"
    else
        printf '\033]0;%s\033\\' "$USER@$HOSTNAME"
    fi
    sleep 10
done
EOF
    chmod +x "$BIN_DIR/${TITLE_NAME}-daemon.sh"

    #### Collector service ####
    cat > "$SERVICE_DIR/${COLLECTOR_NAME}.service" <<EOF
[Unit]
Description=Battery info collector
After=default.target

[Service]
ExecStart=$BIN_DIR/${COLLECTOR_NAME}.sh
Restart=always

[Install]
WantedBy=default.target
EOF

    #### Title service ####
    cat > "$SERVICE_DIR/${TITLE_NAME}.service" <<EOF
[Unit]
Description=Battery % updater in terminal title
After=${COLLECTOR_NAME}.service

[Service]
ExecStart=$BIN_DIR/${TITLE_NAME}-daemon.sh
Restart=always

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "${COLLECTOR_NAME}.service" "${TITLE_NAME}.service"

    echo "[+] Installed and started:"
    echo "    - ${COLLECTOR_NAME}.service"
    echo "    - ${TITLE_NAME}.service"
    echo
    echo "Check logs with:"
    echo "    systemctl --user status ${COLLECTOR_NAME}"
    echo "    systemctl --user status ${TITLE_NAME}"
}

uninstall_all() {
    echo "[*] Uninstalling battery monitor services…"
    systemctl --user disable --now "${TITLE_NAME}.service" "${COLLECTOR_NAME}.service" || true
    rm -f \
        "$BIN_DIR/${COLLECTOR_NAME}.sh" \
        "$BIN_DIR/${TITLE_NAME}-daemon.sh" \
        "$SERVICE_DIR/${COLLECTOR_NAME}.service" \
        "$SERVICE_DIR/${TITLE_NAME}.service"
    systemctl --user daemon-reload
    echo "[+] Uninstalled."
}

case "${1:-}" in
    uninstall) uninstall_all ;;
    *) install_all ;;
esac
