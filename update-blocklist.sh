#!/usr/bin/env bash
#
# Script para atualizar e aplicar blocklists com ipset e iptables
# Uso: update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

# Verifica se o script é executado como root
if [ "$(id -u)" != "0" ]; then
    echo "Erro: este script precisa ser executado como root."
    exit 1
fi

# Função para verificar se o comando existe
function exists() { command -v "$1" >/dev/null 2>&1 ; }

# Função para validar IP/CIDR
function validate_ip() {
    if [[ ! "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
        return 1  # IP inválido
    fi
    IFS='.' read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        if [[ "$octet" -gt 255 || "$octet" -lt 0 ]]; then
            return 1  # IP inválido
        fi
    done
    return 0  # IP válido
}

# Função para adicionar regras iptables
function add_iptables_rules() {
    local chain=$1
    local ipset_name=$2
    local prefix=$3
    local rule_num=${4:-1}

    if [ "$FORCE" = "yes" ]; then
        # Adiciona regra de log
        iptables -I $chain $rule_num -m set --match-set "$ipset_name" src -j LOG --log-prefix "$prefix" --log-level 4
        # Adiciona regra de DROP
        iptables -I $chain $rule_num -m set --match-set "$ipset_name" src -j DROP
        if [ "$VERBOSE" = "yes" ]; then
            echo "Regras iptables para $chain adicionadas."
        fi
    else
        # Verifica se a regra já existe
        if ! iptables -nvL $chain | grep -q "match-set $ipset_name"; then
            # Adiciona regra de log
            iptables -I $chain $rule_num -m set --match-set "$ipset_name" src -j LOG --log-prefix "$prefix" --log-level 4
            # Adiciona regra de DROP
            iptables -I $chain $rule_num -m set --match-set "$ipset_name" src -j DROP
            if [ "$VERBOSE" = "yes" ]; then
                echo "Regras iptables para $chain adicionadas."
            fi
        else
            if [ "$VERBOSE" = "yes" ]; then
                echo "Regras iptables para $chain já existem."
            fi
        fi
    fi
}

# Verificação do arquivo de configuração
if [[ -z "$1" ]]; then
    echo "Erro: por favor, especifique um arquivo de configuração, ex: $0 /opt/ipset-blocklist/ipset-blocklist.conf"
    exit 1
fi

# Carrega o arquivo de configuração
if ! source "$1"; then
    echo "Erro: não foi possível carregar o arquivo de configuração $1"
    exit 1
fi

# Verifica se os comandos essenciais estão disponíveis
for cmd in curl grep ipset iptables sed sort mktemp; do
    if ! exists $cmd; then
        echo "Erro: comando '$cmd' não encontrado."
        exit 1
    fi
done

# Verifica a existência dos diretórios
for dir in $(dirname "$IP_BLOCKLIST_INCOMING") $(dirname "$IP_BLOCKLIST_OUTGOING") $(dirname "$IP_BLOCKLIST_INCOMING_RESTORE") $(dirname "$IP_BLOCKLIST_OUTGOING_RESTORE"); do
    if [[ ! -d "$dir" ]]; then
        echo "Erro: diretório $dir não existe."
        exit 1
    fi
done

# Cria ipsets se não existirem
for ipset in "$IPSET_INCOMING_NAME" "$IPSET_OUTGOING_NAME"; do
    if ! ipset list -n | grep -q "$ipset"; then
        ipset create "$ipset" hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-131072}"
        if [ "$VERBOSE" = "yes" ]; then
            echo "Ipset $ipset criado."
        fi
    fi
done

# Adiciona regras iptables para INPUT e OUTPUT
add_iptables_rules "INPUT" "$IPSET_INCOMING_NAME" "BLOCKED_IN: " "$IPTABLES_IPSET_RULE_NUMBER"
add_iptables_rules "OUTPUT" "$IPSET_OUTGOING_NAME" "BLOCKED_OUT: " "$IPTABLES_IPSET_RULE_NUMBER"

# Processamento dos blocklists de entrada
IP_BLOCKLIST_INCOMING_TMP=$(mktemp)
invalid_ip_count_in=0
valid_ip_count_in=0

for url in "${BLOCKLISTS_INCOMING[@]}"; do
    if [ "$VERBOSE" = "yes" ]; then
        echo "Processando blocklist de entrada: $url"
    fi
    result=$(curl -s "$url")
    if [ -z "$result" ]; then
        echo "Erro: Falha ao baixar o blocklist de $url"
        continue
    fi
    while read -r ip; do
        if ! validate_ip "$ip"; then
            invalid_ip_count_in=$((invalid_ip_count_in + 1))
            continue
        fi
        echo "$ip" >> "$IP_BLOCKLIST_INCOMING_TMP"
        valid_ip_count_in=$((valid_ip_count_in + 1))
    done <<< "$(echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')"
done

# Processamento dos blocklists de saída
IP_BLOCKLIST_OUTGOING_TMP=$(mktemp)
invalid_ip_count_out=0
valid_ip_count_out=0

for url in "${BLOCKLISTS_OUTGOING[@]}"; do
    if [ "$VERBOSE" = "yes" ]; then
        echo "Processando blocklist de saída: $url"
    fi
    result=$(curl -s "$url")
    if [ -z "$result" ]; then
        echo "Erro: Falha ao baixar o blocklist de $url"
        continue
    fi
    while read -r ip; do
        if ! validate_ip "$ip"; then
            invalid_ip_count_out=$((invalid_ip_count_out + 1))
            continue
        fi
        echo "$ip" >> "$IP_BLOCKLIST_OUTGOING_TMP"
        valid_ip_count_out=$((valid_ip_count_out + 1))
    done <<< "$(echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')"
done

# Filtra e otimiza IPs de entrada
sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_INCOMING_TMP" | sort -n | sort -mu > "$IP_BLOCKLIST_INCOMING"
rm -f "$IP_BLOCKLIST_INCOMING_TMP"

# Filtra e otimiza IPs de saída
sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_OUTGOING_TMP" | sort -n | sort -mu > "$IP_BLOCKLIST_OUTGOING"
rm -f "$IP_BLOCKLIST_OUTGOING_TMP"

# Prepara o arquivo de restore para ipset de entrada
cat > "$IP_BLOCKLIST_INCOMING_RESTORE" <<EOF
create $IPSET_INCOMING_NAME hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-131072}
EOF
sed -rn -e '/^#|^$/d' -e "s/^([0-9./]+).*/add $IPSET_INCOMING_NAME \\1/p" "$IP_BLOCKLIST_INCOMING" >> "$IP_BLOCKLIST_INCOMING_RESTORE"

# Prepara o arquivo de restore para ipset de saída
cat > "$IP_BLOCKLIST_OUTGOING_RESTORE" <<EOF
create $IPSET_OUTGOING_NAME hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-131072}
EOF
sed -rn -e '/^#|^$/d' -e "s/^([0-9./]+).*/add $IPSET_OUTGOING_NAME \\1/p" "$IP_BLOCKLIST_OUTGOING" >> "$IP_BLOCKLIST_OUTGOING_RESTORE"

# Restaura os ipsets
if [ "$VERBOSE" = "yes" ]; then
    echo "Atualizando listas do ipset..."
fi
ipset -file "$IP_BLOCKLIST_INCOMING_RESTORE" restore
ipset -file "$IP_BLOCKLIST_OUTGOING_RESTORE" restore

# Relatório final
if [ "$VERBOSE" = "yes" ]; then
    echo "Endereços IP bloqueados para entrada: $(wc -l "$IP_BLOCKLIST_INCOMING" | cut -d' ' -f1)"
    echo "Endereços IP bloqueados para saída: $(wc -l "$IP_BLOCKLIST_OUTGOING" | cut -d' ' -f1)"
    echo "IPs inválidos descartados para entrada: $invalid_ip_count_in"
    echo "IPs inválidos descartados para saída: $invalid_ip_count_out"
fi

# Limpa arquivos temporários
rm -f "$IP_BLOCKLIST_INCOMING_RESTORE" "$IP_BLOCKLIST_OUTGOING_RESTORE"
