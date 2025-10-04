#!/bin/bash
#
# oci-update-ipv6-rule.sh
#
# Purpose:
#   Keep OCI Security List + host firewalls in sync with current IPv6 prefix.
#   Runs on a controller host and can also push updates to extra hosts.
#
# Features:
#   - Detect prefix from router via SSH
#   - Update OCI Security List rule (by description)
#   - Update local firewall via firewalld + ipset
#   - Update remote hosts via SSH
#   - SELinux-friendly (restorecon + AVC checks)
#   - Install/uninstall as systemd service + timer
#   - Dry-run mode
#   - Colorful, verbose logging
#
# Usage:
#   oci-update-ipv6-rule.sh            Run once
#   oci-update-ipv6-rule.sh --install  Install service+timer
#   oci-update-ipv6-rule.sh --uninstall Remove service+timer
#   oci-update-ipv6-rule.sh --dry-run  Preview changes
#   oci-update-ipv6-rule.sh -h|--help  Show help
#

# --- Default Configuration ---
SEC_LIST_OCID="$Oracle_VCN_Security_List_OCID"
RULE_DESCRIPTION="ALLOW_HOME_NETWORK@NET28"
SSH_USER_HOST="root@msm"
EXTRA_HOSTS=("m1" "m2")
TIMER_INTERVAL="5min"
LOG_FILE="/var/log/oci_ipv6_update.log"
STRICT_SELINUX=true
INSTALL_PATH="/usr/local/bin/oci-update-ipv6-rule.sh"
# --- End Configuration ---

# --- Colors ---
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RESET="\033[0m"

log() {
    local msg="$1"
    local color="$2"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$color" ]; then
        echo -e "${ts} - ${color}${msg}${RESET}" | tee -a "$LOG_FILE"
    else
        echo "${ts} - $msg" | tee -a "$LOG_FILE"
    fi
}

usage() {
    echo -e "${BLUE}============================================${RESET}"
    echo -e "${BLUE}   OCI IPv6 Updater & Firewall Sync Tool   ${RESET}"
    echo -e "${BLUE}============================================${RESET}"
    echo
    echo -e "${GREEN}Usage:${RESET}"
    echo "  $0 [--install|--uninstall|--dry-run|--help]"
    echo
    echo -e "${GREEN}Options:${RESET}"
    echo "  --install     Install as systemd service+timer"
    echo "  --uninstall   Remove systemd service+timer"
    echo "  --dry-run     Show what would happen, but do nothing"
    echo "  -h, --help    Show this help message"
    echo
    echo -e "${GREEN}Defaults:${RESET}"
    echo "  OCI SecList OCID: $SEC_LIST_OCID"
    echo "  Rule description: $RULE_DESCRIPTION"
    echo "  SSH router host : $SSH_USER_HOST"
    echo "  Extra hosts     : ${EXTRA_HOSTS[*]}"
    echo "  Timer interval  : $TIMER_INTERVAL"
    echo "  Install path    : $INSTALL_PATH"
    echo
    exit 0
}

selinux_status() {
    if command -v getenforce >/dev/null; then
        local mode=$(getenforce)
        log "SELinux mode: $mode" "$BLUE"
        [ "$mode" = "Enforcing" ] && log "⚠ SELinux is enforcing" "$YELLOW"
    fi
}

fix_selinux_contexts() {
    if command -v restorecon >/dev/null; then
        restorecon -v /etc/systemd/system/oci-update-ipv6-rule.{service,timer} "$INSTALL_PATH" 2>&1 | tee -a "$LOG_FILE"
    fi
}

check_avc() {
    if [ -f /var/log/audit/audit.log ]; then
        local denials
        denials=$(tail -n 50 /var/log/audit/audit.log | grep AVC | tail -n 5)
        [ -n "$denials" ] && log "Recent SELinux denials:\n$denials" "$YELLOW"
    fi
}

get_prefix_ssh() {
    log "Querying IPv6 prefix via $SSH_USER_HOST..." "$BLUE"
    CURRENT_PREFIX=$(ssh "$SSH_USER_HOST" "rdisc6 -1 wlan0" | awk '/Prefix/ {print $3; exit}')
}

update_local_fw() {
    local prefix=$1
    local ipset_name="home6"
    log "Updating local firewall with prefix: ${YELLOW}$prefix${RESET}"

    firewall-cmd --permanent --get-ipsets | grep -q "^$ipset_name$" || \
        firewall-cmd --permanent --new-ipset=$ipset_name --type=hash:net --family=ipv6

    firewall-cmd --permanent --zone=public --query-rich-rule="rule family=ipv6 source ipset=$ipset_name accept" >/dev/null 2>&1 || \
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv6 source ipset=$ipset_name accept"

    for entry in $(firewall-cmd --ipset=$ipset_name --get-entries); do
        firewall-cmd --permanent --ipset=$ipset_name --remove-entry=$entry
    done

    firewall-cmd --permanent --ipset=$ipset_name --add-entry=$prefix

    if ! firewall-cmd --reload; then
        log "firewalld reload failed (possible SELinux denial)" "$RED"
        check_avc
        $STRICT_SELINUX && exit 1
    fi
}

update_remote_fw() {
    local prefix=$1
    for host in "${EXTRA_HOSTS[@]}"; do
        log "Updating firewall on ${YELLOW}$host${RESET} with prefix ${YELLOW}$prefix${RESET}"
        ssh "root@$host" "$(typeset -f update_local_fw); update_local_fw $prefix"
    done
}

install_service() {
    echo "Installing systemd service and timer..."

    read -p "OCI Security List OCID [$SEC_LIST_OCID]: " input
    [ -n "$input" ] && SEC_LIST_OCID=$input

    read -p "Hosts to update (space-separated) [${EXTRA_HOSTS[*]}]: " input
    [ -n "$input" ] && EXTRA_HOSTS=($input)

    read -p "Timer interval [$TIMER_INTERVAL]: " input
    [ -n "$input" ] && TIMER_INTERVAL=$input

    # Copy script to /usr/local/bin
    install -m 755 "$0" "$INSTALL_PATH"

    cat > /etc/systemd/system/oci-update-ipv6-rule.service <<EOF
[Unit]
Description=Update OCI IPv6 Security List and host firewalls
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
EOF

    cat > /etc/systemd/system/oci-update-ipv6-rule.timer <<EOF
[Unit]
Description=Run IPv6 prefix updater every $TIMER_INTERVAL

[Timer]
OnBootSec=5min
OnUnitActiveSec=$TIMER_INTERVAL
Unit=oci-update-ipv6-rule.service

[Install]
WantedBy=timers.target
EOF

    fix_selinux_contexts
    systemctl daemon-reload
    systemctl enable --now oci-update-ipv6-rule.timer

    log "Installed and started timer: ${YELLOW}$TIMER_INTERVAL${RESET}" "$GREEN"

    # Check service health
    if ! systemctl is-active --quiet oci-update-ipv6-rule.timer; then
        log "⚠ Timer not active. Check systemd logs." "$YELLOW"
    fi
    if ! systemctl is-enabled --quiet oci-update-ipv6-rule.timer; then
        log "⚠ Timer not enabled on boot." "$YELLOW"
    fi
}

uninstall_service() {
    log "Uninstalling service and timer..." "$BLUE"
    systemctl disable --now oci-update-ipv6-rule.timer 2>/dev/null
    rm -f /etc/systemd/system/oci-update-ipv6-rule.{service,timer}
    rm -f "$INSTALL_PATH"
    systemctl daemon-reload
    log "Uninstalled service, timer, and script." "$GREEN"
}

# --- Main ---
case "$1" in
    -h|--help)
        usage
        ;;
    --install)
        install_service
        exit 0
        ;;
    --uninstall)
        uninstall_service
        exit 0
        ;;
    ""|--dry-run)
        # proceed with main workflow
        ;;
    *)
        log "Unknown option: $1" "$RED"
        log "Use --help to view usage information." "$YELLOW"
        exit 1
        ;;
esac

selinux_status
log "--- Starting IPv6 update check ---" "$BLUE"

get_prefix_ssh
if [ -z "$CURRENT_PREFIX" ]; then
    log "Error: could not determine IPv6 prefix" "$RED"
    exit 1
fi
if ! [[ "$CURRENT_PREFIX" == */64 ]]; then
    log "Error: not a /64 prefix: ${YELLOW}$CURRENT_PREFIX${RESET}" "$RED"
    exit 1
fi
log "Discovered prefix: ${YELLOW}$CURRENT_PREFIX${RESET}"

RULES_JSON=$(oci network security-list get --security-list-id "$SEC_LIST_OCID" --query "data.\"ingress-security-rules\"" 2>&1) || {
    log "Error fetching rules from OCI" "$RED"
    exit 1
}

EXISTING_PREFIX=$(echo "$RULES_JSON" | jq -r ".[] | select(.description==\"$RULE_DESCRIPTION\") | .source")
if [ -z "$EXISTING_PREFIX" ] || [ "$EXISTING_PREFIX" == "null" ]; then
    log "Error: Rule $RULE_DESCRIPTION not found" "$RED"
    exit 1
fi
log "Current OCI prefix: ${YELLOW}$EXISTING_PREFIX${RESET}"

if [ "$1" == "--dry-run" ]; then
    log "[Dry run] Would update OCI if prefix differs" "$YELLOW"
    log "[Dry run] Would update local firewall ipset to: ${YELLOW}$CURRENT_PREFIX${RESET}" "$YELLOW"
    log "[Dry run] Would push update to: ${YELLOW}${EXTRA_HOSTS[*]}${RESET}" "$YELLOW"
    exit 0
fi

if [ "$CURRENT_PREFIX" != "$EXISTING_PREFIX" ]; then
    log "Updating OCI rule..." "$BLUE"
    NEW_RULES_JSON=$(echo "$RULES_JSON" | jq "(.[] | select(.description==\"$RULE_DESCRIPTION\").source) |= \"$CURRENT_PREFIX\" ")
    if oci network security-list update --security-list-id "$SEC_LIST_OCID" --ingress-security-rules "$NEW_RULES_JSON" --force; then
        log "OCI updated to ${YELLOW}$CURRENT_PREFIX${RESET}" "$GREEN"
    else
        log "Failed to update OCI" "$RED"
        check_avc
        $STRICT_SELINUX && exit 1
    fi
else
    log "OCI already up to date" "$GREEN"
fi

update_local_fw "$CURRENT_PREFIX"
update_remote_fw "$CURRENT_PREFIX"

log "--- IPv6 update check finished ---" "$BLUE"
exit 0
