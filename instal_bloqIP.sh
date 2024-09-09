#!/bin/bash

# Função para instalar pacotes ausentes
install_missing_packages() {
    # Verificar se o ipset e o wget estão instalados e instalar se estiverem ausentes
    MISSING_PACKAGES=()

    if ! command -v ipset &> /dev/null; then
        MISSING_PACKAGES+=("ipset")
    fi

    if ! command -v wget &> /dev/null; then
        MISSING_PACKAGES+=("wget")
    fi

    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        echo "Os seguintes pacotes estão faltando: ${MISSING_PACKAGES[*]}"
        read -p "Deseja instalar os pacotes necessários? (S/n): " install_choice

        if [[ "$install_choice" =~ ^[Ss]$ || -z "$install_choice" ]]; then
            if command -v apt &> /dev/null; then
                sudo apt update
                sudo apt install -y "${MISSING_PACKAGES[@]}"
            elif command -v yum &> /dev/null; then
                sudo yum install -y "${MISSING_PACKAGES[@]}"
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y "${MISSING_PACKAGES[@]}"
            elif command -v pacman &> /dev/null; then
                sudo pacman -S --noconfirm "${MISSING_PACKAGES[@]}"
            else
                echo "Erro: gerenciador de pacotes não suportado. Instale os pacotes manualmente."
                exit 1
            fi
        else
            echo "Instalação cancelada."
            exit 1
        fi
    else
        echo "Todos os pacotes necessários já estão instalados."
    fi
}

# Função para instalar o IPSet Blocklist
install_ipset_blocklist() {
    # Verificar e instalar pacotes ausentes
    install_missing_packages

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

    # Criar o arquivo do temporizador systemd
    cat <<EOF > /etc/systemd/system/ipset-blocklist.timer
[Unit]
Description=Agendador de 6 em 6 horas

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
AccuracySec=1s
Persistent=true

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

    # Remover arquivos e diretórios
    rm -rf /usr/local/sbin/update-blocklist.sh
    rm -rf /opt/ipset-blocklist
    rm -f /etc/systemd/system/ipset-blocklist.service
    rm -f /etc/systemd/system/ipset-blocklist.timer

    # Recarregar o systemd
    systemctl daemon-reload

    # Remover ipsets e regras iptables
    if ipset list -n | grep -q 'blocklist'; then
        echo "Removendo o ipset 'blocklist'"
        ipset destroy blocklist || echo "Erro ao destruir o ipset 'blocklist'"
    fi

    # Remover regras do iptables associadas ao ipset
    iptables-save | grep -E "match-set blocklist" | while read -r rule; do
        iptables -D INPUT "$(echo "$rule" | awk '{print $1}')" || echo "Erro ao remover regra do iptables."
    done

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
