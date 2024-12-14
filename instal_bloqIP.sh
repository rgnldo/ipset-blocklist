#!/bin/bash

# Função para instalar pacotes faltantes
install_missing_packages() {
    # Verificar e instalar ipset
    if ! command -v ipset &> /dev/null; then
        echo "Instalando ipset..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y ipset
        elif command -v yum &> /dev/null; then
            yum install -y ipset
        elif command -v dnf &> /dev/null; then
            dnf install -y ipset
        else
            echo "Gerenciador de pacotes não suportado. Instale o ipset manualmente."
            exit 1
        fi
    fi

    # Verificar e instalar wget
    if ! command -v wget &> /dev/null; then
        echo "Instalando wget..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y wget
        elif command -v yum &> /dev/null; then
            yum install -y wget
        elif command -v dnf &> /dev/null; then
            dnf install -y wget
        else
            echo "Gerenciador de pacotes não suportado. Instale o wget manualmente."
            exit 1
        fi
    fi
}

# Função para instalar IPSet Blocklist
install_ipset_blocklist() {
    # Instalar pacotes faltantes
    install_missing_packages

    # Criar diretórios
    mkdir -p /opt/ipset-blocklist

    # Baixar scripts e configuração
    wget -O /usr/local/sbin/update-blocklist.sh https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh
    chmod +x /usr/local/sbin/update-blocklist.sh

    # Criar reboot_script.sh usando sed
    cat > /usr/local/sbin/reboot_script.sh << EOF
#!/bin/bash

# Restaurar ipset a partir do backup
ipset restore < /opt/ipset-blocklist/ip-blocklist.restore

# Adicionar regras iptables
iptables -I INPUT -m set --match-set blocklist src -j LOG --log-prefix 'BLOCKED_IP: ' --log-level 4
iptables -I INPUT -m set --match-set blocklist src -j DROP

# Aguardar por 5 minutos
sleep 300

# Atualizar blocklist
/usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
EOF
    chmod +x /usr/local/sbin/reboot_script.sh

    wget -O /opt/ipset-blocklist/ipset-blocklist.conf https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/ipset-blocklist.conf

    # Gerar blocklist inicial
    /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

    # Configurar trabalhos cron
    cat > /etc/cron.d/ipset-blocklist << EOF
@reboot root /usr/local/sbin/reboot_script.sh >> /var/log/blocklist_reboot.log 2>&1
0 */12 * * * root /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf >> /var/log/blocklist_update.log 2>&1
EOF
    chmod 0644 /etc/cron.d/ipset-blocklist

    echo "Trabalhos cron configurados com sucesso."
}

# Função para desinstalar IPSet Blocklist
uninstall_ipset_blocklist() {
    read -p "Tem certeza que deseja desinstalar o IPSet Blocklist? (S/N): " confirmacao
    if [[ "$confirmacao" != [Ss] ]]; then
        echo "Desinstalação cancelada."
        return
    fi

    # Remover regras iptables
    iptables -D INPUT -m set --match-set blocklist src -j DROP 2>/dev/null
    iptables -D INPUT -m set --match-set blocklist src -j LOG --log-prefix "BLOCKED_IP: " --log-level 4 2>/dev/null

    # Destruir ipset
    ipset destroy blocklist

    # Remover scripts e arquivos de configuração
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /usr/local/sbin/reboot_script.sh
    rm -rf /opt/ipset-blocklist

    # Remover trabalhos cron
    rm -f /etc/cron.d/ipset-blocklist

    # Remover arquivos de log, se existirem
    rm -f /var/log/blocklist_reboot.log
    rm -f /var/log/blocklist_update.log
    rm -f /var/log/blocklist.log

    echo "Desinstalação concluída com sucesso."
}

# Função para verificar o status do IPSet Blocklist
check_status() {
    if [[ -f /opt/ipset-blocklist/ip-blocklist.restore && -f /usr/local/sbin/update-blocklist.sh ]]; then
        echo -e "${GREEN}IPSet Blocklist está instalado.${NC}"
    else
        echo -e "${RED}IPSet Blocklist não está instalado.${NC}"
        return
    fi

    # Check iptables rules
    if iptables -S INPUT | grep -q 'blocklist src -j DROP'; then
        echo -e "${GREEN}Regra DROP no iptables está ativa.${NC}"
    else
        echo -e "${RED}Regra DROP no iptables não está ativa.${NC}"
    fi

    if iptables -S INPUT | grep -q 'blocklist src -j LOG'; then
        echo -e "${GREEN}Regra LOG no iptables está ativa.${NC}"
    else
        echo -e "${RED}Regra LOG no iptables não está ativa.${NC}"
    fi

    # Check ipset status
    if ipset list | grep -q 'blocklist'; then
        echo -e "${GREEN}Ipset blocklist está ativo.${NC}"

        # Get IP count
        ip_count=$(ipset list blocklist | grep '^' | wc -l)
        echo -e "${YELLOW}Total de IPs bloqueados: ${GREEN}${ip_count}${NC}"

        # Get last update time
        last_update=$(stat -c %y /opt/ipset-blocklist/ip-blocklist.restore)
        echo -e "${YELLOW}Última atualização: ${GREEN}${last_update}${NC}"

        # Check for blocklist actions
        log_file=$(grep 'LOGFILE' /opt/ipset-blocklist/ipset-blocklist.conf | cut -d '=' -f2 | tr -d ' ')
        if [[ -z "$log_file" ]]; then
            log_file="/var/log/blocklist.log"
        fi
        if [[ -f "$log_file" ]]; then
            blocked_ips=$(grep 'BLOCKED_IP:' "$log_file" | wc -l)
            echo -e "${YELLOW}Total de bloqueios realizados: ${GREEN}${blocked_ips}${NC}"
        else
            echo -e "${RED}Arquivo de log não encontrado. O caminho do log está especificado corretamente na configuração?${NC}"
        fi
    else
        echo -e "${RED}Ipset blocklist não está ativo.${NC}"
    fi
}

# Menu interativo
while true; do
    clear
    echo "Instalador do IPSet Blocklist"
    echo "-----------------------------"
    echo "1. Instalar IPSet Blocklist"
    echo "2. Desinstalar IPSet Blocklist"
    echo "3. Verificar Status do Blocklist"
    echo "4. Sair"

    read -p "Escolha uma opção (1/2/3/4): " opcao

    case $opcao in
        1)
            install_ipset_blocklist
            ;;
        2)
            uninstall_ipset_blocklist
            ;;
        3)
            check_status
            ;;
        4)
            echo "Saindo."
            exit 0
            ;;
        *)
            echo "Opção inválida. Tente novamente."
            ;;
    esac

    read -p "Pressione Enter para continuar..."
done
