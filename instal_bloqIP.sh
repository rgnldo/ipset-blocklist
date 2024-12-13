#!/bin/bash

# Color variables
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Constants
BLOCKLIST_DIR="/opt/ipset-blocklist"
LOG_DIR="/var/log"
REBOOT_SCRIPT="/usr/local/sbin/reboot_script.sh"
UPDATE_SCRIPT="/usr/local/sbin/update-blocklist.sh"
CRON_FILE="/etc/cron.d/ipset-blocklist"
URL_BASE="https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    exit 1
fi

# Function to log errors
log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Function to install a package
install_package() {
    local package=$1
    if ! command -v "$package" &> /dev/null; then
        echo -e "${YELLOW}Installing $package...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y "$package" || log_error "Failed to install $package using apt-get."
        elif command -v yum &> /dev/null; then
            yum install -y "$package" || log_error "Failed to install $package using yum."
        elif command -v dnf &> /dev/null; then
            dnf install -y "$package" || log_error "Failed to install $package using dnf."
        else
            log_error "Package manager not supported. Install $package manually."
        fi
    else
        echo -e "${GREEN}$package is already installed.${NC}"
    fi
}

# Install dependencies
install_missing_packages() {
    install_package ipset
    install_package wget
    install_package curl
}

# Function to install IPSet Blocklist
install_ipset_blocklist() {
    install_missing_packages

    mkdir -p "$BLOCKLIST_DIR" || log_error "Failed to create directory $BLOCKLIST_DIR."

    wget -O "$UPDATE_SCRIPT" "$URL_BASE/update-blocklist.sh" || log_error "Failed to download update-blocklist.sh."
    chmod +x "$UPDATE_SCRIPT"

    cat > "$REBOOT_SCRIPT" << EOF
#!/bin/bash

ipset restore < "$BLOCKLIST_DIR/incoming_blocklist.restore"
ipset restore < "$BLOCKLIST_DIR/outgoing_blocklist.restore"

iptables -I INPUT -m set --match-set incoming_blocklist src -j LOG --log-prefix 'BLOCKED_IN: ' --log-level 4
iptables -I INPUT -m set --match-set incoming_blocklist src -j DROP
iptables -I OUTPUT -m set --match-set outgoing_blocklist dst -j LOG --log-prefix 'BLOCKED_OUT: ' --log-level 4
iptables -I OUTPUT -m set --match-set outgoing_blocklist dst -j DROP

sleep 300
"$UPDATE_SCRIPT"
EOF
    chmod +x "$REBOOT_SCRIPT"

    # Removed incomplete line

    "$UPDATE_SCRIPT" "$CONF_FILE" || log_error "Failed to execute update-blocklist.sh."

    cat > "$CRON_FILE" << EOF
@reboot root "$REBOOT_SCRIPT" >> "$LOG_DIR/blocklist_reboot.log" 2>&1
0 */12 * * * root "$UPDATE_SCRIPT" >> "$LOG_DIR/blocklist_update.log" 2>&1
EOF
    chmod 0644 "$CRON_FILE"

    echo -e "${GREEN}IPSet Blocklist installed and cron jobs configured successfully.${NC}"
}

# Uninstall function
uninstall_ipset_blocklist() {
    read -p "Are you sure you want to uninstall IPSet Blocklist? (Y/N): " confirmation
    if [[ "$confirmation" != [Yy] ]]; then
        echo "Uninstallation canceled."
        return
    fi

    iptables -D INPUT -m set --match-set incoming_blocklist src -j DROP 2>/dev/null
    iptables -D INPUT -m set --match-set incoming_blocklist src -j LOG 2>/dev/null
    iptables -D OUTPUT -m set --match-set outgoing_blocklist dst -j DROP 2>/dev/null
    iptables -D OUTPUT -m set --match-set outgoing_blocklist dst -j LOG 2>/dev/null

    ipset destroy incoming_blocklist 2>/dev/null
    ipset destroy outgoing_blocklist 2>/dev/null

    rm -rf "$BLOCKLIST_DIR" "$UPDATE_SCRIPT" "$REBOOT_SCRIPT" "$CRON_FILE" \
           "$LOG_DIR/blocklist_reboot.log" "$LOG_DIR/blocklist_update.log"

    echo -e "${GREEN}Uninstallation completed successfully.${NC}"
}

# Function to check the status of the blocklist
check_status() {
    # Placeholder for status checking logic
    echo "Status check logic goes here."
}

# Menu
while true; do
    clear
    echo "IPSet Blocklist Installer"
    echo "-------------------------"
    echo "1. Install IPSet Blocklist"
    echo "2. Uninstall IPSet Blocklist"
    echo "3. Check Blocklist Status"
    echo "4. Exit"

    read -p "Select an option (1/2/3/4): " option

    case $option in
        1) install_ipset_blocklist ;;
        2) uninstall_ipset_blocklist ;;
        3) check_status ;;
        4) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option. Please try again."; sleep 2 ;;
    esac
done
