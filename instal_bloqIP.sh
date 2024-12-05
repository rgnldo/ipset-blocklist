#!/bin/bash

# Função para instalar pacotes necessários
instalar_pacotes_necessarios() {
    # Verificar se ipset e wget estão instalados e instalar se necessário
    if ! command -v ipset &> /dev/null; then
        echo -e "\n\033[33mIpset não encontrado. Instalando...\033[0m"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y ipset
        elif command -v yum &> /dev/null; then
            yum install -y ipset
        elif command -v dnf &> /dev/null; then
            dnf install -y ipset
        else
            echo -e "\n\033[31mGerenciador de pacotes não suportado. Instale o ipset manualmente.\033[0m"
            exit 1
        fi
    fi

    if ! command -v wget &> /dev/null; then
        echo -e "\n\033[33mWget não encontrado. Instalando...\033[0m"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y wget
        elif command -v yum &> /dev/null; then
            yum install -y wget
        elif command -v dnf &> /dev/null; then
            dnf install -y wget
        else
            echo -e "\n\033[31mGerenciador de pacotes não suportado. Instale o wget manualmente.\033[0m"
            exit 1
        fi
    fi
}

# Função para instalar o IPSet Blocklist
instalar_ipset_blocklist() {
    # Instalar pacotes necessários
    instalar_pacotes_necessarios

    # Criar diretórios
    mkdir -p /opt/ipset-blocklist

    # Baixar scripts e configurar
    wget -O /usr/local/sbin/update-blocklist.sh https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh
    chmod +x /usr/local/sbin/update-blocklist.sh

    wget -O /opt/ipset-blocklist/ipset-blocklist.conf https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/ipset-blocklist.conf

    # Gerar a lista inicial
    /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

    # Configurar cron jobs
    echo -e "\n\033[33mConfigurando cron jobs para regras iptables e atualização de blocklist...\033[0m"

    # Criar arquivo cron dedicado
    echo "@reboot ipset restore < /opt/ipset-blocklist/ip-blocklist.restore && iptables -I INPUT -m set --match-set blocklist src -j LOG --log-prefix 'BLOCKED_IP: ' --log-level 4 && iptables -I INPUT -m set --match-set blocklist src -j DROP" > /etc/cron.d/ipset-blocklist
    echo "@reboot sleep 300 && /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf" >> /etc/cron.d/ipset-blocklist
    echo "0 */12 * * * /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf" >> /etc/cron.d/ipset-blocklist

    chmod 0644 /etc/cron.d/ipset-blocklist

    echo -e "\n\033[32mCron jobs configurados com sucesso.\033[0m"
}

# Função para desinstalar o IPSet Blocklist
desinstalar_ipset_blocklist() {
    read -p "Tem certeza que deseja desinstalar o IPSet Blocklist? (S/N): " confirmacao
    if [[ "$confirmacao" != [Ss] ]]; then
        echo -e "\n\033[33mDesinstalação cancelada.\033[0m"
        return
    fi

    # Remover regras do iptables e ipset
    iptables -D INPUT -m set --match-set blocklist src -j DROP 2>/dev/null
    if iptables -C INPUT -m set --match-set blocklist src -j LOG --log-prefix "BLOCKED_IP: " --log-level 4 2>/dev/null; then
        iptables -D INPUT -m set --match-set blocklist src -j LOG --log-prefix "BLOCKED_IP: " --log-level 4
        echo -e "\n\033[32mRegra de log removida.\033[0m"
    else
        echo -e "\n\033[33mRegra de log não encontrada.\033[0m"
    fi
    ipset destroy blocklist

    # Remover arquivos e diretórios
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /opt/ipset-blocklist

    # Remover cron jobs
    rm -f /etc/cron.d/ipset-blocklist

    echo -e "\n\033[32mDesinstalação concluída com sucesso.\033[0m"
}

# Função para verificar o status do IPSet Blocklist
verificar_status() {
    if [[ -f /opt/ipset-blocklist/ip-blocklist.restore && -f /usr/local/sbin/update-blocklist.sh ]]; then
        echo -e "\n\033[32mIPSet Blocklist está instalado.\033[0m"
    else
        echo -e "\n\033[31mIPSet Blocklist não está instalado.\033[0m"
        return
    fi

    # Verificar regras do iptables
    if iptables -S INPUT | grep -q 'blocklist src -j DROP'; then
        echo -e "\033[32mRegra DROP no iptables está ativa.\033[0m"
    else
        echo -e "\033[31mRegra DROP no iptables não está ativa.\033[0m"
    fi

    if iptables -S INPUT | grep -q 'blocklist src -j LOG'; then
        echo -e "\033[32mRegra LOG no iptables está ativa.\033[0m"
    else
        echo -e "\033[31mRegra LOG no iptables não está ativa.\033[0m"
    fi

    # Verificar estado do ipset
    if ipset list | grep -q 'blocklist'; then
        echo -e "\033[32mIpset blocklist está ativo.\033[0m"
    else
        echo -e "\033[31mIpset blocklist não está ativo.\033[0m"
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
            instalar_ipset_blocklist
            ;;
        2)
            desinstalar_ipset_blocklist
            ;;
        3)
            verificar_status
            ;;
        4)
            echo "Saindo."
            exit 0
            ;;
        *)
            echo -e "\n\033[31mOpção inválida. Tente novamente.\033[0m"
            ;;
    esac

    read -p "Pressione Enter para continuar..."
done
