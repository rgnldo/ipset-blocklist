#!/usr/bin/env bash
#
# Script para atualizar a blocklist usando ipset e iptables
# Uso: update-blocklist.sh <arquivo de configuração>

# Função para verificar se um comando existe
function exists() { type -P "$1" >/dev/null 2>&1 ; }

# Função para exibir mensagens de erro
function log_error() { echo >&2 "Erro: $1"; }

# Função para exibir mensagens informativas
function log_info() { echo "$1"; }

# Verifica se um arquivo de configuração foi fornecido
if [[ -z "$1" ]]; then
  log_error "Por favor, especifique um arquivo de configuração, por exemplo: $0 /opt/ipset-blocklist/ipset-blocklist.conf"
  exit 1
fi

# Carrega o arquivo de configuração
if ! source "$1"; then
  log_error "Não foi possível carregar o arquivo de configuração $1"
  exit 1
fi

# Verifica se todas as dependências estão instaladas
for cmd in curl egrep grep ipset iptables sed sort wc; do
  if ! exists "$cmd"; then
    log_error "O comando $cmd não foi encontrado no sistema."
    exit 1
  fi
done

# Define se será feita a otimização CIDR
DO_OPTIMIZE_CIDR=no
if exists iprange && [[ ${OPTIMIZE_CIDR:-yes} != no ]]; then
  DO_OPTIMIZE_CIDR=yes
fi

# Verifica se os diretórios para os arquivos de blocklist existem
if [[ ! -d $(dirname "$IP_BLOCKLIST") || ! -d $(dirname "$IP_BLOCKLIST_RESTORE") ]]; then
  log_error "Diretório(s) ausente(s): $(dirname "$IP_BLOCKLIST" "$IP_BLOCKLIST_RESTORE" | sort -u)"
  exit 1
fi

# Remove o ipset existente antes de criar um novo
if ipset list -n | grep -q "$IPSET_BLOCKLIST_NAME"; then
  log_info "Removendo o ipset existente: $IPSET_BLOCKLIST_NAME"
  
  # Remove as regras do iptables que usam o ipset
  iptables-save | grep -E "match-set $IPSET_BLOCKLIST_NAME" | while read -r rule; do
    iptables -D INPUT "$(echo "$rule" | awk '{print $1}')" || log_error "Não foi possível remover a regra do iptables."
  done
  
  # Destrói o ipset
  if ! ipset destroy "$IPSET_BLOCKLIST_NAME"; then
    log_error "Não foi possível destruir o ipset '$IPSET_BLOCKLIST_NAME'."
    exit 1
  fi
fi

# Cria um novo ipset
if ! ipset create "$IPSET_BLOCKLIST_NAME" hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-65536}"; then
  log_error "Erro ao criar o ipset inicial"
  exit 1
fi

# Verifica se a regra do iptables para o ipset já existe
if ! iptables -nvL INPUT | grep -q "match-set $IPSET_BLOCKLIST_NAME"; then
  if [[ ${FORCE:-no} != yes ]]; then
    log_error "A regra do iptables para o ipset '$IPSET_BLOCKLIST_NAME' está ausente."
    log_error "Adicione a regra manualmente usando o comando:"
    log_error "# iptables -I INPUT ${IPTABLES_IPSET_RULE_NUMBER:-1} -m set --match-set $IPSET_BLOCKLIST_NAME src -j DROP"
    exit 1
  fi
  if ! iptables -I INPUT "${IPTABLES_IPSET_RULE_NUMBER:-1}" -m set --match-set "$IPSET_BLOCKLIST_NAME" src -j DROP; then
    log_error "Falha ao adicionar a regra do ipset ao iptables."
    exit 1
  fi
fi

# Cria um arquivo temporário para a blocklist
IP_BLOCKLIST_TMP=$(mktemp)
for url in "${BLOCKLISTS[@]}"; do
  IP_TMP=$(mktemp)
  HTTP_RC=$(curl -L -A "blocklist-update/script/github" --connect-timeout 10 --max-time 10 -o "$IP_TMP" -s -w "%{http_code}" "$url")
  
  if [[ $HTTP_RC == 200 || $HTTP_RC == 302 || $HTTP_RC == 0 ]]; then
    grep -Po '^(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' "$IP_TMP" | \
    sed -r 's/^0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)$/\1.\2.\3.\4/' >> "$IP_BLOCKLIST_TMP"
    [[ ${VERBOSE:-yes} == yes ]] && echo -n "."
  elif [[ $HTTP_RC == 503 ]]; then
    log_info "Indisponível (${HTTP_RC}): $url"
  else
    log_error "Aviso: o curl retornou o código de resposta HTTP $HTTP_RC para a URL $url"
  fi
  rm -f "$IP_TMP"
done

# Remove IPs de faixas reservadas e ordena os endereços IP
sed -r '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_TMP" | \
sort -n | sort -mu >| "$IP_BLOCKLIST"

# Otimização CIDR, se ativada
if [[ $DO_OPTIMIZE_CIDR == yes ]]; then
  [[ ${VERBOSE:-no} == yes ]] && log_info "Endereços antes da otimização CIDR: $(wc -l < "$IP_BLOCKLIST")"
  
  iprange --optimize < "$IP_BLOCKLIST" > "$IP_BLOCKLIST_TMP" 2>/dev/null
  [[ ${VERBOSE:-no} == yes ]] && log_info "Endereços após a otimização CIDR: $(wc -l < "$IP_BLOCKLIST_TMP")"
  
  cp "$IP_BLOCKLIST_TMP" "$IP_BLOCKLIST"
fi

rm -f "$IP_BLOCKLIST_TMP"

# Gera o arquivo de restauração do ipset
cat >| "$IP_BLOCKLIST_RESTORE" <<EOF
create $IPSET_TMP_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}
create $IPSET_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}
EOF

# Adiciona os IPs à blocklist temporária
sed -rn '/^#|^$/d' \
  -e "s/^([0-9./]+).*/add $IPSET_TMP_BLOCKLIST_NAME \\1/p" "$IP_BLOCKLIST" >> "$IP_BLOCKLIST_RESTORE"

# Troca as listas e destrói a temporária
cat >> "$IP_BLOCKLIST_RESTORE" <<EOF
swap $IPSET_BLOCKLIST_NAME $IPSET_TMP_BLOCKLIST_NAME
destroy $IPSET_TMP_BLOCKLIST_NAME
EOF

# Restaura o ipset com a nova blocklist
ipset restore -file "$IP_BLOCKLIST_RESTORE"

# Exibe o resultado, se verbose estiver ativado
if [[ ${VERBOSE:-no} == yes ]]; then
  log_info
  log_info "Endereços IP adicionados à blocklist: $(wc -l < "$IP_BLOCKLIST")"
fi

# Limpeza final
rm -f "$IP_BLOCKLIST_RESTORE"

# Mensagem de sucesso
log_info "Blocklist atualizada com sucesso."
