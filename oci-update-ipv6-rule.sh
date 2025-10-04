#!/bin/bash
set -o errexit
set -o pipefail

CONFIG_PATH="/etc/oci-update-ipv6-rule.conf"
RUNNER_PATH="/usr/local/sbin/oci-update-ipv6-autopilot"
INSTALL_PATH="/usr/local/bin/oci-update-ipv6-rule"
SERVICE_PATH="/etc/systemd/system/oci-update-ipv6-rule.service"
TIMER_PATH="/etc/systemd/system/oci-update-ipv6-rule.timer"

DEFAULT_SEC_LIST_OCID="${Oracle_VCN_Security_List_OCID:-}"
DEFAULT_RULE_DESCRIPTION="ALLOW_HOME_NETWORK@NET28"
DEFAULT_SSH_USER_HOST="root@msm"
DEFAULT_EXTRA_HOSTS="m1 m2"
DEFAULT_TIMER_INTERVAL="5min"
DEFAULT_LOG_FILE="/var/log/oci_ipv6_update.log"
DEFAULT_IPSET_NAME="home6"
DEFAULT_PREFIX_COMMAND="rdisc6 -1 wlan0 | awk '/Prefix/ {print \$3; exit}'"
DEFAULT_STRICT_SELINUX="true"

SEC_LIST_OCID="$DEFAULT_SEC_LIST_OCID"
RULE_DESCRIPTION="$DEFAULT_RULE_DESCRIPTION"
SSH_USER_HOST="$DEFAULT_SSH_USER_HOST"
EXTRA_HOSTS_STRING="$DEFAULT_EXTRA_HOSTS"
TIMER_INTERVAL="$DEFAULT_TIMER_INTERVAL"
LOG_FILE="$DEFAULT_LOG_FILE"
IPSET_NAME="$DEFAULT_IPSET_NAME"
PREFIX_COMMAND="$DEFAULT_PREFIX_COMMAND"
STRICT_SELINUX="$DEFAULT_STRICT_SELINUX"

DRY_RUN=false
ACTION="run"

RESET="\033[0m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"

supports_color() {
    [ -t 1 ] || return 1
    local term=${TERM:-}
    [[ -n "$term" && "$term" != "dumb" ]]
}

if ! supports_color; then
    RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""
fi

strip_ansi() {
    sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

highlight() {
    local colour="$1"
    shift
    printf '%s%s%s' "$colour" "$*" "$RESET"
}

log() {
    local level="$1"
    shift
    local message="$*"
    local colour="$RESET"
    case "$level" in
        INFO) colour="$BLUE" ;;
        WARN) colour="$YELLOW" ;;
        ERROR) colour="$RED" ;;
        SUCCESS) colour="$GREEN" ;;
        DEBUG) colour="$CYAN" ;;
    esac
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="${ts} [${level}] ${message}"
    echo -e "${colour}${line}${RESET}"
    if [ -n "${LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        printf '%s\n' "$(printf '%s' "$line" | strip_ansi)" >> "$LOG_FILE"
    fi
}

usage() {
    cat <<USAGE
${BOLD}OCI IPv6 updater${RESET}

Usage: $0 [--install|--uninstall|--run|--dry-run|--check-services|--config <path>|--help]
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install) ACTION="install" ;;
            --uninstall) ACTION="uninstall" ;;
            --run) ACTION="run" ;;
            --dry-run) DRY_RUN=true ;;
            --check-services) ACTION="check" ;;
            --config) CONFIG_PATH="$2"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log ERROR "Unknown argument: $1"; usage; exit 1 ;;
        esac
        shift
    done
}

load_config() {
    if [ -f "$CONFIG_PATH" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_PATH"
    fi
    SEC_LIST_OCID="${SEC_LIST_OCID:-$DEFAULT_SEC_LIST_OCID}"
    RULE_DESCRIPTION="${RULE_DESCRIPTION:-$DEFAULT_RULE_DESCRIPTION}"
    SSH_USER_HOST="${SSH_USER_HOST:-$DEFAULT_SSH_USER_HOST}"
    EXTRA_HOSTS_STRING="${EXTRA_HOSTS_STRING:-$DEFAULT_EXTRA_HOSTS}"
    TIMER_INTERVAL="${TIMER_INTERVAL:-$DEFAULT_TIMER_INTERVAL}"
    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    IPSET_NAME="${IPSET_NAME:-$DEFAULT_IPSET_NAME}"
    PREFIX_COMMAND="${PREFIX_COMMAND:-$DEFAULT_PREFIX_COMMAND}"
    STRICT_SELINUX="${STRICT_SELINUX:-$DEFAULT_STRICT_SELINUX}"
    # shellcheck disable=SC2206
    EXTRA_HOSTS=(${EXTRA_HOSTS_STRING})
}


ensure_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log ERROR "Required command $(highlight "$RED" "$cmd") is missing."
        exit 1
    fi
}

check_dependencies() {
    ensure_command jq
    ensure_command oci
    ensure_command firewall-cmd
    ensure_command ssh
    ensure_command systemctl
}

selinux_status() {
    if command -v getenforce >/dev/null 2>&1; then
        local mode
        mode=$(getenforce)
        if [ "$mode" = "Enforcing" ]; then
            log INFO "SELinux status: $(highlight "$CYAN" "$mode")"
        else
            log WARN "SELinux status: $(highlight "$YELLOW" "$mode")"
        fi
    fi
}

apply_selinux_contexts() {
    local files=()
    [ -e "$INSTALL_PATH" ] && files+=("$INSTALL_PATH")
    [ -e "$RUNNER_PATH" ] && files+=("$RUNNER_PATH")
    [ -e "$SERVICE_PATH" ] && files+=("$SERVICE_PATH")
    [ -e "$TIMER_PATH" ] && files+=("$TIMER_PATH")
    [ -n "$LOG_FILE" ] && files+=("$LOG_FILE")

    if command -v restorecon >/dev/null 2>&1 && [ "${#files[@]}" -gt 0 ]; then
        restorecon -Rv "${files[@]}" >/dev/null 2>&1 || true
    fi
}

auto_heal_selinux() {
    [ "${STRICT_SELINUX,,}" = "true" ] || return
    if ! command -v ausearch >/dev/null 2>&1 || ! command -v audit2allow >/dev/null 2>&1; then
        return
    fi
    local denials
    denials=$(ausearch -m AVC -ts recent 2>/dev/null | grep -E 'oci-update-ipv6|firewall-cmd' || true)
    [ -z "$denials" ] && return

    log WARN "SELinux denials detected; attempting policy adjustment."
    local tmpdir
    tmpdir=$(mktemp -d)
    pushd "$tmpdir" >/dev/null || return
    echo "$denials" | audit2allow -M oci_ipv6_update >/dev/null 2>&1 || true
    if [ -f oci_ipv6_update.pp ]; then
        if semodule -i oci_ipv6_update.pp >/dev/null 2>&1; then
            log SUCCESS "Installed SELinux policy module for the updater."
        else
            log WARN "Failed to install SELinux module automatically."
        fi
    else
        log WARN "audit2allow produced no module; review denials manually."
    fi
    popd >/dev/null || true
    rm -rf "$tmpdir"
}

check_recent_selinux_denials() {
    if [ -f /var/log/audit/audit.log ]; then
        local denials
        denials=$(tail -n 50 /var/log/audit/audit.log | grep AVC || true)
        [ -n "$denials" ] && log WARN "Recent SELinux AVC entries detected."
    fi
}

sanity_check() {
    local issues=0
    if [ -z "$SEC_LIST_OCID" ]; then
        log WARN "OCI security list OCID is empty."
        issues=$((issues + 1))
    fi
    if [ -z "$RULE_DESCRIPTION" ]; then
        log WARN "Rule description is empty."
        issues=$((issues + 1))
    fi
    if [ -z "$SSH_USER_HOST" ]; then
        log WARN "Router SSH host is undefined."
        issues=$((issues + 1))
    fi
    if [ -z "$PREFIX_COMMAND" ]; then
        log WARN "Prefix discovery command is empty."
        issues=$((issues + 1))
    fi

    if ! firewall-cmd --state >/dev/null 2>&1; then
        log WARN "firewalld appears inactive."
        issues=$((issues + 1))
    fi

    if ! systemctl is-active firewalld >/dev/null 2>&1; then
        log WARN "firewalld service is not active according to systemd."
    fi

    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER_HOST" true >/dev/null 2>&1; then
        log WARN "Unable to reach router $(highlight "$YELLOW" "$SSH_USER_HOST") without interaction."
        issues=$((issues + 1))
    fi

    if [ "${#EXTRA_HOSTS[@]}" -eq 0 ]; then
        log WARN "No extra hosts configured for firewall updates."
    fi

    if [ "$issues" -gt 0 ]; then
        log WARN "Sanity check detected $issues potential issue(s)."
    else
        log SUCCESS "Sanity check passed."
    fi
}

ssh_prefix_query() {
    log INFO "Querying IPv6 prefix from $(highlight "$CYAN" "$SSH_USER_HOST")"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER_HOST" "$PREFIX_COMMAND" | head -n 1
}

fetch_current_prefix() {
    local prefix
    prefix=$(ssh_prefix_query)
    prefix=${prefix//$'\r'/}
    echo "$prefix"
}

fetch_existing_oci_prefix() {
    local rules_json
    if ! rules_json=$(oci network security-list get --security-list-id "$SEC_LIST_OCID" --query 'data."ingress-security-rules"' 2>/dev/null); then
        log ERROR "Failed to query OCI security list."
        return 1
    fi
    local existing
    existing=$(echo "$rules_json" | jq -r --arg desc "$RULE_DESCRIPTION" '.[] | select(.description==$desc) | .source')
    if [ -z "$existing" ] || [ "$existing" = "null" ]; then
        log ERROR "Rule $(highlight "$RED" "$RULE_DESCRIPTION") not found in OCI security list."
        return 1
    fi
    echo "$existing"
}

update_oci_prefix() {
    local current="$1"
    local rules_json
    rules_json=$(oci network security-list get --security-list-id "$SEC_LIST_OCID" --query 'data."ingress-security-rules"' 2>/dev/null)
    local new_rules
    new_rules=$(echo "$rules_json" | jq --arg desc "$RULE_DESCRIPTION" --arg prefix "$current" '(.[] | select(.description==$desc).source) = $prefix')
    if ! oci network security-list update --security-list-id "$SEC_LIST_OCID" --ingress-security-rules "$new_rules" --force >/dev/null; then
        log ERROR "Failed to update OCI security list."
        check_recent_selinux_denials
        return 1
    fi
    log SUCCESS "Updated OCI security list to prefix $(highlight "$GREEN" "$current")"
    return 0
}

ensure_ipset_exists() {
    if ! firewall-cmd --permanent --get-ipsets | grep -q "^$IPSET_NAME$"; then
        log INFO "Creating ipset $(highlight "$CYAN" "$IPSET_NAME")"
        firewall-cmd --permanent --new-ipset="$IPSET_NAME" --type=hash:net --family=ipv6 >/dev/null
    fi
    if ! firewall-cmd --permanent --zone=public --query-rich-rule="rule family=ipv6 source ipset=$IPSET_NAME accept" >/dev/null 2>&1; then
        log INFO "Allowing ipset $(highlight "$CYAN" "$IPSET_NAME") in public zone"
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv6 source ipset=$IPSET_NAME accept" >/dev/null
    fi
}

update_local_firewall() {
    local prefix="$1"
    log INFO "Refreshing local ipset $(highlight "$CYAN" "$IPSET_NAME") with prefix $(highlight "$CYAN" "$prefix")"
    ensure_ipset_exists
    for entry in $(firewall-cmd --permanent --ipset="$IPSET_NAME" --get-entries); do
        firewall-cmd --permanent --ipset="$IPSET_NAME" --remove-entry="$entry" >/dev/null
    done
    firewall-cmd --permanent --ipset="$IPSET_NAME" --add-entry="$prefix" >/dev/null
    if firewall-cmd --reload >/dev/null; then
        log SUCCESS "Local firewall now permits $(highlight "$GREEN" "$prefix")"
    else
        log ERROR "firewalld reload failed; SELinux may be blocking the action."
        check_recent_selinux_denials
        auto_heal_selinux
        [ "${STRICT_SELINUX,,}" = "true" ] && exit 1
    fi
}

format_remote_target() {
    local host="$1"
    if [[ "$host" == *@* ]]; then
        echo "$host"
    else
        echo "root@$host"
    fi
}

update_remote_firewall() {
    local prefix="$1"
    for host in "${EXTRA_HOSTS[@]}"; do
        [ -z "$host" ] && continue
        local target
        target=$(format_remote_target "$host")
        log INFO "Updating host $(highlight "$CYAN" "$target") with prefix $(highlight "$CYAN" "$prefix")"
        if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "bash -s" -- "$prefix" "$IPSET_NAME" <<'EOSSH'
#!/bin/bash
set -o errexit
PREFIX="$1"
SET_NAME="$2"
if ! command -v firewall-cmd >/dev/null 2>&1; then
    exit 1
fi
if ! firewall-cmd --permanent --get-ipsets | grep -q "^$SET_NAME$"; then
    firewall-cmd --permanent --new-ipset="$SET_NAME" --type=hash:net --family=ipv6 >/dev/null
fi
if ! firewall-cmd --permanent --zone=public --query-rich-rule="rule family=ipv6 source ipset=$SET_NAME accept" >/dev/null 2>&1; then
    firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv6 source ipset=$SET_NAME accept" >/dev/null
fi
for entry in $(firewall-cmd --permanent --ipset="$SET_NAME" --get-entries); do
    firewall-cmd --permanent --ipset="$SET_NAME" --remove-entry="$entry" >/dev/null
done
firewall-cmd --permanent --ipset="$SET_NAME" --add-entry="$PREFIX" >/dev/null
firewall-cmd --reload >/dev/null
EOSSH
        then
            log WARN "Failed to update host $(highlight "$YELLOW" "$target")"
        else
            log SUCCESS "Host $(highlight "$GREEN" "$target") accepts prefix $(highlight "$GREEN" "$prefix")"
        fi
    done
}

check_service_health() {
    local units=("oci-update-ipv6-rule.service" "oci-update-ipv6-rule.timer")
    for unit in "${units[@]}"; do
        if systemctl list-units --full --all "$unit" >/dev/null 2>&1; then
            local state
            state=$(systemctl is-active "$unit" 2>/dev/null || true)
            local enabled
            enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
            if [ "$state" = "active" ] || [ "$state" = "activating" ]; then
                log SUCCESS "$unit is $(highlight "$GREEN" "$state") and $(highlight "$GREEN" "$enabled")"
            else
                log WARN "$unit is $(highlight "$YELLOW" "$state") and $(highlight "$YELLOW" "$enabled"). Check journalctl -u $unit."
            fi
        else
            log WARN "Systemd unit $(highlight "$YELLOW" "$unit") not found"
        fi
    done
    if systemctl list-timers oci-update-ipv6-rule.timer >/dev/null 2>&1; then
        systemctl list-timers oci-update-ipv6-rule.timer
    fi
}

write_config() {
    cat > "$CONFIG_PATH" <<EOF
# Autogenerated by oci-update-ipv6-rule.sh on $(date)
SEC_LIST_OCID="$SEC_LIST_OCID"
RULE_DESCRIPTION="$RULE_DESCRIPTION"
SSH_USER_HOST="$SSH_USER_HOST"
EXTRA_HOSTS_STRING="${EXTRA_HOSTS[*]}"
TIMER_INTERVAL="$TIMER_INTERVAL"
LOG_FILE="$LOG_FILE"
IPSET_NAME="$IPSET_NAME"
PREFIX_COMMAND="$PREFIX_COMMAND"
STRICT_SELINUX="$STRICT_SELINUX"
EOF
    chmod 600 "$CONFIG_PATH"
    log SUCCESS "Wrote configuration to $(highlight "$GREEN" "$CONFIG_PATH")"
}

generate_runner() {
    cat > "$RUNNER_PATH" <<CONFIG
#!/bin/bash
exec "$INSTALL_PATH" --run --config "$CONFIG_PATH"
CONFIG
    chmod 755 "$RUNNER_PATH"
    log SUCCESS "Generated autopilot helper $(highlight "$GREEN" "$RUNNER_PATH")"
}

install_units() {
    cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=Update OCI IPv6 Security List and host firewalls
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNNER_PATH
StandardOutput=journal
StandardError=journal
SERVICE

    cat > "$TIMER_PATH" <<TIMER
[Unit]
Description=Run OCI IPv6 updater regularly ($TIMER_INTERVAL)

[Timer]
OnBootSec=5min
OnUnitActiveSec=$TIMER_INTERVAL
AccuracySec=1min
Unit=$(basename "$SERVICE_PATH")

[Install]
WantedBy=timers.target
TIMER
    chmod 644 "$SERVICE_PATH" "$TIMER_PATH"
    log SUCCESS "Installed systemd unit files"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log ERROR "This operation requires root privileges."
        exit 1
    fi
}

install_stack() {
    require_root
    load_config

    read -rp "OCI Security List OCID [$SEC_LIST_OCID]: " input
    [ -n "$input" ] && SEC_LIST_OCID="$input"

    read -rp "Rule description [$RULE_DESCRIPTION]: " input
    [ -n "$input" ] && RULE_DESCRIPTION="$input"

    read -rp "Router SSH user@host [$SSH_USER_HOST]: " input
    [ -n "$input" ] && SSH_USER_HOST="$input"

    read -rp "Extra hosts (space separated) [$EXTRA_HOSTS_STRING]: " input
    [ -n "$input" ] && EXTRA_HOSTS_STRING="$input"
    # shellcheck disable=SC2206
    EXTRA_HOSTS=(${EXTRA_HOSTS_STRING})

    read -rp "Timer interval [$TIMER_INTERVAL]: " input
    [ -n "$input" ] && TIMER_INTERVAL="$input"

    read -rp "Prefix discovery command [$PREFIX_COMMAND]: " input
    [ -n "$input" ] && PREFIX_COMMAND="$input"

    install -m 755 "$0" "$INSTALL_PATH"
    write_config
    generate_runner
    install_units
    apply_selinux_contexts
    systemctl daemon-reload
    systemctl enable --now oci-update-ipv6-rule.timer
    log SUCCESS "Systemd timer enabled with interval $(highlight "$GREEN" "$TIMER_INTERVAL")"
    check_service_health
}

uninstall_stack() {
    require_root
    systemctl disable --now oci-update-ipv6-rule.timer >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH" "$TIMER_PATH" "$RUNNER_PATH" "$INSTALL_PATH"
    rm -f "$CONFIG_PATH"
    systemctl daemon-reload
    log SUCCESS "Removed OCI IPv6 updater stack"
}

run_update() {
    load_config
    check_dependencies
    selinux_status
    sanity_check

    local current_prefix existing_prefix
    current_prefix=$(fetch_current_prefix)
    if [ -z "$current_prefix" ]; then
        log ERROR "Failed to determine IPv6 prefix"
        exit 1
    fi

    if [[ "$current_prefix" != */64 ]]; then
        log ERROR "Discovered prefix $(highlight "$RED" "$current_prefix") is not a /64"
        exit 1
    fi

    log INFO "Discovered prefix $(highlight "$CYAN" "$current_prefix")"

    existing_prefix=$(fetch_existing_oci_prefix)
    if [ -z "$existing_prefix" ]; then
        exit 1
    fi
    log INFO "Current OCI prefix $(highlight "$CYAN" "$existing_prefix")"

    if $DRY_RUN; then
        log WARN "Dry-run: would update OCI rule if prefixes differ"
        log WARN "Dry-run: would sync local firewall to $(highlight "$YELLOW" "$current_prefix")"
        log WARN "Dry-run: would push to hosts $(highlight "$YELLOW" "${EXTRA_HOSTS[*]}")"
        return
    fi

    if [ "$current_prefix" != "$existing_prefix" ]; then
        log INFO "Prefix differs; updating OCI security list"
        update_oci_prefix "$current_prefix" || exit 1
    else
        log SUCCESS "OCI security list already matches $(highlight "$GREEN" "$current_prefix")"
    fi

    update_local_firewall "$current_prefix"
    update_remote_firewall "$current_prefix"
    apply_selinux_contexts
    auto_heal_selinux
    check_service_health
}

main() {
    parse_args "$@"
    case "$ACTION" in
        run)
            run_update
            ;;
        install)
            install_stack
            ;;
        uninstall)
            uninstall_stack
            ;;
        check)
            load_config
            check_service_health
            ;;
    esac
}

main "$@"
