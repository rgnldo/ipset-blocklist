#!/bin/bash

# Função para instalar pacotes necessários
install_missing_packages() {
    # Verificar se o ipset e o wget estão instalados e instalar se necessário
    if ! command -v ipset &> /dev/null; then
        echo "Instalando ipset..."
        apt-get update && apt-get install -y ipset || { echo "Falha ao instalar ipset."; exit 1; }
    fi

    if ! command -v wget &> /dev/null; then
        echo "Instalando wget..."
        apt-get update && apt-get install -y wget || { echo "Falha ao instalar wget."; exit 1; }
    fi
}

# Função para instalar o IPSet Blocklist
install_ipset_blocklist() {
    # Instalar pacotes necessários
    install_missing_packages

    # Criar diretórios
    mkdir -p /opt/ipset-blocklist

    # Baixar scripts e configurar
    wget -O /usr/local/sbin/update-blocklist.sh https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh
    chmod +x /usr/local/sbin/update-blocklist.sh

    wget -O /opt/ipset-blocklist/ipset-blocklist.conf https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/ipset-blocklist.conf

    # Gerar a lista inicial
    /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

    # Adicionar cron jobs
    (crontab -l 2>/dev/null; echo "@reboot ipset restore < /opt/ipset-blocklist/ip-blocklist.restore && iptables -I INPUT -m set --match-set blocklist src -j DROP") | crontab -
    (crontab -l 2>/dev/null; echo "0 */12 * * * /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf") | crontab -

    echo "Instalação concluída com sucesso."
}

# Função para desinstalar o IPSet Blocklist
uninstall_ipset_blocklist() {
    # Remover regras do iptables e ipset
    iptables -D INPUT -m set --match-set blocklist src -j DROP 2>/dev/null
    ipset destroy blocklist

    # Remover arquivos e diretórios
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /opt/ipset-blocklist

    # Remover entradas do cron
    crontab -l 2>/dev/null | grep -v 'update-blocklist.sh' | grep -v 'ipset restore' | crontab -

    echo "Desinstalação concluída com sucesso."
}

# Menu interativo
while true; do
    clear
    echo "Instalador do IPSet Blocklist"
    echo "-----------------------------"
    echo "1. Instalar IPSet Blocklist"
    echo "2. Desinstalar IPSet Blocklist"
    echo "3. Sair"

    read -p "Escolha uma opção (1/2/3): " choice

    case $choice in
        1)
            install_ipset_blocklist
            ;;
        2)
            uninstall_ipset_blocklist
            ;;
        3)
            echo "Saindo."
            exit 0
            ;;
        *)
            echo "Opção inválida. Tente novamente."
            ;;
    esac
done
