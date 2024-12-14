#!/usr/bin/env bash

# Script para atualizar e aplicar blocklists com ipset e iptables

set -euo pipefail

# Variáveis de configuração
BLOCKLIST_DIR="/opt/ipset-blocklist"
IPSET_ENTRADA_NOME="incoming_blocklist"
IPSET_SAIDA_NOME="outgoing_blocklist"
IP_BLOCKLIST_ENTRADA="$BLOCKLIST_DIR/incoming_blocklist.txt"
IP_BLOCKLIST_SAIDA="$BLOCKLIST_DIR/outgoing_blocklist.txt"
IP_BLOCKLIST_ENTRADA_RESTAURAR="$BLOCKLIST_DIR/incoming_blocklist.restore"
IP_BLOCKLIST_SAIDA_RESTAURAR="$BLOCKLIST_DIR/outgoing_blocklist.restore"
MAXELEM=131072
REgra_IPTABLES_IPSET_NUMERO=1  # Número da regra no iptables

# URLs das blocklists de entrada
BLOCKLISTS_ENTRADA=(
    "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt"
    "https://s3.i02.estaleiro.serpro.gov.br/blocklist/blocklist.txt"
    "https://talosintelligence.com/documents/ip-blacklist"
    "https://iplists.firehol.org/files/alienvault_reputation.ipset"
    "https://iplists.firehol.org/files/spamhaus_drop.netset"
    "https://iplists.firehol.org/files/spamhaus_edrop.netset"
    "https://iplists.firehol.org/files/ransomware_cryptowall_ps.ipset"
    "https://iplists.firehol.org/files/ransomware_feed.ipset"
    "https://iplists.firehol.org/files/normshield_all_ddosbot.ipset"
    "https://blocklist.greensnow.co/greensnow.txt"
)

# URLs das blocklists de saída
BLOCKLISTS_SAIDA=(
    "https://cpdbl.net/lists/sslblock.list"
    "https://cpdbl.net/lists/ipsum.list"
)

# Verifica se o script é executado como root
if [ "$(id -u)" != "0" ]; then
    echo "Erro: este script precisa ser executado como root." >&2
    exit 1
fi

# Função de log
log() {
    local nivel="$1"
    local mensagem="$2"
    echo "[$nivel] $mensagem"
}

# Verifica se o comando existe
comando_existe() {
    command -v "$1" >/dev/null 2>&1
}

# Valida IP/CIDR
validar_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]] || return 1
    IFS='.' read -r -a octetos <<< "$1"
    for octeto in "${octetos[@]}"; do
        [[ "$octeto" -ge 0 && "$octeto" -le 255 ]] || return 1
    done
    return 0
}

# Adiciona regras no iptables
adicionar_regras_iptables() {
    local cadeia="$1"
    local ipset_nome="$2"
    local prefixo="$3"
    local numero_regra="${4:-1}"

    if ! iptables -C "$cadeia" -m set --match-set "$ipset_nome" src -j DROP 2>/dev/null; then
        iptables -I "$cadeia" "$numero_regra" -m set --match-set "$ipset_nome" src -j LOG --log-prefix "$prefixo" --log-level 4
        iptables -I "$cadeia" "$numero_regra" -m set --match-set "$ipset_nome" src -j DROP
        log "INFO" "Regras iptables para $cadeia adicionadas."
    else
        log "INFO" "Regras iptables para $cadeia já existem."
    fi
}

# Verifica comandos essenciais
for cmd in curl grep ipset iptables sed sort mktemp; do
    if ! comando_existe "$cmd"; then
        log "ERROR" "Comando '$cmd' não encontrado."
        exit 1
    fi
done

# Cria ipsets se não existirem
for ipset in "$IPSET_ENTRADA_NOME" "$IPSET_SAIDA_NOME"; do
    if ! ipset list -n | grep -q "$ipset"; then
        ipset create "$ipset" hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-131072}"
        log "INFO" "Ipset $ipset criado."
    fi
done

# Adiciona regras ao iptables
adicionar_regras_iptables "INPUT" "$IPSET_ENTRADA_NOME" "BLOQUEADO_ENTRADA: " "$REgra_IPTABLES_IPSET_NUMERO"
adicionar_regras_iptables "OUTPUT" "$IPSET_SAIDA_NOME" "BLOQUEADO_SAIDA: " "$REgra_IPTABLES_IPSET_NUMERO"

# Processa blocklists
processar_blocklist() {
    local urls=("${@:2}")
    local tmp_arquivo="$(mktemp)"
    local ipset_nome="$1"
    local validos=0
    local invalidos=0

    for url in "${urls[@]}"; do
        log "INFO" "Processando blocklist: $url"
        resultado=$(curl -s "$url") || { log "ERROR" "Falha ao baixar $url."; continue; }

        while read -r ip; do
            if validar_ip "$ip"; then
                echo "$ip" >> "$tmp_arquivo"
                ((validos++))
            else
                ((invalidos++))
            fi
        done <<< "$(echo "$resultado" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')"
    done

    sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' \
        "$tmp_arquivo" | sort -u > "$ipset_nome"

    log "INFO" "IPs válidos: $validos | IPs inválidos: $invalidos"
    rm -f "$tmp_arquivo"
}

processar_blocklist "$IP_BLOCKLIST_ENTRADA" "${BLOCKLISTS_ENTRADA[@]}"
processar_blocklist "$IP_BLOCKLIST_SAIDA" "${BLOCKLISTS_SAIDA[@]}"

# Atualiza ipsets
for ipset_restaurar in "$IP_BLOCKLIST_ENTRADA_RESTAURAR" "$IP_BLOCKLIST_SAIDA_RESTAURAR"; do
    ipset -file "$ipset_restaurar" restore || {
        log "ERROR" "Falha ao restaurar ipset de $ipset_restaurar"
        exit 1
    }
    log "INFO" "Ipset atualizado: $ipset_restaurar"
done
