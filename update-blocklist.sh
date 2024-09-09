#!/usr/bin/env bash
#
# usage: update-blocklist.sh <configuration file>

# Function to check if a command exists
function exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if configuration file is provided
if [[ -z "$1" ]]; then
  echo "Error: please specify a configuration file, e.g. $0 /opt/ipset-blocklist/ipset-blocklist.conf"
  exit 1
fi

# Source the configuration file
if ! source "$1"; then
  echo "Error: can't load configuration file $1"
  exit 1
fi

# Check for required commands
if ! exists curl || ! exists egrep || ! exists grep || ! exists ipset || ! exists iptables || ! exists sed || ! exists sort || ! exists wc ; then
  echo >&2 "Error: searching PATH fails to find executables among: curl egrep grep ipset iptables sed sort wc"
  exit 1
fi

# Default values for optimization
DO_OPTIMIZE_CIDR=no
if exists iprange && [[ ${OPTIMIZE_CIDR:-yes} != no ]]; then
  DO_OPTIMIZE_CIDR=yes
fi

# Check if directories exist
if [[ ! -d $(dirname "$IP_BLOCKLIST") || ! -d $(dirname "$IP_BLOCKLIST_RESTORE") ]]; then
  echo >&2 "Error: missing directory(s): $(dirname "$IP_BLOCKLIST" "$IP_BLOCKLIST_RESTORE" | sort -u)"
  exit 1
fi

# Create the ipsets if they don't exist
for i in {1..5}; do
  IPSET_NAME="${IPSET_BLOCKLIST_NAME}_${i}"
  if ! ipset list -n | grep -q "^$IPSET_NAME$"; then
    if [[ ${FORCE:-no} != yes ]]; then
      echo >&2 "Error: ipset '$IPSET_NAME' does not exist yet, create it using:"
      echo >&2 "# ipset create $IPSET_NAME hash:net family inet hashsize ${HASHSIZE:-32768} maxelem ${MAXELEM:-131072}"
      exit 1
    fi
    if ! ipset create "$IPSET_NAME" hash:net family inet hashsize "${HASHSIZE:-32768}" maxelem "${MAXELEM:-131072}"; then
      echo >&2 "Error: while creating the initial ipset '$IPSET_NAME'"
      exit 1
    fi
  fi
done

# Check iptables rules
if ! iptables -nvL INPUT | grep -q "match-set ${IPSET_BLOCKLIST_NAME}_1"; then
  if [[ ${FORCE:-no} != yes ]]; then
    echo >&2 "Error: iptables rule for ipset '${IPSET_BLOCKLIST_NAME}_1' is missing."
    echo >&2 "Add it manually using:"
    echo >&2 "# iptables -I INPUT ${IPTABLES_IPSET_RULE_NUMBER:-1} -m set --match-set ${IPSET_BLOCKLIST_NAME}_1 src -j DROP"
    exit 1
  fi
  if ! iptables -I INPUT "${IPTABLES_IPSET_RULE_NUMBER:-1}" -m set --match-set "${IPSET_BLOCKLIST_NAME}_1" src -j DROP; then
    echo >&2 "Error: Failed to add iptables rule for ipset '${IPSET_BLOCKLIST_NAME}_1'."
    exit 1
  fi
fi

# Process blocklists
IP_BLOCKLIST_TMP=$(mktemp)
for url in "${BLOCKLISTS[@]}"; do
  IP_TMP=$(mktemp)
  HTTP_RC=$(curl -L -A "blocklist-update/script/github" --connect-timeout 10 --max-time 10 -o "$IP_TMP" -s -w "%{http_code}" "$url")
  if [[ $HTTP_RC -eq 200 || $HTTP_RC -eq 302 || $HTTP_RC -eq 0 ]]; then
    grep -Po '^(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' "$IP_TMP" | sed -r 's/^0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)$/\1.\2.\3.\4/' >> "$IP_BLOCKLIST_TMP"
    [[ ${VERBOSE:-yes} == yes ]] && echo -n "."
  elif [[ $HTTP_RC -eq 503 ]]; then
    echo -e "\\nUnavailable (${HTTP_RC}): $url"
  else
    echo >&2 -e "\\nWarning: curl returned HTTP response code $HTTP_RC for URL $url"
  fi
  rm -f "$IP_TMP"
done

# Filter and sort the blocklist
sed -r -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLOCKLIST_TMP" | sort -n | sort -mu > "$IP_BLOCKLIST"
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

# Create restore file
IP_BLOCKLIST_RESTORE=$(mktemp)
cat > "$IP_BLOCKLIST_RESTORE" <<EOF
create ${IPSET_BLOCKLIST_NAME}_1 -exist hash:net family inet hashsize ${HASHSIZE:-32768} maxelem ${MAXELEM:-131072}
EOF

# Add IPs to the restore file
for i in {1..5}; do
  IPSET_NAME="${IPSET_BLOCKLIST_NAME}_${i}"
  sed -rn -e '/^#|^$/d' -e "s/^([0-9./]+).*/add $IPSET_NAME \\1/p" "$IP_BLOCKLIST" >> "$IP_BLOCKLIST_RESTORE"
done

cat >> "$IP_BLOCKLIST_RESTORE" <<EOF
swap ${IPSET_BLOCKLIST_NAME}_1 ${IPSET_BLOCKLIST_NAME}_2
destroy ${IPSET_BLOCKLIST_NAME}_2
EOF

ipset -file "$IP_BLOCKLIST_RESTORE" restore
rm -f "$IP_BLOCKLIST_RESTORE"

if [[ ${VERBOSE:-no} == yes ]]; then
  echo
  echo "Blacklisted addresses found: $(wc -l "$IP_BLOCKLIST" | cut -d' ' -f1)"
fi
