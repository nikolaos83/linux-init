#!/bin/bash
#
# oci-update-ipv6-rule.sh
#
# Purpose:
#   Keeps Oracle Cloud Infrastructure (OCI) Security List *and* host firewalls
#   (local + remote) in sync with the current dynamic IPv6 prefix.
#
# Features:
#   - Detect current /64 prefix from a router via SSH
#   - Update OCI Security List ingress rule (by description)
#   - Update local firewall using firewalld + ipset (accept all traffic from prefix)
#   - Update remote firewalls on extra hosts via SSH
#   - SELinux aware: logs mode, fixes contexts for systemd units, inspects AVC denials
#   - Can install itself as a systemd service + timer (`--install`)
#   - Dry-run mode (`--dry-run`) to preview changes without applying
#   - Detailed logging to $LOG_FILE
#
# Usage:
#   ./oci-update-ipv6-rule.sh            Run once (update OCI + firewalls)
#   ./oci-update-ipv6-rule.sh --install  Install systemd service + timer
#   ./oci-update-ipv6-rule.sh --dry-run  Show what would change, but do nothing
#   ./oci-update-ipv6-rule.sh -h|--help  Print this help message
#
# Default configuration can be edited in the section below.
#

# --- Default Configuration ---
SEC_LIST_OCID="$Oracle_VCN_Security_List_OCID"
RULE_DESCRIPTION="ALLOW_HOME_NETWORK@NET28"
SSH_USER_HOST="root@msm"
EXTRA_HOSTS=("m1" "m2")
TIMER_INTERVAL="5min"
LOG_FILE="/var/log/oci_ipv6_update.log"
STRICT_SELINUX=true
# --- End Configuration ---


# --- Helper Functions ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

usage() {
    grep "^# " "$0" | sed 's/^# //'
    exit 0
}

selinux_status() {
    if command -v getenforce >/dev/null; then
        local mode=$(getenforce)
        log "SELinux mode: $mode"
        [ "$mode" = "Enforcing" ] && log "⚠️ SELinux is enforcing — policy denials may block updates."
    fi
}

fix_selinux_contexts() {
    if command -v restorecon >/dev/null; then
        restorecon -v /etc/systemd/system/oci-update-ipv6-rule.{service,timer} 2>&1 | tee -a "$LOG_FILE"
    fi
}

check_avc() {
    if [ -f /var/log/audit/audit.log ]; then
        local denials
        denials=$(tail -n 50 /var/log/audit/audit.log | grep AVC | tail -n 5)
        [ -n "$denials" ] && log "Recent SELinux denials detected:\n$denials"
    fi
}

get_prefix_ssh() {
    log "Attempting to get IPv6 prefix via SSH from $SSH_USER_HOST..."
    CURRENT_PREFIX=$(ssh "$SSH_USER_HOST" "rdisc6 -1 wlan0" | awk '/Prefix/ {print $3; exit}')
}

update_local_fw() {
    local prefix=$1
    local ipset_name="home6"

    log "Updating local firewall for prefix $prefix"

    firewall-cmd --permanent --get-ipsets | grep -q "^$ipset_name$" || \
        firewall-cmd --permanent --new-ipset=$ipset_name --type=hash:net --family=ipv6

    firewall-cmd --permanent --zone=public --query-rich-rule="rule family=ipv6 source ipset=$ipset_name accept" >/dev/null 2>&1 || \
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv6 source ipset=$ipset_name accept"

    for entry in $(firewall-cmd --ipset=$ipset_name --get-entries); do
        firewall-cmd --permanent --ipset=$ipset_name --remove-entry=$entry
    done

    firewall-cmd --permanent --ipset=$ipset_name --add-entry=$prefix

    if ! firewall-cmd --reload; then
        log "❌ firewalld reload failed (possible SELinux denial)"
        check_avc
        $STRICT_SELINUX && exit 1
    fi
}

update_remote_fw() {
    local prefix=$1
    for host in "${EXTRA_HOSTS[@]}"; do
        log "Updating firewall on $host for prefix $prefix"
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

    cat > /etc/systemd/system/oci-update-ipv6-rule.service <<EOF
[Unit]
Description=Update OCI IPv6 Security List and host firewalls
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$0
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
    echo "Installed and started timer ($TIMER_INTERVAL)"
}

# --- Main ---
if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    usage
fi

if [ "$1" == "--install" ]; then
    install_service
    exit 0
fi

selinux_status
log "--- Starting IPv6 update check ---"

get_prefix_ssh
if [ -z "$CURRENT_PREFIX" ]; then
    log "Error: Could not determine current IPv6 prefix."
    exit 1
fi

if ! [[ "$CURRENT_PREFIX" == */64 ]]; then
    log "Error: Not a /64 prefix: $CURRENT_PREFIX"
    exit 1
fi

log "Discovered prefix: $CURRENT_PREFIX"

RULES_JSON=$(oci network security-list get --security-list-id "$SEC_LIST_OCID" --query "data.\"ingress-security-rules\"" 2>&1) || {
    log "Error fetching rules from OCI"
    exit 1
}

EXISTING_PREFIX=$(echo "$RULES_JSON" | jq -r ".[] | select(.description==\"$RULE_DESCRIPTION\") | .source")
if [ -z "$EXISTING_PREFIX" ] || [ "$EXISTING_PREFIX" == "null" ]; then
    log "Error: Rule with description $RULE_DESCRIPTION not found"
    exit 1
fi

log "Current OCI prefix: $EXISTING_PREFIX"

if [ "$1" == "--dry-run" ]; then
    log "[Dry run] Would update OCI rule if prefix differs."
    log "[Dry run] Would update local firewall ipset to: $CURRENT_PREFIX"
    log "[Dry run] Would push update to: ${EXTRA_HOSTS[*]}"
    exit 0
fi

if [ "$CURRENT_PREFIX" != "$EXISTING_PREFIX" ]; then
    log "Updating OCI rule..."
    NEW_RULES_JSON=$(echo "$RULES_JSON" | jq "(.[] | select(.description==\"$RULE_DESCRIPTION\").source) |= \"$CURRENT_PREFIX\" ")
    if oci network security-list update --security-list-id "$SEC_LIST_OCID" --ingress-security-rules "$NEW_RULES_JSON" --force; then
        log "✅ OCI updated to $CURRENT_PREFIX"
    else
        log "❌ Failed to update OCI"
        check_avc
        $STRICT_SELINUX && exit 1
    fi
else
    log "OCI already up to date"
fi

update_local_fw "$CURRENT_PREFIX"
update_remote_fw "$CURRENT_PREFIX"

log "--- IPv6 update check finished ---"
exit 0
