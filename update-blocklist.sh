#!/usr/bin/env bash

# Script para atualizar e aplicar blocklists com ipset e iptables

set -euo pipefail

# Verifica se o script é executado como root
if [ "$(id -u)" != "0" ]; then
    echo "Erro: este script precisa ser executado como root." >&2
    exit 1
fi

# Função de log
log() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
}

# Verifica se o comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Valida IP/CIDR
validate_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]] || return 1
    IFS='.' read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
    done
    return 0
}

# Adiciona regras no iptables
add_iptables_rules() {
    local chain="$1"
    local ipset_name="$2"
    local prefix="$3"
    local rule_num="${4:-1}"

    if ! iptables -C "$chain" -m set --match-set "$ipset_name" src -j DROP 2>/dev/null; then
        iptables -I "$chain" "$rule_num" -m set --match-set "$ipset_name" src -j LOG --log-prefix "$prefix" --log-level 4
        iptables -I "$chain" "$rule_num" -m set --match-set "$ipset_name" src -j DROP
        log "INFO" "Regras iptables para $chain adicionadas."
    else
        log "INFO" "Regras iptables para $chain já existem."
    fi
}

# Carrega configuração
if [[ -z "$1" ]]; then
    log "ERROR" "Por favor, especifique um arquivo de configuração."
    exit 1
fi

if ! source "$1"; then
    log "ERROR" "Não foi possível carregar o arquivo de configuração $1"
    exit 1
fi

# Verifica comandos essenciais
for cmd in curl grep ipset iptables sed sort mktemp; do
    if ! command_exists "$cmd"; then
        log "ERROR" "Comando '$cmd' não encontrado."
        exit 1
    fi
done

# Cria ipsets se não existirem
for ipset in "$IPSET_INCOMING_NAME" "$IPSET_OUTGOING_NAME"; do
    if ! ipset list -n | grep -q "$ipset"; then
        ipset create "$ipset" hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-131072}"
        log "INFO" "Ipset $ipset criado."
    fi
done

# Adiciona regras ao iptables
add_iptables_rules "INPUT" "$IPSET_INCOMING_NAME" "BLOCKED_IN: " "$IPTABLES_IPSET_RULE_NUMBER"
add_iptables_rules "OUTPUT" "$IPSET_OUTGOING_NAME" "BLOCKED_OUT: " "$IPTABLES_IPSET_RULE_NUMBER"

# Define blocklist URLs
BLOCKLISTS_INCOMING=(
    "https://www.projecthoneypot.org/list_of_ips.php?t=d&rss=1"
    "https://iplists.firehol.org/files/cybercrime.ipset"
    # ... (other URLs)
)

BLOCKLISTS_OUTGOING=(
    "https://cpdbl.net/lists/sslblock.list"
    "https://cpdbl.net/lists/ipsum.list"
    # ... (other URLs)
)

# Processa blocklists
process_blocklist() {
    local ipset_name="$1"
    shift
    local urls=("$@")
    local tmp_file="$(mktemp)"
    local valid_count=0
    local invalid_count=0

    for url in "${urls[@]}"; do
        log "INFO" "Processando blocklist: $url"
        result=$(curl -s "$url") || { log "ERROR" "Falha ao baixar $url."; continue; }

        while read -r ip; do
            if validate_ip "$ip"; then
                echo "$ip" >> "$tmp_file"
                ((valid_count++))
            else
                ((invalid_count++))
            fi
        done <<< "$(echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')"
    done

    sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' \
        "$tmp_file" | sort -u > "$ipset_name"

    log "INFO" "IPs válidos: $valid_count | IPs inválidos: $invalid_count"
    rm -f "$tmp_file"
}

process_blocklist "$IP_BLOCKLIST_INCOMING" "${BLOCKLISTS_INCOMING[@]}"
process_blocklist "$IP_BLOCKLIST_OUTGOING" "${BLOCKLISTS_OUTGOING[@]}"

# Atualiza ipsets
for ipset_restore in "$IP_BLOCKLIST_INCOMING_RESTORE" "$IP_BLOCKLIST_OUTGOING_RESTORE"; do
    ipset -file "$ipset_restore" restore || {
        log "ERROR" "Falha ao restaurar ipset de $ipset_restore"
        exit 1
    }
    log "INFO" "Ipset atualizado: $ipset_restore"
done

# Ipset configuration
IPSET_INCOMING_NAME="incoming_blocklist"
IPSET_OUTGOING_NAME="outgoing_blocklist"

# File paths for storing and restoring blocklists
IP_BLOCKLIST_INCOMING="/opt/ipset-blocklist/incoming_blocklist.txt"
IP_BLOCKLIST_OUTGOING="/opt/ipset-blocklist/outgoing_blocklist.txt"
IP_BLOCKLIST_INCOMING_RESTORE="/opt/ipset-blocklist/incoming_blocklist.restore"
IP_BLOCKLIST_OUTGOING_RESTORE="/opt/ipset-blocklist/outgoing_blocklist.restore"

# Ipset parameters
MAXELEM=131072                             # Maximum elements for ipsets
