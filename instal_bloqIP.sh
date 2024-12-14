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
"$SCRIPT_ATUALIZAR" "$ARQUIVO_CONF"
EOF
    chmod +x "$SCRIPT_REBOOT"

    cat > "$ARQUIVO_CRON" << EOF
@reboot root "$SCRIPT_REBOOT" >> "$DIRETORIO_LOG/blocklist_reboot.log" 2>&1
0 */12 * * * root "$SCRIPT_ATUALIZAR" "$ARQUIVO_CONF" >> "$DIRETORIO_LOG/blocklist_update.log" 2>&1
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

# Função para verificar o status do blocklist
verificar_status() {
    # (Implementar lógica de verificação de status)
    echo "Lógica de verificação de status aqui."
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
        3) verificar_status ;;
        4) echo "Saindo."; exit 0 ;;
        *) echo "Opção inválida. Por favor, tente novamente."; sleep 2 ;;
    esac
done
