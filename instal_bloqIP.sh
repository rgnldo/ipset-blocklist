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

    # Gerar a lista em /opt/ipset-blocklist/ip-blocklist.restore
    /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
    

    # Criar o arquivo do serviço systemd
    cat <<EOF > /etc/systemd/system/ipset-blocklist.service
[Unit]
Description=IPSet Blocklist Service
After=network-online.target

[Service]
Type=simple
ExecStart=ipset restore < /opt/ipset-blocklist/ip-blocklist.restore
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

    # Criar o arquivo do temporizador systemd
   cat <<EOF > /etc/systemd/system/ipset-blocklist.timer
[Unit]
Description=Agendador de 6 em 6 horas para atualização do IPSet Blocklist

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
AccuracySec=1s
Persistent=true

[Service]
ExecStart=/usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf

[Install]
WantedBy=timers.target
EOF


    # Recarregar o systemd
    systemctl daemon-reload

    # Habilitar o temporizador e o serviço para iniciar após o boot
    systemctl enable ipset-blocklist.timer
    systemctl enable ipset-blocklist.service
    systemctl start ipset-blocklist.timer
    systemctl start ipset-blocklist.service

    echo "Instalação concluída com sucesso."
}

# Função para desinstalar o IPSet Blocklist
uninstall_ipset_blocklist() {
    # Parar o serviço e temporizador systemd
    systemctl stop ipset-blocklist.service
    systemctl disable ipset-blocklist.service
    systemctl stop ipset-blocklist.timer
    systemctl disable ipset-blocklist.timer

    # Remover regras do iptables e ipset
    iptables -D INPUT -m set --match-set blocklist  src -j DROP 2>/dev/null
    ipset destroy blocklist

    # Remover arquivos e diretórios
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /opt/ipset-blocklist
    rm -f /etc/systemd/system/ipset-blocklist.service
    rm -f /etc/systemd/system/ipset-blocklist.timer

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
