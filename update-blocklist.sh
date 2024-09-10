#!/usr/bin/env bash
#
# Script para atualizar e aplicar blocklists com ipset e iptables
# Uso: update-blocklist.sh <arquivo de configuração>

# Função para verificar se o comando existe
function exists() { command -v "$1" >/dev/null 2>&1 ; }

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
if ! exists curl || ! exists grep || ! exists ipset || ! exists iptables || ! exists sed || ! exists sort || ! exists wc ; then
  echo >&2 "Erro: faltam executáveis: curl grep ipset iptables sed sort wc"
  exit 1
fi

# Define se otimizaremos CIDR (blocos de IP)
DO_OPTIMIZE_CIDR=no
if exists iprange && [[ ${OPTIMIZE_CIDR:-yes} != no ]]; then
  DO_OPTIMIZE_CIDR=yes
fi

# Verificação dos diretórios
if [[ ! -d $(dirname "$IP_BLOCKLIST") || ! -d $(dirname "$IP_BLOCKLIST_RESTORE") ]]; then
  echo >&2 "Erro: diretório(s) faltando: $(dirname "$IP_BLOCKLIST" "$IP_BLOCKLIST_RESTORE"|sort -u)"
  exit 1
fi

# Criação do ipset se ele não existir
if ! ipset list -n | grep -q "$IPSET_BLOCKLIST_NAME"; then
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Erro: o ipset ainda não existe, crie usando:"
    echo >&2 "# ipset create $IPSET_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}"
    exit 1
  fi
  ipset create "$IPSET_BLOCKLIST_NAME" -exist hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-65536}"
fi

# Criação da chain BLOCKLIST no iptables se não existir
if ! iptables -L BLOCKLIST -n >/dev/null 2>&1; then
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Erro: a chain BLOCKLIST não existe, adicione usando:"
    echo >&2 "# iptables -N BLOCKLIST"
    exit 1
  fi
  iptables -N BLOCKLIST
  iptables -A BLOCKLIST -m set --match-set "$IPSET_BLOCKLIST_NAME" src -j DROP
fi

# Adiciona a chain BLOCKLIST à chain INPUT se não estiver presente
if ! iptables -L INPUT -n | grep -q "BLOCKLIST"; then
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Erro: a chain BLOCKLIST não está na chain INPUT, adicione usando:"
    echo >&2 "# iptables -I INPUT ${IPTABLES_IPSET_RULE_NUMBER:-1} -j BLOCKLIST"
    exit 1
  fi
  iptables -I INPUT "${IPTABLES_IPSET_RULE_NUMBER:-1}" -j BLOCKLIST
fi

# Processamento dos blocklists
IP_BLOCKLIST_TMP=$(mktemp)
for url in "${BLOCKLISTS[@]}"; do
  result=$(curl -s "$url")
  if [ -n "$result" ]; then
    echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' >> "$IP_BLOCKLIST_TMP"
  else
    echo "Sem resultado de: $url"
  fi
done

# Elimina IPs locais, ordena e otimiza CIDR
sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_TMP" | sort -n | sort -mu >| "$IP_BLOCKLIST"

if [[ $DO_OPTIMIZE_CIDR == yes ]]; then
  [[ ${VERBOSE:-no} == yes ]] && echo -e "\\nEndereços antes da otimização CIDR: $(wc -l "$IP_BLOCKLIST" | cut -d' ' -f1)"
  < "$IP_BLOCKLIST" iprange --optimize - > "$IP_BLOCKLIST_TMP" 2>/dev/null
  [[ ${VERBOSE:-no} == yes ]] && echo "Endereços após a otimização CIDR: $(wc -l "$IP_BLOCKLIST_TMP" | cut -d' ' -f1)"
  cp "$IP_BLOCKLIST_TMP" "$IP_BLOCKLIST"
fi

rm -f "$IP_BLOCKLIST_TMP"

# Preparação do arquivo para o restore do ipset
cat >| "$IP_BLOCKLIST_RESTORE" <<EOF
create $IPSET_TMP_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}
create $IPSET_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}
EOF

# Processamento final do blocklist
sed -rn -e '/^#|^$/d' -e "s/^([0-9./]+).*/add $IPSET_TMP_BLOCKLIST_NAME \\1/p" "$IP_BLOCKLIST" >> "$IP_BLOCKLIST_RESTORE"

cat >> "$IP_BLOCKLIST_RESTORE" <<EOF
swap $IPSET_BLOCKLIST_NAME $IPSET_TMP_BLOCKLIST_NAME
destroy $IPSET_TMP_BLOCKLIST_NAME
EOF

ipset -file "$IP_BLOCKLIST_RESTORE" restore

# Relatório final
[[ ${VERBOSE:-no} == yes ]] && echo "Endereços IP bloqueados: $(wc -l "$IP_BLOCKLIST" | cut -d' ' -f1)"
