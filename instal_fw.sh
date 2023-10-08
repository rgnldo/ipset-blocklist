#!/bin/bash

# Função para instalar o IPSet Blocklist
install_ipset_blocklist() {
    # Verificar se o ipset e o wget estão instalados
    if ! command -v ipset &> /dev/null; then
        echo "O ipset não está instalado. Instale-o antes de prosseguir."
        exit 1
    fi

    if ! command -v wget &> /dev/null; then
        echo "O wget não está instalado. Instale-o antes de prosseguir."
        exit 1
    fi

    # Criar diretórios
    mkdir -p /opt/ipset-blocklist

    # Baixar scripts e configurar
    wget -O /usr/local/sbin/update-blocklist.sh https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh
    chmod +x /usr/local/sbin/update-blocklist.sh

    wget -O /opt/ipset-blocklist/ipset-blocklist.conf https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/ipset-blocklist.conf

    # Gerar a lista em /opt/ipset-blocklist/ip-blocklist.restore
    /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

    # Configurar iptables regras
    ipset restore < /opt/ipset-blocklist/ip-blocklist.restore
    iptables -I INPUT 1 -m set --match-set blocklist src -j DROP
    
    # Adicionar no CRON
    cat <<EOF > /etc/cron.d/update-blocklist
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
33 23 * * * root /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
EOF

    # Criar o arquivo de serviço systemd
    cat <<EOF > /etc/systemd/system/ipset-blocklist.service
[Unit]
Description=IPSet Blocklist Service
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

    # Recarregar o serviço systemd
    systemctl daemon-reload

    # Habilitar o serviço para iniciar após o boot
    systemctl enable ipset-blocklist.service

    # Iniciar o serviço systemd
    systemctl start ipset-blocklist.service

    echo "Instalação concluída com sucesso."
}

# Função para desinstalar o IPSet Blocklist
uninstall_ipset_blocklist() {
    # Parar o serviço systemd
    systemctl stop ipset-blocklist.service
    systemctl disable ipset-blocklist.service

    # Remover arquivos e diretórios
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /opt/ipset-blocklist
    rm -f /etc/systemd/system/ipset-blocklist.service
    rm -f /etc/cron.d/update-blocklist

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

