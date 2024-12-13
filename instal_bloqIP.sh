#!/bin/bash

# Color variables for logging
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Constants and variables
BLOCKLIST_DIR="/opt/ipset-blocklist"
UPDATE_SCRIPT_PATH="/usr/local/sbin/update-blocklist.sh"
CRON_FILE="/etc/cron.d/ipset-blocklist"
URL_UPDATE_SCRIPT="https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh"
IPSET_INCOMING="incoming_blocklist"
IPSET_OUTGOING="outgoing_blocklist"

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root.${NC}"
        exit 1
    fi
}

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Install missing packages
install_packages() {
    for pkg in ipset wget curl iptables; do
        if ! command -v "$pkg" &> /dev/null; then
            log_info "Installing $pkg..."
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y "$pkg" || log_error "Failed to install $pkg using apt-get."
            elif command -v yum &> /dev/null; then
                yum install -y "$pkg" || log_error "Failed to install $pkg using yum."
            elif command -v dnf &> /dev/null; then
                dnf install -y "$pkg" || log_error "Failed to install $pkg using dnf."
            else
                log_error "Package manager not supported. Install $pkg manually."
            fi
        else
            log_info "$pkg is already installed."
        fi
    done
}

# Install update-blocklist.sh
install_update_script() {
    mkdir -p "$BLOCKLIST_DIR" || log_error "Failed to create directory $BLOCKLIST_DIR."
    wget -O "$UPDATE_SCRIPT_PATH" "$URL_UPDATE_SCRIPT" || log_error "Failed to download update-blocklist.sh."
    chmod +x "$UPDATE_SCRIPT_PATH" || log_error "Failed to set execute permission for update-blocklist.sh."
    log_info "update-blocklist.sh installed successfully."
}

# Configure cron jobs
configure_cron() {
    cat > "$CRON_FILE" << EOF
@reboot root /usr/local/sbin/update-blocklist.sh >> /var/log/blocklist_reboot.log 2>&1
0 */12 * * * root /usr/local/sbin/update-blocklist.sh >> /var/log/blocklist_update.log 2>&1
EOF
    chmod 0644 "$CRON_FILE" || log_error "Failed to set permissions for cron file."
    log_info "Cron jobs configured successfully."
}

# Configure iptables and ipsets
configure_firewall() {
    # Create ipsets if they don't exist
    if ! ipset list -n | grep -qw "$IPSET_INCOMING"; then
        ipset create "$IPSET_INCOMING" hash:net || log_error "Failed to create ipset $IPSET_INCOMING."
    else
        log_warning "Ipset $IPSET_INCOMING already exists."
    fi

    if ! ipset list -n | grep -qw "$IPSET_OUTGOING"; then
        ipset create "$IPSET_OUTGOING" hash:net || log_error "Failed to create ipset $IPSET_OUTGOING."
    else
        log_warning "Ipset $IPSET_OUTGOING already exists."
    fi

    # Add iptables rules if they don't exist
    if ! iptables -C INPUT -m set --match-set "$IPSET_INCOMING" src -j DROP &> /dev/null; then
        iptables -I INPUT -m set --match-set "$IPSET_INCOMING" src -j LOG --log-prefix 'BLOCKED_IN: ' --log-level 4
        iptables -I INPUT -m set --match-set "$IPSET_INCOMING" src -j DROP
        log_info "iptables rule for $IPSET_INCOMING added."
    else
        log_warning "iptables rule for $IPSET_INCOMING already exists."
    fi

    if ! iptables -C OUTPUT -m set --match-set "$IPSET_OUTGOING" dst -j DROP &> /dev/null; then
        iptables -I OUTPUT -m set --match-set "$IPSET_OUTGOING" dst -j LOG --log-prefix 'BLOCKED_OUT: ' --log-level 4
        iptables -I OUTPUT -m set --match-set "$IPSET_OUTGOING" dst -j DROP
        log_info "iptables rule for $IPSET_OUTGOING added."
    else
        log_warning "iptables rule for $IPSET_OUTGOING already exists."
    fi
}

# Uninstall functionality
uninstall_config() {
    read -p "Are you sure you want to uninstall IPSet Blocklist? (Y/N): " confirmation
    if [[ "$confirmation" != [Yy] ]]; then
        echo "Uninstallation canceled."
        return
    fi

    # Remove iptables rules
    iptables -D INPUT -m set --match-set "$IPSET_INCOMING" src -j DROP 2>/dev/null
    iptables -D INPUT -m set --match-set "$IPSET_INCOMING" src -j LOG --log-prefix 'BLOCKED_IN: ' --log-level 4 2>/dev/null
    iptables -D OUTPUT -m set --match-set "$IPSET_OUTGOING" dst -j DROP 2>/dev/null
    iptables -D OUTPUT -m set --match-set "$IPSET_OUTGOING" dst -j LOG --log-prefix 'BLOCKED_OUT: ' --log-level 4 2>/dev/null

    # Destroy ipsets
    ipset destroy "$IPSET_INCOMING" 2>/dev/null
    ipset destroy "$IPSET_OUTGOING" 2>/dev/null

    # Remove cron jobs
    rm -f "$CRON_FILE"

    # Remove scripts and log files
    rm -f "$UPDATE_SCRIPT_PATH"
    rm -rf "$BLOCKLIST_DIR"
    rm -f /var/log/blocklist_reboot.log /var/log/blocklist_update.log

    log_info "Uninstallation completed successfully."
}

# Menu system
while true; do
    clear
    echo "IPSet Blocklist Installer"
    echo "-------------------------"
    echo "1. Install IPSet Blocklist"
    echo "2. Uninstall IPSet Blocklist"
    echo "3. Exit"

    read -p "Select an option (1/2/3): " option

    case $option in
        1)
            check_root
            install_packages
            install_update_script
            configure_cron
            configure_firewall
            ;;
        2)
            check_root
            uninstall_config
            ;;
        3)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            sleep 2
            ;;
    esac
done
