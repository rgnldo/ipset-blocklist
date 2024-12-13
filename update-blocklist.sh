#!/bin/bash

# Color variables for logging
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Constants and variables
BLOCKLIST_INCOMING_URLS=(
    "https://www.projecthoneypot.org/list_of_ips.php?t=d&rss=1"
    "https://iplists.firehol.org/files/cybercrime.ipset"
    # Add more incoming blocklist URLs here
)

BLOCKLIST_OUTGOING_URLS=(
    "https://cpdbl.net/lists/sslblock.list"
    "https://cpdbl.net/lists/ipsum.list"
    # Add more outgoing blocklist URLs here
)

IPSET_INCOMING_NAME="incoming_blocklist"
IPSET_OUTGOING_NAME="outgoing_blocklist"

FILE_PATH_INCOMING="/opt/ipset-blocklist/incoming_blocklist.txt"
FILE_PATH_OUTGOING="/opt/ipset-blocklist/outgoing_blocklist.txt"

RESTORE_FILE_INCOMING="/opt/ipset-blocklist/incoming_blocklist.restore"
RESTORE_FILE_OUTGOING="/opt/ipset-blocklist/outgoing_blocklist.restore"

IPTABLES_IPSET_RULE_NUMBER=1

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to log messages with colors
log() {
    local level="$1"
    local message="$2"
    echo -e "${level}[${message}]${NC}"
}

# Function to validate IP/CIDR
validate_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]] || return 1
    IFS='.' read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
    done
    return 0
}

# Function to add iptables rules
add_iptables_rules() {
    local chain="$1"
    local ipset_name="$2"
    local prefix="$3"
    local rule_num="${4:-1}"

    if ! iptables -C "$chain" -m set --match-set "$ipset_name" src -j DROP 2>/dev/null; then
        iptables -I "$chain" "$rule_num" -m set --match-set "$ipset_name" src -j LOG --log-prefix "$prefix" --log-level 4
        iptables -I "$chain" "$rule_num" -m set --match-set "$ipset_name" src -j DROP
        log "${GREEN}" "Regras iptables para $chain adicionadas."
    else
        log "${YELLOW}" "Regras iptables para $chain já existem."
    fi
}

# Function to process blocklists
process_blocklist() {
    local urls=("$@")
    local file_path="$1"
    local valid_count=0
    local invalid_count=0

    > "$file_path" # Clear the file

    for url in "${urls[@]}"; do
        log "${YELLOW}" "Processando blocklist: $url"
        result=$(curl -s "$url") || { log "${RED}" "Falha ao baixar $url."; continue; }

        while read -r ip; do
            if validate_ip "$ip"; then
                echo "$ip" >> "$file_path"
                ((valid_count++))
            else
                ((invalid_count++))
            fi
        done <<< "$(echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')"
    done

    # Filter out private and reserved IPs
    sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' \
        "$file_path" | sort -u > "${file_path}.tmp" && mv "${file_path}.tmp" "$file_path"

    log "${GREEN}" "IPs válidos: $valid_count | IPs inválidos: $invalid_count"
}

# Main script logic
if [ "$(id -u)" != "0" ]; then
    log "${RED}" "Este script precisa ser executado como root."
    exit 1
fi

# Install missing dependencies
for pkg in ipset wget curl iptables; do
    if ! command_exists "$pkg"; then
        log "${YELLOW}" "Instalando $pkg..."
        apt-get install -y "$pkg" || { log "${RED}" "Falha ao instalar $pkg."; exit 1; }
    else
        log "${GREEN}" "$pkg já instalado."
    fi
done

# Create necessary directories
mkdir -p /opt/ipset-blocklist || { log "${RED}" "Falha ao criar diretório."; exit 1; }

# Process incoming blocklists
process_blocklist "${BLOCKLIST_INCOMING_URLS[@]}" "$FILE_PATH_INCOMING"

# Process outgoing blocklists
process_blocklist "${BLOCKLIST_OUTGOING_URLS[@]}" "$FILE_PATH_OUTGOING"

# Update ipsets
for set in "$IPSET_INCOMING_NAME" "$IPSET_OUTGOING_NAME"; do
    if ! ipset list -n | grep -q "$set"; then
        ipset create "$set" hash:net family inet hashsize 16384 maxelem 131072
        log "${GREEN}" "Ipset $set criado."
    fi
done

ipset restore -file "$FILE_PATH_INCOMING" -exist || { log "${RED}" "Falha ao restaurar ipset $IPSET_INCOMING_NAME."; exit 1; }
ipset restore -file "$FILE_PATH_OUTGOING" -exist || { log "${RED}" "Falha ao restaurar ipset $IPSET_OUTGOING_NAME."; exit 1; }

# Apply iptables rules
add_iptables_rules "INPUT" "$IPSET_INCOMING_NAME" "BLOCKED_IN: " "$IPTABLES_IPSET_RULE_NUMBER"
add_iptables_rules "OUTPUT" "$IPSET_OUTGOING_NAME" "BLOCKED_OUT: " "$IPTABLES_IPSET_RULE_NUMBER"

log "${GREEN}" "Configuração concluída com sucesso."
