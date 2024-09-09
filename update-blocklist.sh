#!/usr/bin/env bash
#
# usage update-blocklist.sh <configuration file>

#
function exists() { command -v "$1" >/dev/null 2>&1 ; }

if [[ -z "$1" ]]; then
  echo "Error: please specify a configuration file, e.g. $0 /opt/ipset-blocklist/ipset-blocklist.conf"
  exit 1
fi

# shellcheck source=ipset-blocklist.conf
if ! source "$1"; then
  echo "Error: can't load configuration file $1"
  exit 1
fi

if ! exists curl && exists egrep && exists grep && exists ipset && exists iptables && exists sed && exists sort && exists wc ; then
  echo >&2 "Error: searching PATH fails to find executables among: curl egrep grep ipset iptables sed sort wc"
  exit 1
fi

DO_OPTIMIZE_CIDR=no
if exists iprange && [[ ${OPTIMIZE_CIDR:-yes} != no ]]; then
  DO_OPTIMIZE_CIDR=yes
fi

if [[ ! -d $(dirname "$IP_BLOCKLIST") || ! -d $(dirname "$IP_BLOCKLIST_RESTORE") ]]; then
  echo >&2 "Error: missing directory(s): $(dirname "$IP_BLOCKLIST" "$IP_BLOCKLIST_RESTORE"|sort -u)"
  exit 1
fi

# create the ipset if needed (or abort if does not exists and FORCE=no)
if ! ipset list -n|command grep -q "$IPSET_BLOCKLIST_NAME"; then
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Error: ipset does not exist yet, add it using:"
    echo >&2 "# ipset create $IPSET_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}"
    exit 1
  fi
  if ! ipset create "$IPSET_BLOCKLIST_NAME" -exist hash:net family inet hashsize "${HASHSIZE:-16384}" maxelem "${MAXELEM:-65536}"; then
    echo >&2 "Error: while creating the initial ipset"
    exit 1
  fi
fi

# Verifica se a regra necessária no iptables está presente (ou aborta se não existir e FORCE=no)
if ! iptables -nvL INPUT | grep -q "match-set $IPSET_BLOCKLIST_NAME"; then
  # Se FORCE não estiver definido como 'yes', solicita ao usuário para adicionar manualmente a regra necessária no iptables.
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Erro: A regra do iptables para o ipset '$IPSET_BLOCKLIST_NAME' está ausente."
    echo >&2 "Adicione a regra manualmente usando o seguinte comando:"
    echo >&2 "# iptables -I INPUT ${IPTABLES_IPSET_RULE_NUMBER:-1} -m set --match-set $IPSET_BLOCKLIST_NAME src -j DROP"
    exit 1
  fi
  
  # Tenta adicionar a regra do ipset à cadeia INPUT na posição especificada.
  if ! iptables -I INPUT "${IPTABLES_IPSET_RULE_NUMBER:-1}" -m set --match-set "$IPSET_BLOCKLIST_NAME" src -j DROP; then
    echo >&2 "Erro: Falha ao adicionar a regra do ipset ao iptables."
    exit 1
  fi
fi

# Adiciona a regra para descartar os pacotes provenientes dos IPs na blocklist
iptables -A INPUT -m set --match-set "$IPSET_BLOCKLIST_NAME" src -j DROP

IP_BLOCKLIST_TMP=$(mktemp)
for i in "${BLOCKLISTS[@]}"
do
  IP_TMP=$(mktemp)
  (( HTTP_RC=$(curl -L -A "blocklist-update/script/github" --connect-timeout 10 --max-time 10 -o "$IP_TMP" -s -w "%{http_code}" "$i") ))
  if (( HTTP_RC == 200 || HTTP_RC == 302 || HTTP_RC == 0 )); then # "0" because file:/// returns 000
    command grep -Po '^(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' "$IP_TMP" | sed -r 's/^0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)$/\1.\2.\3.\4/' >> "$IP_BLOCKLIST_TMP"
    [[ ${VERBOSE:-yes} == yes ]] && echo -n "."
  elif (( HTTP_RC == 503 )); then
    echo -e "\\nUnavailable (${HTTP_RC}): $i"
  else
    echo >&2 -e "\\nWarning: curl returned HTTP response code $HTTP_RC for URL $i"
  fi
  rm -f "$IP_TMP"
done

# sort -nu does not work as expected
sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_TMP"|sort -n|sort -mu >| "$IP_BLOCKLIST"
if [[ ${DO_OPTIMIZE_CIDR} == yes ]]; then
  if [[ ${VERBOSE:-no} == yes ]]; then
    echo -e "\\nAddresses before CIDR optimization: $(wc -l "$IP_BLOCKLIST" | cut -d' ' -f1)"
  fi
  < "$IP_BLOCKLIST" iprange --optimize - > "$IP_BLOCKLIST_TMP" 2>/dev/null
  if [[ ${VERBOSE:-no} == yes ]]; then
    echo "Addresses after CIDR optimization:  $(wc -l "$IP_BLOCKLIST_TMP" | cut -d' ' -f1)"
  fi
  cp "$IP_BLOCKLIST_TMP" "$IP_BLOCKLIST"
fi

rm -f "$IP_BLOCKLIST_TMP"

# family = inet for IPv4 only
cat >| "$IP_BLOCKLIST_RESTORE" <<EOF
create $IPSET_TMP_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}
create $IPSET_BLOCKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-16384} maxelem ${MAXELEM:-65536}
EOF

# can be IPv4 including netmask notation
# IPv6 ? -e "s/^([0-9a-f:./]+).*/add $IPSET_TMP_BLOCKLIST_NAME \1/p" \ IPv6
sed -rn -e '/^#|^$/d' \
  -e "s/^([0-9./]+).*/add $IPSET_TMP_BLOCKLIST_NAME \\1/p" "$IP_BLOCKLIST" >> "$IP_BLOCKLIST_RESTORE"

cat >> "$IP_BLOCKLIST_RESTORE" <<EOF
swap $IPSET_BLOCKLIST_NAME $IPSET_TMP_BLOCKLIST_NAME
destroy $IPSET_TMP_BLOCKLIST_NAME
EOF

ipset -file  "$IP_BLOCKLIST_RESTORE" restore

if [[ ${VERBOSE:-no} == yes ]]; then
  echo
  echo "Blacklisted addresses found: $(wc -l "$IP_BLOCKLIST" | cut -d' ' -f1)"
fi
