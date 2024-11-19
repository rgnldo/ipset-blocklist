#!/usr/bin/env bash
#
# Script para atualizar e aplicar blocklists com ipset e iptables
# Uso: update-blocklist.sh <arquivo de configuração>

# Função para verificar se o comando existe
function exists() { command -v "$1" >/dev/null 2>&1 ; }

# Função para validar IP/CIDR
function validate_ip() {
  # Valida IPs ou CIDRs válidos
  if [[ ! "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
    return 1  # IP inválido
  fi
  # Validando se os octetos do IP estão no intervalo correto (0-255)
  IFS='.' read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    if [[ "$octet" -gt 255 || "$octet" -lt 0 ]]; then
      return 1  # IP inválido
    fi
  done
  return 0  # IP válido
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
if ! exists curl || ! exists grep || ! exists ipset || ! exists iptables || ! exists sed || ! exists sort || ! exists wc ; then
  echo >&2 "Erro: faltam executáveis: curl grep ipset iptables sed sort wc"
  exit 1
fi

# Verificação dos diretórios
if [[ ! -d $(dirname "$IP_BLOCKLIST") || ! -d $(dirname "$IP_BLOCKLIST_RESTORE") ]]; then
  echo >&2 "Erro: diretório(s) faltando: $(dirname "$IP_BLOCKLIST" "$IP_BLOCKLIST_RESTORE"|sort -u)"
  exit 1
fi

# Criação do ipset se ele não existir
if ! ipset list -n | grep -q "$IPSET_BLOCKLIST_NAME"; then
  echo "Criando ipset $IPSET_BLOCKLIST_NAME"
  ipset create "$IPSET_BLOCKLIST_NAME" -exist hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-65536}"
fi

# Adiciona a regra iptables se ela não existir
echo "Adiciona a regra iptables se ela não existir"
# Verifica se a regra de iptables já existe
if ! iptables -nvL INPUT | grep -q "match-set $IPSET_BLOCKLIST_NAME"; then
  # Se a regra não existir, adicionar a regra ao INPUT
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Atenção: A regra iptables com ipset não existe. Adicionando..."
    echo >&2 "# iptables -I INPUT ${IPTABLES_IPSET_RULE_NUMBER:-1} -m set --match-set $IPSET_BLOCKLIST_NAME src -j DROP"
  fi

  # Adiciona a regra no iptables
  if ! iptables -I INPUT "${IPTABLES_IPSET_RULE_NUMBER:-1}" -m set --match-set "$IPSET_BLOCKLIST_NAME" src -j DROP; then
    echo >&2 "Erro: Falha ao adicionar a regra --match-set ipset ao iptables."
    exit 1
  fi
else
  echo "A regra iptables já existe. Nenhuma alteração foi feita."
fi

# Realiza o flush da lista do ipset
echo "Realizando flush da lista do ipset $IPSET_BLOCKLIST_NAME"
if ipset list "$IPSET_BLOCKLIST_NAME" >/dev/null 2>&1; then
  ipset flush "$IPSET_BLOCKLIST_NAME"
else
  echo "Aviso: ipset não encontrado. Criando nova lista."
fi

# Processamento dos blocklists
IP_BLOCKLIST_TMP=$(mktemp)
invalid_ip_count=0
valid_ip_count=0

for url in "${BLOCKLISTS[@]}"; do
  echo "Processando blocklist: $url"
  result=$(curl -s "$url")
  if [ -n "$result" ]; then
    while read -r ip; do
      # Valida o IP
      if ! validate_ip "$ip"; then
        invalid_ip_count=$((invalid_ip_count + 1))
        continue  # Ignora o IP inválido
      fi
      echo "$ip" >> "$IP_BLOCKLIST_TMP"
      valid_ip_count=$((valid_ip_count + 1))
    done <<< "$(echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')"
  else
    echo "Sem resultado de: $url"
  fi
done

# Relatório de IPs inválidos e válidos
echo "IPs inválidos descartados: $invalid_ip_count"
echo "IPs válidos processados: $valid_ip_count"

# Se não houver IPs válidos, aborta
if [[ "$valid_ip_count" -eq 0 ]]; then
  echo "Erro: nenhum IP válido encontrado. Abortando."
  rm -f "$IP_BLOCKLIST_TMP"
  exit 1
fi

# Elimina IPs locais, ordena e otimiza CIDR
echo "Filtrando e otimizando os IPs..."
sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_TMP" | sort -n | sort -mu >| "$IP_BLOCKLIST"

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

# Restaura o ipset
echo "Atualizando a lista do ipset..."
ipset -file "$IP_BLOCKLIST_RESTORE" restore

# Relatório final
echo "Endereços IP bloqueados: $(wc -l "$IP_BLOCKLIST" | cut -d' ' -f1)"
