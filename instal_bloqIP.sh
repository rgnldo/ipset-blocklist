#!/bin/bash

# Variáveis de cores
VERDE='\033[0;32m'
VERMELHO='\033[0;31m'
AMARELO='\033[0;33m'
NC='\033[0m' # Sem cor

# Constantes
DIRETORIO_BLOCKLIST="/opt/ipset-blocklist"
DIRETORIO_LOG="/var/log"
SCRIPT_REBOOT="/usr/local/sbin/reboot_script.sh"
SCRIPT_ATUALIZAR="/usr/local/sbin/update-blocklist.sh"
ARQUIVO_CRON="/etc/cron.d/ipset-blocklist"
URL_BASE="https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master"

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
    echo -e "${VERMELHO}Este script deve ser executado como root.${NC}"
    exit 1
fi

# Função para registrar erros
log_error() {
    echo -e "${VERMELHO}[ERRO] $1${NC}"
    exit 1
}

# Função para instalar pacotes
instalar_pacote() {
    local pacote=$1
    if ! command -v "$pacote" &> /dev/null; then
        echo -e "${AMARELO}Instalando $pacote...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y "$pacote" || log_error "Falha ao instalar $pacote usando apt-get."
        elif command -v yum &> /dev/null; then
            yum install -y "$pacote" || log_error "Falha ao instalar $pacote usando yum."
        elif command -v dnf &> /dev/null; then
            dnf install -y "$pacote" || log_error "Falha ao instalar $pacote usando dnf."
        else
            log_error "Gerenciador de pacotes não suportado. Instale $pacote manualmente."
        fi
    else
        echo -e "${VERDE}$pacote já está instalado.${NC}"
    fi
}

# Instalar pacotes ausentes
instalar_pacotes_ausentes() {
    instalar_pacote ipset
    instalar_pacote wget
    instalar_pacote curl
}

# Função para instalar IPSet Blocklist
instalar_ipset_blocklist() {
    instalar_pacotes_ausentes

    mkdir -p "$DIRETORIO_BLOCKLIST" || log_error "Falha ao criar o diretório $DIRETORIO_BLOCKLIST."

    wget -O "$SCRIPT_ATUALIZAR" "$URL_BASE/update-blocklist.sh" || log_error "Falha ao baixar update-blocklist.sh."
    chmod +x "$SCRIPT_ATUALIZAR"

    cat > "$SCRIPT_REBOOT" << EOF
#!/bin/bash

ipset restore < "$DIRETORIO_BLOCKLIST/incoming_blocklist.restore"
ipset restore < "$DIRETORIO_BLOCKLIST/outgoing_blocklist.restore"

iptables -I INPUT -m set --match-set incoming_blocklist src -j LOG --log-prefix 'BLOQUEADO_ENTRADA: ' --log-level 4
iptables -I INPUT -m set --match-set incoming_blocklist src -j DROP
iptables -I OUTPUT -m set --match-set outgoing_blocklist dst -j LOG --log-prefix 'BLOQUEADO_SAIDA: ' --log-level 4
iptables -I OUTPUT -m set --match-set outgoing_blocklist dst -j DROP

sleep 300
"$SCRIPT_ATUALIZAR"
EOF
    chmod +x "$SCRIPT_REBOOT"

    cat > "$ARQUIVO_CRON" << EOF
@reboot root "$SCRIPT_REBOOT" >> "$DIRETORIO_LOG/blocklist_reboot.log" 2>&1
0 */12 * * * root "$SCRIPT_ATUALIZAR" >> "$DIRETORIO_LOG/blocklist_update.log" 2>&1
EOF
    chmod 0644 "$ARQUIVO_CRON"

    echo -e "${VERDE}IPSet Blocklist instalado e trabalhos cron configurados com sucesso.${NC}"
}

# Função para desinstalar
desinstalar_ipset_blocklist() {
    read -p "Tem certeza de que deseja desinstalar o IPSet Blocklist? (S/N): " confirmacao
    if [[ "$confirmacao" != [Ss] ]]; then
        echo "Desinstalação cancelada."
        return
    fi

    iptables -D INPUT -m set --match-set incoming_blocklist src -j DROP 2>/dev/null
    iptables -D INPUT -m set --match-set incoming_blocklist src -j LOG 2>/dev/null
    iptables -D OUTPUT -m set --match-set outgoing_blocklist dst -j DROP 2>/dev/null
    iptables -D OUTPUT -m set --match-set outgoing_blocklist dst -j LOG 2>/dev/null

    ipset destroy incoming_blocklist 2>/dev/null
    ipset destroy outgoing_blocklist 2>/dev/null

    rm -rf "$DIRETORIO_BLOCKLIST" "$SCRIPT_ATUALIZAR" "$SCRIPT_REBOOT" "$ARQUIVO_CRON" \
           "$DIRETORIO_LOG/blocklist_reboot.log" "$DIRETORIO_LOG/blocklist_update.log"

    echo -e "${VERDE}Desinstalação concluída com sucesso.${NC}"
}

# Função para verificar o status do IPSet Blocklist
check_status() {
    # Verificar se os arquivos de restauração e o script de atualização existem
    if [[ -f "$DIRETORIO_BLOCKLIST/incoming_blocklist.restore" && -f "$DIRETORIO_BLOCKLIST/outgoing_blocklist.restore" && -f "$SCRIPT_ATUALIZAR" ]]; then
        echo -e "${VERDE}IPSet Blocklist está instalado.${NC}"
    else
        echo -e "${VERMELHO}IPSet Blocklist não está instalado.${NC}"
        return
    fi

    # Verificar regras DROP no iptables para entrada
    if iptables -S INPUT | grep -q 'incoming_blocklist src -j DROP'; then
        echo -e "${VERDE}Regra DROP no iptables para entrada está ativa.${NC}"
    else
        echo -e "${VERMELHO}Regra DROP no iptables para entrada não está ativa.${NC}"
    fi

    # Verificar regras DROP no iptables para saída
    if iptables -S OUTPUT | grep -q 'outgoing_blocklist dst -j DROP'; then
        echo -e "${VERDE}Regra DROP no iptables para saída está ativa.${NC}"
    else
        echo -e "${VERMELHO}Regra DROP no iptables para saída não está ativa.${NC}"
    fi

    # Verificar regras LOG no iptables para entrada
    if iptables -S INPUT | grep -q 'incoming_blocklist src -j LOG'; then
        echo -e "${VERDE}Regra LOG no iptables para entrada está ativa.${NC}"
    else
        echo -e "${VERMELHO}Regra LOG no iptables para entrada não está ativa.${NC}"
    fi

    # Verificar regras LOG no iptables para saída
    if iptables -S OUTPUT | grep -q 'outgoing_blocklist dst -j LOG'; then
        echo -e "${VERDE}Regra LOG no iptables para saída está ativa.${NC}"
    else
        echo -e "${VERMELHO}Regra LOG no iptables para saída não está ativa.${NC}"
    fi

    # Verificar status dos ipsets
    if ipset list | grep -q 'incoming_blocklist'; then
        echo -e "${VERDE}Ipset incoming_blocklist está ativo.${NC}"
    else
        echo -e "${VERMELHO}Ipset incoming_blocklist não está ativo.${NC}"
    fi

    if ipset list | grep -q 'outgoing_blocklist'; then
        echo -e "${VERDE}Ipset outgoing_blocklist está ativo.${NC}"
    else
        echo -e "${VERMELHO}Ipset outgoing_blocklist não está ativo.${NC}"
    fi

    # Obter o total de IPs bloqueados
    incoming_ips=$(ipset list incoming_blocklist | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{0,2})?' | wc -l)
    outgoing_ips=$(ipset list outgoing_blocklist | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{0,2})?' | wc -l)
    total_ips=$((incoming_ips + outgoing_ips))
    echo -e "${AMARELO}Total de IPs bloqueados: ${VERDE}${total_ips}${NC}"

    # Obter a última atualização das blocklists
    last_update_incoming=$(stat -c %y "$DIRETORIO_BLOCKLIST/incoming_blocklist.restore")
    last_update_outgoing=$(stat -c %y "$DIRETORIO_BLOCKLIST/outgoing_blocklist.restore")
    echo -e "${AMARELO}Última atualização da blocklist de entrada: ${VERDE}${last_update_incoming}${NC}"
    echo -e "${AMARELO}Última atualização da blocklist de saída: ${VERDE}${last_update_outgoing}${NC}"

    # Obter o total de bloqueios realizados
    log_file="/var/log/kern.log"
    if [[ -f "$log_file" ]]; then
        blocked_incoming=$(grep 'BLOQUEADO_ENTRADA:' "$log_file" | wc -l)
        blocked_outgoing=$(grep 'BLOQUEADO_SAIDA:' "$log_file" | wc -l)
        total_blocked=$((blocked_incoming + blocked_outgoing))
        echo -e "${AMARELO}Total de bloqueios realizados para entrada: ${VERDE}${blocked_incoming}${NC}"
        echo -e "${AMARELO}Total de bloqueios realizados para saída: ${VERDE}${blocked_outgoing}${NC}"
        echo -e "${AMARELO}Total de bloqueios realizados: ${VERDE}${total_blocked}${NC}"
    else
        echo -e "${VERMELHO}Arquivo de log do kernel não encontrado. Verifique o caminho do log.${NC}"
    fi
}

# Menu
while true; do
    clear
    echo "Instalador de Blocklist IPSet"
    echo "-----------------------------"
    echo "1. Instalar IPSet Blocklist"
    echo "2. Desinstalar IPSet Blocklist"
    echo "3. Verificar Status do Blocklist"
    echo "4. Sair"

    read -p "Selecione uma opção (1/2/3/4): " opcao

    case $opcao in
        1) instalar_ipset_blocklist ;;
        2) desinstalar_ipset_blocklist ;;
        3) check_status ;;
        4) echo "Saindo."; exit 0 ;;
        *) echo "Opção inválida. Por favor, tente novamente."; sleep 2 ;;
    esac
done
