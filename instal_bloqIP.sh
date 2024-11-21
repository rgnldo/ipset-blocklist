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
echo "Configurando cron jobs para regras iptables e atualização de blocklist..."

# Cron job para reinicialização: adiciona as regras de log e DROP
(crontab -l 2>/dev/null; echo "@reboot ipset restore < /opt/ipset-blocklist/ip-blocklist.restore && \
iptables -I INPUT -m set --match-set blocklist src -j LOG --log-prefix 'BLOCKED_IP: ' --log-level 4 && \
iptables -I INPUT -m set --match-set blocklist src -j DROP") | crontab -

# Cron job para atualizar a blocklist 5 minutos após o reboot
(crontab -l 2>/dev/null; echo "@reboot sleep 300 && /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf") | crontab -

# Cron job para atualização periódica da blocklist (sem regras de iptables)
(crontab -l 2>/dev/null; echo "0 */12 * * * /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf") | crontab -

echo "Cron jobs configurados com sucesso."

}

# Função para desinstalar o IPSet Blocklist
uninstall_ipset_blocklist() {
    # Remover regras do iptables e ipset
    iptables -D INPUT -m set --match-set blocklist src -j DROP 2>/dev/null
    # Remove regra de log
if iptables -C INPUT -m set --match-set blocklist src -j LOG --log-prefix "BLOCKED_IP: " --log-level 4 2>/dev/null; then
  iptables -D INPUT -m set --match-set blocklist src -j LOG --log-prefix "BLOCKED_IP: " --log-level 4
  echo "Regra de log removida."
else
  echo "Regra de log não encontrada."
fi
    ipset destroy blocklist

    # Remover arquivos e diretórios
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /opt/ipset-blocklist

    # Remover entradas do cron
    crontab -l 2>/dev/null | grep -v 'update-blocklist.sh' | grep -v 'iptables' | grep -v 'ipset restore' | crontab -

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
