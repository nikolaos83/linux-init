#!/bin/bash
#
# oci-update-ipv6-rule.sh
#
# Keeps an OCI security list and the firewalld ipset on a fleet of hosts in
# sync with the currently advertised IPv6 prefix.  The script can be run once,
# used to configure the environment, or install a systemd timer that performs
# the update automatically from a copy stored under /usr/local.
#
# Features
#   * Discovers the active IPv6 prefix from a router via SSH.
#   * Updates a specific OCI ingress security rule when the prefix changes.
#   * Synchronises the local firewalld ipset and pushes the update to peers.
#   * Handles SELinux contexts for the created files.
#   * Provides verbose, colourised logging and health checks.
#
# Usage examples:
#   ./oci-update-ipv6-rule.sh --configure    # interactive configuration only
#   ./oci-update-ipv6-rule.sh --run-once     # run a single synchronisation
#   ./oci-update-ipv6-rule.sh --install      # run once then install timer
#   ./oci-update-ipv6-rule.sh --uninstall    # remove the timer and copy
#   ./oci-update-ipv6-rule.sh --status       # report service/timer status
#   ./oci-update-ipv6-rule.sh --dry-run      # preview actions without changes
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="/etc/oci-update-ipv6-rule.conf"
INSTALL_PATH="/usr/local/libexec/oci-update-ipv6-rule.sh"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="oci-update-ipv6-rule.service"
TIMER_NAME="oci-update-ipv6-rule.timer"
DEFAULT_LOG_FILE="/var/log/oci_ipv6_update.log"

# Defaults that can be overridden in the config file.
DEFAULT_RULE_DESCRIPTION="ALLOW_HOME_NETWORK@NET28"
DEFAULT_SSH_USER_HOST="root@msm"
DEFAULT_EXTRA_HOSTS=("m1" "m2")
DEFAULT_TIMER_INTERVAL="5min"
DEFAULT_ROUTER_INTERFACE="wlan0"
DEFAULT_PREFIX_DISCOVERY_TEMPLATE="rdisc6 -1 %IF%"
DEFAULT_PREFIX_DISCOVERY_COMMAND="${DEFAULT_PREFIX_DISCOVERY_TEMPLATE//%IF%/$DEFAULT_ROUTER_INTERFACE}"
DEFAULT_IPSET_NAME="home6"
DEFAULT_FIREWALL_ZONE="public"
DEFAULT_PREFIX_LENGTH="64"
DEFAULT_STRICT_SELINUX="true"

# Colours.
RESET="\033[0m"
BOLD="\033[1m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"

DRY_RUN=false
SELINUX_MODE="unknown"

SEC_LIST_OCID=""
RULE_DESCRIPTION="$DEFAULT_RULE_DESCRIPTION"
SSH_USER_HOST="$DEFAULT_SSH_USER_HOST"
TIMER_INTERVAL="$DEFAULT_TIMER_INTERVAL"
ROUTER_INTERFACE="$DEFAULT_ROUTER_INTERFACE"
PREFIX_DISCOVERY_COMMAND="$DEFAULT_PREFIX_DISCOVERY_COMMAND"
IPSET_NAME="$DEFAULT_IPSET_NAME"
FIREWALL_ZONE="$DEFAULT_FIREWALL_ZONE"
PREFIX_LENGTH="$DEFAULT_PREFIX_LENGTH"
STRICT_SELINUX="$DEFAULT_STRICT_SELINUX"
LOG_FILE="$DEFAULT_LOG_FILE"
declare -a EXTRA_HOSTS=("${DEFAULT_EXTRA_HOSTS[@]}")

CURRENT_PREFIX=""
CURRENT_OCI_PREFIX=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_base() {
    local level="$1"
    local colour="$2"
    shift 2
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ -t 1 ]]; then
        printf '%s [%s] %b%s%b\n' "$timestamp" "$level" "$colour" "$message" "$RESET" | tee -a "$LOG_FILE"
    else
        printf '%s [%s] %s\n' "$timestamp" "$level" "$message" | tee -a "$LOG_FILE"
    fi
}

log_info()    { log_base INFO "$BLUE"    "$*"; }
log_success() { log_base OK   "$GREEN"   "$*"; }
log_warn()    { log_base WARN "$YELLOW" "$*"; }
log_error()   { log_base ERR  "$RED"    "$*"; }

highlight() {
    local colour="$1"
    shift
    printf '%b%s%b' "$colour" "$*" "$RESET"
}

fatal() {
    log_error "$*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line=$1
    log_error "Aborted at line ${line} (exit code ${exit_code})."
    report_selinux_denials
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------
ensure_log_file() {
    local dir
    dir=$(dirname "$LOG_FILE")
    mkdir -p "$dir"
    touch "$LOG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    RULE_DESCRIPTION=${RULE_DESCRIPTION:-$DEFAULT_RULE_DESCRIPTION}
    SSH_USER_HOST=${SSH_USER_HOST:-$DEFAULT_SSH_USER_HOST}
    TIMER_INTERVAL=${TIMER_INTERVAL:-$DEFAULT_TIMER_INTERVAL}
    ROUTER_INTERFACE=${ROUTER_INTERFACE:-$DEFAULT_ROUTER_INTERFACE}
    PREFIX_DISCOVERY_COMMAND=${PREFIX_DISCOVERY_COMMAND:-${DEFAULT_PREFIX_DISCOVERY_TEMPLATE//%IF%/$ROUTER_INTERFACE}}
    IPSET_NAME=${IPSET_NAME:-$DEFAULT_IPSET_NAME}
    FIREWALL_ZONE=${FIREWALL_ZONE:-$DEFAULT_FIREWALL_ZONE}
    PREFIX_LENGTH=${PREFIX_LENGTH:-$DEFAULT_PREFIX_LENGTH}
    STRICT_SELINUX=${STRICT_SELINUX:-$DEFAULT_STRICT_SELINUX}
    LOG_FILE=${LOG_FILE:-$DEFAULT_LOG_FILE}

    if ! declare -p EXTRA_HOSTS >/dev/null 2>&1; then
        EXTRA_HOSTS=("${DEFAULT_EXTRA_HOSTS[@]}")
    fi
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    {
        echo "# Generated by ${SCRIPT_NAME} on $(date)"
        declare -p SEC_LIST_OCID RULE_DESCRIPTION SSH_USER_HOST ROUTER_INTERFACE \
            PREFIX_DISCOVERY_COMMAND FIREWALL_ZONE IPSET_NAME TIMER_INTERVAL \
            PREFIX_LENGTH STRICT_SELINUX LOG_FILE EXTRA_HOSTS
    } >"${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_success "Configuration saved to $(highlight "$MAGENTA" "$CONFIG_FILE")"
}

prompt_for_value() {
    local var_name="$1"
    local prompt_text="$2"
    local current_value="$3"
    local input=""

    read -r -p "${prompt_text} [${current_value}]: " input
    if [[ -n "$input" ]]; then
        printf -v "$var_name" '%s' "$input"
    fi
}

interactive_configure() {
    log_info "Starting interactive configuration."

    prompt_for_value SEC_LIST_OCID "OCI Security List OCID" "$SEC_LIST_OCID"
    prompt_for_value RULE_DESCRIPTION "Rule description" "$RULE_DESCRIPTION"
    prompt_for_value SSH_USER_HOST "Router SSH user@host" "$SSH_USER_HOST"
    prompt_for_value ROUTER_INTERFACE "Router interface" "$ROUTER_INTERFACE"
    prompt_for_value PREFIX_DISCOVERY_COMMAND "Prefix discovery command" "$PREFIX_DISCOVERY_COMMAND"
    prompt_for_value TIMER_INTERVAL "Timer interval" "$TIMER_INTERVAL"
    prompt_for_value IPSET_NAME "Local ipset name" "$IPSET_NAME"
    prompt_for_value FIREWALL_ZONE "firewalld zone" "$FIREWALL_ZONE"
    prompt_for_value PREFIX_LENGTH "Expected prefix length" "$PREFIX_LENGTH"
    prompt_for_value LOG_FILE "Log file" "$LOG_FILE"

    local hosts_input
    read -r -p "Additional hosts to update (space separated) [${EXTRA_HOSTS[*]}]: " hosts_input
    if [[ -n "$hosts_input" ]]; then
        # shellcheck disable=SC2206
        EXTRA_HOSTS=($hosts_input)
    fi

    local selinux_input
    read -r -p "Abort on SELinux denials? (true/false) [$STRICT_SELINUX]: " selinux_input
    if [[ -n "$selinux_input" ]]; then
        STRICT_SELINUX="$selinux_input"
    fi

    validate_config
    save_config
}

validate_config() {
    [[ -z "$SEC_LIST_OCID" ]] && fatal "SEC_LIST_OCID is not configured."
    [[ -z "$SSH_USER_HOST" ]] && fatal "SSH_USER_HOST is not configured."
    [[ -z "$RULE_DESCRIPTION" ]] && fatal "RULE_DESCRIPTION is not configured."
    [[ -z "$IPSET_NAME" ]] && fatal "IPSET_NAME is not configured."
    [[ -z "$FIREWALL_ZONE" ]] && fatal "FIREWALL_ZONE is not configured."
    [[ -z "$TIMER_INTERVAL" ]] && fatal "TIMER_INTERVAL is not configured."
    [[ -z "$PREFIX_DISCOVERY_COMMAND" ]] && fatal "PREFIX_DISCOVERY_COMMAND is not configured."
}

# ---------------------------------------------------------------------------
# Environment & SELinux helpers
# ---------------------------------------------------------------------------
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        fatal "This script must be run as root."
    fi
}

check_dependencies() {
    local missing=()
    local dep
    for dep in ssh jq oci firewall-cmd systemctl awk sed; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required commands: ${missing[*]}"
    fi
}

selinux_status() {
    if command -v getenforce >/dev/null 2>&1; then
        SELINUX_MODE=$(getenforce)
        case "$SELINUX_MODE" in
            Enforcing)
                log_warn "SELinux mode: $(highlight "$YELLOW" "$SELINUX_MODE")"
                ;;
            Permissive)
                log_info "SELinux mode: $(highlight "$CYAN" "$SELINUX_MODE")"
                ;;
            Disabled)
                log_info "SELinux mode: $(highlight "$GREEN" "$SELINUX_MODE")"
                ;;
            *)
                log_info "SELinux mode: $SELINUX_MODE"
                ;;
        esac
    else
        SELINUX_MODE="unknown"
        log_warn "getenforce not found; SELinux status unknown."
    fi
}

ensure_selinux_contexts() {
    local targets=()
    [[ -f "$CONFIG_FILE" ]] && targets+=("$CONFIG_FILE")
    [[ -f "$LOG_FILE" ]] && targets+=("$LOG_FILE")
    [[ -f "$INSTALL_PATH" ]] && targets+=("$INSTALL_PATH")
    [[ -f "$SYSTEMD_DIR/$SERVICE_NAME" ]] && targets+=("$SYSTEMD_DIR/$SERVICE_NAME")
    [[ -f "$SYSTEMD_DIR/$TIMER_NAME" ]] && targets+=("$SYSTEMD_DIR/$TIMER_NAME")

    if [[ ${#targets[@]} -gt 0 ]] && command -v restorecon >/dev/null 2>&1; then
        log_info "Refreshing SELinux contexts for managed files."
        if ! restorecon -Fv "${targets[@]}" >>"$LOG_FILE" 2>&1; then
            log_warn "restorecon reported issues; review SELinux policy if problems persist."
        fi
    fi
}

report_selinux_denials() {
    [[ ! -f /var/log/audit/audit.log ]] && return
    command -v ausearch >/dev/null 2>&1 || return
    local denials
    denials=$(ausearch -m AVC -ts recent 2>/dev/null | tail -n 20 || true)
    if [[ -n "$denials" ]]; then
        log_warn "Recent SELinux denials detected:\n$denials"
        log_warn "Consider:\n  ausearch -m AVC -ts recent | audit2allow -M oci-ipv6\n  semodule -i oci-ipv6.pp"
    fi
}

# ---------------------------------------------------------------------------
# Core functionality
# ---------------------------------------------------------------------------
current_ipset_entries() {
    firewall-cmd --permanent --ipset="$IPSET_NAME" --get-entries 2>/dev/null || true
}

discover_prefix() {
    log_info "Querying IPv6 prefix from $(highlight "$MAGENTA" "$SSH_USER_HOST") using $(highlight "$CYAN" "$PREFIX_DISCOVERY_COMMAND")."
    local output
    if ! output=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER_HOST" "$PREFIX_DISCOVERY_COMMAND" 2>&1); then
        log_error "Failed to query router $(highlight "$RED" "$SSH_USER_HOST"). Output:\n$output"
        return 1
    fi

    local prefix
    prefix=$(awk '/Prefix/ {print $3; exit}' <<<"$output")
    if [[ -z "$prefix" ]]; then
        prefix=$(grep -Eo '([0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}/[0-9]+' <<<"$output" | head -n1)
    fi

    if [[ -z "$prefix" ]]; then
        log_error "Could not parse IPv6 prefix from router output:\n$output"
        return 1
    fi

    if [[ ! "$prefix" =~ /$PREFIX_LENGTH$ ]]; then
        log_error "Discovered prefix $(highlight "$YELLOW" "$prefix") is not a /$PREFIX_LENGTH network."
        return 1
    fi

    CURRENT_PREFIX="$prefix"
    log_success "Discovered prefix: $(highlight "$GREEN" "$CURRENT_PREFIX")"
}

fetch_oci_rule() {
    log_info "Fetching existing OCI rule $(highlight "$MAGENTA" "$RULE_DESCRIPTION")."
    local response
    if ! response=$(oci network security-list get --security-list-id "$SEC_LIST_OCID" --output json 2>&1); then
        log_error "Failed to obtain security list. OCI CLI output:\n$response"
        return 1
    fi

    CURRENT_OCI_PREFIX=$(jq -r --arg desc "$RULE_DESCRIPTION" '.data."ingress-security-rules"[] | select(.description==$desc) | .source' <<<"$response" | head -n1)
    if [[ -z "$CURRENT_OCI_PREFIX" || "$CURRENT_OCI_PREFIX" == "null" ]]; then
        log_error "Rule $(highlight "$MAGENTA" "$RULE_DESCRIPTION") was not found in the security list."
        return 1
    fi

    log_info "OCI currently allows $(highlight "$CYAN" "$CURRENT_OCI_PREFIX")."

    OCI_RULES_JSON=$(jq '.data."ingress-security-rules"' <<<"$response")
}

update_oci_rule_if_needed() {
    if [[ "$CURRENT_PREFIX" == "$CURRENT_OCI_PREFIX" ]]; then
        log_success "OCI security list is already up to date."
        return
    fi

    log_warn "OCI rule needs update: $(highlight "$CYAN" "$CURRENT_OCI_PREFIX") -> $(highlight "$GREEN" "$CURRENT_PREFIX")."

    local new_rules
    new_rules=$(jq --arg desc "$RULE_DESCRIPTION" --arg prefix "$CURRENT_PREFIX" \
        'map(if .description==$desc then .source=$prefix else . end)' <<<"$OCI_RULES_JSON")

    if $DRY_RUN; then
        log_info "[Dry-run] Would push updated ingress rules to OCI."
        return
    fi

    if oci network security-list update --security-list-id "$SEC_LIST_OCID" \
        --ingress-security-rules "$new_rules" --force >/dev/null; then
        log_success "Updated OCI rule to $(highlight "$GREEN" "$CURRENT_PREFIX")."
    else
        log_error "OCI update failed."
        [[ "$STRICT_SELINUX" == "true" ]] && report_selinux_denials && fatal "Aborting due to failed OCI update."
    fi
}

ensure_firewalld_running() {
    if systemctl is-active --quiet firewalld; then
        return
    fi

    if $DRY_RUN; then
        log_warn "[Dry-run] firewalld is inactive; would attempt to start it."
        return
    fi

    log_warn "firewalld is not running; attempting to start."
    if systemctl start firewalld; then
        log_success "Started firewalld service."
    else
        log_error "Failed to start firewalld service."
        [[ "$STRICT_SELINUX" == "true" ]] && fatal "Cannot proceed without firewalld."
    fi
}

update_local_firewall() {
    ensure_firewalld_running

    log_info "Synchronising local ipset $(highlight "$MAGENTA" "$IPSET_NAME") in zone $(highlight "$CYAN" "$FIREWALL_ZONE")."

    if $DRY_RUN; then
        log_info "[Dry-run] Would ensure ipset exists and contains $(highlight "$GREEN" "$CURRENT_PREFIX")."
        return
    fi

    if ! firewall-cmd --permanent --get-ipsets | grep -qx "$IPSET_NAME"; then
        log_warn "ipset $(highlight "$MAGENTA" "$IPSET_NAME") missing; creating."
        firewall-cmd --permanent --new-ipset="$IPSET_NAME" --type=hash:net --family=ipv6
    fi

    if ! firewall-cmd --permanent --zone="$FIREWALL_ZONE" \
        --query-rich-rule="rule family=ipv6 source ipset=$IPSET_NAME accept" >/dev/null 2>&1; then
        log_info "Adding rich rule to zone $(highlight "$CYAN" "$FIREWALL_ZONE")."
        firewall-cmd --permanent --zone="$FIREWALL_ZONE" \
            --add-rich-rule="rule family=ipv6 source ipset=$IPSET_NAME accept"
    fi

    local entries
    entries=$(current_ipset_entries)
    if [[ "$entries" != "$CURRENT_PREFIX" ]]; then
        if [[ -n "$entries" ]]; then
            log_info "Clearing existing entries: $entries"
            for entry in $entries; do
                firewall-cmd --permanent --ipset="$IPSET_NAME" --remove-entry="$entry"
            done
        fi
        firewall-cmd --permanent --ipset="$IPSET_NAME" --add-entry="$CURRENT_PREFIX"
    else
        log_success "Local ipset already contains the correct prefix."
    fi

    if firewall-cmd --reload; then
        log_success "firewalld configuration reloaded."
    else
        log_error "firewalld reload failed."
        report_selinux_denials
        [[ "$STRICT_SELINUX" == "true" ]] && fatal "Aborting due to firewalld reload failure."
    fi
}

update_remote_firewalls() {
    local host
    for host in "${EXTRA_HOSTS[@]}"; do
        [[ -z "$host" ]] && continue
        log_info "Pushing prefix to $(highlight "$MAGENTA" "$host")."

        if $DRY_RUN; then
            log_info "[Dry-run] Would update remote host $(highlight "$MAGENTA" "$host")."
            continue
        fi

        if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'command -v firewall-cmd >/dev/null'; then
            log_warn "Host $(highlight "$MAGENTA" "$host") is unreachable or lacks firewalld. Skipping."
            continue
        fi

        if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" bash -s -- "$IPSET_NAME" "$FIREWALL_ZONE" "$CURRENT_PREFIX" <<'EOS'
set -euo pipefail
ipset_name="$1"
zone="$2"
prefix="$3"

if ! firewall-cmd --permanent --get-ipsets | grep -qx "$ipset_name"; then
    firewall-cmd --permanent --new-ipset="$ipset_name" --type=hash:net --family=ipv6
fi

if ! firewall-cmd --permanent --zone="$zone" \
    --query-rich-rule="rule family=ipv6 source ipset=$ipset_name accept" >/dev/null 2>&1; then
    firewall-cmd --permanent --zone="$zone" \
        --add-rich-rule="rule family=ipv6 source ipset=$ipset_name accept"
fi

existing=$(firewall-cmd --permanent --ipset="$ipset_name" --get-entries 2>/dev/null || true)
if [[ "$existing" != "$prefix" ]]; then
    for entry in $existing; do
        firewall-cmd --permanent --ipset="$ipset_name" --remove-entry="$entry"
    done
    firewall-cmd --permanent --ipset="$ipset_name" --add-entry="$prefix"
fi

firewall-cmd --reload
EOS
        then
            log_success "Updated $(highlight "$MAGENTA" "$host")."
        else
            log_warn "Failed to update $(highlight "$MAGENTA" "$host")."
            [[ "$STRICT_SELINUX" == "true" ]] && report_selinux_denials
        fi
    done
}

check_firewalld_state() {
    if systemctl is-active --quiet firewalld; then
        log_success "firewalld service is active."
    else
        log_warn "firewalld service is inactive. Run 'systemctl status firewalld' to investigate."
    fi
}

check_systemd_unit() {
    local unit="$1"
    if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        if systemctl is-enabled --quiet "$unit"; then
            log_success "Unit $(highlight "$CYAN" "$unit") is enabled."
        else
            log_warn "Unit $(highlight "$CYAN" "$unit") is disabled. Consider enabling it."
        fi

        if systemctl is-active --quiet "$unit"; then
            log_success "Unit $(highlight "$CYAN" "$unit") is active."
        else
            log_warn "Unit $(highlight "$CYAN" "$unit") is not active. Check 'systemctl status $unit'."
        fi
    fi
}

sanity_checks() {
    check_firewalld_state

    if firewall-cmd --permanent --get-ipsets | grep -qx "$IPSET_NAME"; then
        local entries
        entries=$(current_ipset_entries)
        if [[ "$entries" == "$CURRENT_PREFIX" ]]; then
            log_success "Local ipset $(highlight "$MAGENTA" "$IPSET_NAME") contains $(highlight "$GREEN" "$CURRENT_PREFIX")."
        else
            log_warn "Local ipset $(highlight "$MAGENTA" "$IPSET_NAME") entries: $entries"
        fi
    else
        log_warn "Local ipset $(highlight "$MAGENTA" "$IPSET_NAME") not found."
    fi

    check_systemd_unit "$SERVICE_NAME"
    check_systemd_unit "$TIMER_NAME"
}

perform_update() {
    ensure_log_file
    check_dependencies
    selinux_status

    discover_prefix || return 1
    fetch_oci_rule || return 1
    update_oci_rule_if_needed
    update_local_firewall
    update_remote_firewalls

    ensure_selinux_contexts
    sanity_checks

    log_success "IPv6 synchronisation completed."
}

# ---------------------------------------------------------------------------
# Installation helpers
# ---------------------------------------------------------------------------
create_service_files() {
    log_info "Creating systemd service and timer."

    cat >"$SYSTEMD_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=OCI IPv6 prefix synchroniser
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --run-once
StandardOutput=append:$LOG_FILE
StandardError=inherit
EOF

    cat >"$SYSTEMD_DIR/$TIMER_NAME" <<EOF
[Unit]
Description=Run OCI IPv6 synchroniser every $TIMER_INTERVAL

[Timer]
OnBootSec=5min
OnUnitActiveSec=$TIMER_INTERVAL
AccuracySec=1min
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF
}

install_systemd_units() {
    require_root
    load_config

    if [[ ! -f "$CONFIG_FILE" ]]; then
        interactive_configure
    else
        validate_config
    fi

    if $DRY_RUN; then
        log_info "[Dry-run] Would run an initial synchronisation before installation."
        log_info "[Dry-run] Would copy script to $(highlight "$MAGENTA" "$INSTALL_PATH")."
    else
        perform_update
        install -Dm755 "$0" "$INSTALL_PATH"
        log_success "Installed managed copy at $(highlight "$MAGENTA" "$INSTALL_PATH")."
    fi

    if $DRY_RUN; then
        log_info "[Dry-run] Would write $(highlight "$CYAN" "$SYSTEMD_DIR/$SERVICE_NAME")."
        log_info "[Dry-run] Would write $(highlight "$CYAN" "$SYSTEMD_DIR/$TIMER_NAME")."
        log_info "[Dry-run] Would run 'systemctl daemon-reload' and enable $(highlight "$CYAN" "$TIMER_NAME")."
    else
        create_service_files
        ensure_selinux_contexts
        systemctl daemon-reload
        systemctl enable --now "$TIMER_NAME"
        log_success "Enabled timer $(highlight "$CYAN" "$TIMER_NAME")."
    fi

    sanity_checks
}

uninstall_systemd_units() {
    require_root

    if $DRY_RUN; then
        log_info "[Dry-run] Would disable and remove $(highlight "$CYAN" "$TIMER_NAME") and $(highlight "$CYAN" "$SERVICE_NAME")."
        log_info "[Dry-run] Would remove installed copy $(highlight "$MAGENTA" "$INSTALL_PATH")."
        return
    fi

    if systemctl list-units --full --all "$TIMER_NAME" >/dev/null 2>&1; then
        systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    fi
    if systemctl list-units --full --all "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    rm -f "$SYSTEMD_DIR/$TIMER_NAME" "$SYSTEMD_DIR/$SERVICE_NAME"
    rm -f "$INSTALL_PATH"
    systemctl daemon-reload
    ensure_selinux_contexts
    log_success "Removed systemd units and installed copy."
}

show_status() {
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        validate_config
        sanity_checks
    else
        log_warn "Configuration file $(highlight "$MAGENTA" "$CONFIG_FILE") not found. Showing limited service state."
        check_systemd_unit "$SERVICE_NAME"
        check_systemd_unit "$TIMER_NAME"
    fi
}

# ---------------------------------------------------------------------------
# CLI handling
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --configure      Run interactive configuration and save to $CONFIG_FILE
  --run-once       Execute a single synchronisation run (default)
  --install        Run once, copy to $INSTALL_PATH and install timer
  --uninstall      Remove installed timer and managed copy
  --status         Display service health information
  --dry-run        Show planned actions without modifying the system
  -h, --help       Show this help message
EOF
}

main() {
    local action="run"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --configure)
                action="configure"
                ;;
            --run-once)
                action="run"
                ;;
            --install)
                action="install"
                ;;
            --uninstall)
                action="uninstall"
                ;;
            --status)
                action="status"
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
        shift
    done

    case "$action" in
        configure)
            require_root
            load_config
            interactive_configure
            ;;
        install)
            install_systemd_units
            ;;
        uninstall)
            uninstall_systemd_units
            ;;
        status)
            show_status
            ;;
        run)
            require_root
            load_config
            validate_config
            perform_update
            ;;
        *)
            fatal "Unhandled action: $action"
            ;;
    esac
}

main "$@"
