#!/bin/bash

# Color variables
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to install missing packages
install_missing_packages() {
    # Install ipset
    if ! command -v ipset &> /dev/null; then
        echo "Installing ipset..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y ipset
        elif command -v yum &> /dev/null; then
            yum install -y ipset
        elif command -v dnf &> /dev/null; then
            dnf install -y ipset
        else
            echo "Package manager not supported. Install ipset manually."
            exit 1
        fi
    fi

    # Install wget
    if ! command -v wget &> /dev/null; then
        echo "Installing wget..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y wget
        elif command -v yum &> /dev/null; then
            yum install -y wget
        elif command -v dnf &> /dev/null; then
            dnf install -y wget
        else
            echo "Package manager not supported. Install wget manually."
            exit 1
        fi
    fi

    # Install curl
    if ! command -v curl &> /dev/null; then
        echo "Installing curl..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v yum &> /dev/null; then
            yum install -y curl
        elif command -v dnf &> /dev/null; then
            dnf install -y curl
        else
            echo "Package manager not supported. Install curl manually."
            exit 1
        fi
    fi
}

# Function to install IPSet Blocklist
install_ipset_blocklist() {
    # Install missing packages
    install_missing_packages

    # Create directories
    mkdir -p /opt/ipset-blocklist

    # Download scripts and configuration
    wget -O /usr/local/sbin/update-blocklist.sh https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh
    chmod +x /usr/local/sbin/update-blocklist.sh

    # Create reboot_script.sh using sed
    cat > /usr/local/sbin/reboot_script.sh << EOF
#!/bin/bash

# Restore ipset from backups
ipset restore < /opt/ipset-blocklist/incoming_blocklist.restore
ipset restore < /opt/ipset-blocklist/outgoing_blocklist.restore

# Add iptables rules for incoming blocklist
iptables -I INPUT -m set --match-set incoming_blocklist src -j LOG --log-prefix 'BLOCKED_IN: ' --log-level 4
iptables -I INPUT -m set --match-set incoming_blocklist src -j DROP

# Add iptables rules for outgoing blocklist
iptables -I OUTPUT -m set --match-set outgoing_blocklist dst -j LOG --log-prefix 'BLOCKED_OUT: ' --log-level 4
iptables -I OUTPUT -m set --match-set outgoing_blocklist dst -j DROP

# Wait for 5 minutes
sleep 300

# Update blocklist
/usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
EOF
    chmod +x /usr/local/sbin/reboot_script.sh

    wget -O /opt/ipset-blocklist/ipset-blocklist.conf https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/ipset-blocklist.conf

    # Generate initial blocklist
    /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

    # Configure cron jobs
    cat > /etc/cron.d/ipset-blocklist << EOF
@reboot root /usr/local/sbin/reboot_script.sh >> /var/log/blocklist_reboot.log 2>&1
0 */12 * * * root /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf >> /var/log/blocklist_update.log 2>&1
EOF
    chmod 0644 /etc/cron.d/ipset-blocklist

    echo "Cron jobs configured successfully."
}

# Function to uninstall IPSet Blocklist
uninstall_ipset_blocklist() {
    read -p "Are you sure you want to uninstall IPSet Blocklist? (Y/N): " confirmation
    if [[ "\$confirmation" != [Yy] ]]; then
        echo "Uninstallation canceled."
        return
    fi

    # Remove iptables rules
    iptables -D INPUT -m set --match-set incoming_blocklist src -j DROP 2>/dev/null
    iptables -D INPUT -m set --match-set incoming_blocklist src -j LOG --log-prefix "BLOCKED_IN: " --log-level 4 2>/dev/null
    iptables -D OUTPUT -m set --match-set outgoing_blocklist dst -j DROP 2>/dev/null
    iptables -D OUTPUT -m set --match-set outgoing_blocklist dst -j LOG --log-prefix "BLOCKED_OUT: " --log-level 4 2>/dev/null

    # Destroy ipsets
    ipset destroy incoming_blocklist 2>/dev/null
    ipset destroy outgoing_blocklist 2>/dev/null

    # Remove scripts and configuration files
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /usr/local/sbin/reboot_script.sh
    rm -rf /opt/ipset-blocklist

    # Remove cron jobs
    rm -f /etc/cron.d/ipset-blocklist

    # Remove log files, if exist
    rm -f /var/log/blocklist_reboot.log
    rm -f /var/log/blocklist_update.log
    rm -f /var/log/blocklist.log

    echo "Uninstallation completed successfully."
}

# Function to check the status of IPSet Blocklist
check_status() {
    if [[ -f /opt/ipset-blocklist/incoming_blocklist.restore && -f /opt/ipset-blocklist/outgoing_blocklist.restore && -f /usr/local/sbin/update-blocklist.sh ]]; then
        echo -e "\$GREEN IPSet Blocklist is installed. \$NC"
    else
        echo -e "\$RED IPSet Blocklist is not installed. \$NC"
        return
    fi

    # Check iptables rules for incoming blocklist
    if iptables -S INPUT | grep -q 'incoming_blocklist src -j DROP'; then
        echo -e "\$GREEN DROP rule for incoming blocklist in iptables is active. \$NC"
    else
        echo -e "\$RED DROP rule for incoming blocklist in iptables is not active. \$NC"
    fi

    if iptables -S INPUT | grep -q 'incoming_blocklist src -j LOG'; then
        echo -e "\$GREEN LOG rule for incoming blocklist in iptables is active. \$NC"
    else
        echo -e "\$RED LOG rule for incoming blocklist in iptables is not active. \$NC"
    fi

    # Check iptables rules for outgoing blocklist
    if iptables -S OUTPUT | grep -q 'outgoing_blocklist dst -j DROP'; then
        echo -e "\$GREEN DROP rule for outgoing blocklist in iptables is active. \$NC"
    else
        echo -e "\$RED DROP rule for outgoing blocklist in iptables is not active. \$NC"
    fi

    if iptables -S OUTPUT | grep -q 'outgoing_blocklist dst -j LOG'; then
        echo -e "\$GREEN LOG rule for outgoing blocklist in iptables is active. \$NC"
    else
        echo -e "\$RED LOG rule for outgoing blocklist in iptables is not active. \$NC"
    fi

    # Check ipset status for incoming blocklist
    if ipset list | grep -q 'incoming_blocklist'; then
        echo -e "\$GREEN Ipset incoming_blocklist is active. \$NC"

        # Get IP count for incoming blocklist
        ip_count_incoming=\$(ipset list incoming_blocklist | grep '^' | wc -l)
        echo -e "\$YELLOW Total IPs blocked in incoming_blocklist: \$GREEN \$ip_count_incoming \$NC"
    else
        echo -e "\$RED Ipset incoming_blocklist is not active. \$NC"
    fi

    # Check ipset status for outgoing blocklist
    if ipset list | grep -q 'outgoing_blocklist'; then
        echo -e "\$GREEN Ipset outgoing_blocklist is active. \$NC"

        # Get IP count for outgoing blocklist
        ip_count_outgoing=\$(ipset list outgoing_blocklist | grep '^' | wc -l)
        echo -e "\$YELLOW Total IPs blocked in outgoing_blocklist: \$GREEN \$ip_count_outgoing \$NC"
    else
        echo -e "\$RED Ipset outgoing_blocklist is not active. \$NC"
    fi

    # Check last update time
    last_update_incoming=\$(stat -c %y /opt/ipset-blocklist/incoming_blocklist.restore)
    last_update_outgoing=\$(stat -c %y /opt/ipset-blocklist/outgoing_blocklist.restore)
    echo -e "\$YELLOW Last update for incoming_blocklist: \$GREEN \$last_update_incoming \$NC"
    echo -e "\$YELLOW Last update for outgoing_blocklist: \$GREEN \$last_update_outgoing \$NC"

    # Check for blocklist actions in log files
    log_file_incoming=\$(grep 'LOGFILE_IN' /opt/ipset-blocklist/ipset-blocklist.conf | cut -d '=' -f2 | tr -d ' ')
    log_file_outgoing=\$(grep 'LOGFILE_OUT' /opt/ipset-blocklist/ipset-blocklist.conf | cut -d '=' -f2 | tr -d ' ')

    if [[ -n "\$log_file_incoming" && -f "\$log_file_incoming" ]]; then
        blocked_in=\$(grep 'BLOCKED_IN:' "\$log_file_incoming" | wc -l)
        echo -e "\$YELLOW Total blocks for incoming: \$GREEN \$blocked_in \$NC"
    else
        echo -e "\$RED Incoming log file not found or path not specified in configuration. \$NC"
    fi

    if [[ -n "\$log_file_outgoing" && -f "\$log_file_outgoing" ]]; then
        blocked_out=\$(grep 'BLOCKED_OUT:' "\$log_file_outgoing" | wc -l)
        echo -e "\$YELLOW Total blocks for outgoing: \$GREEN \$blocked_out \$NC"
    else
        echo -e "\$RED Outgoing log file not found or path not specified in configuration. \$NC"
    fi
}

# Interactive menu
while true; do
    clear
    echo "IPSet Blocklist Installer"
    echo "-------------------------"
    echo "1. Install IPSet Blocklist"
    echo "2. Uninstall IPSet Blocklist"
    echo "3. Check Blocklist Status"
    echo "4. Exit"

    read -p "Select an option (1/2/3/4): " option

    case \$option in
        1)
            install_ipset_blocklist
            ;;
        2)
            uninstall_ipset_blocklist
            ;;
        3)
            check_status
            ;;
        4)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac

    read -p "Press Enter to continue..."
done
