#!/bin/bash
# Instalador automático da versão mais atual do Agent GLPI no Debian 13
# Instala e/ou atualiza os módulos:
# * Inventory
# * NetInventory
# * ESX
# * Collect
# * Deploy
# * IEC61850
# Para instalar basta dar um wget na url do script e após bash install-glpi-agent.sh
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Versão: 1.0
# Veja o link: https://wiki.projetoroot.com.br/index.php?title=GLPI_11
# 2026

set -e

echo "Consultando última versão do GLPI Agent..."

LATEST_VERSION=$(curl -s https://api.github.com/repos/glpi-project/glpi-agent/releases/latest | grep tag_name | cut -d '"' -f4)

if [ -z "$LATEST_VERSION" ]; then
  echo "Falha ao obter versão mais recente."
  exit 1
fi

LATEST_DEB_VERSION="${LATEST_VERSION#v}-1"
ARCH="amd64"
BASE_URL="https://github.com/glpi-project/glpi-agent/releases/download/${LATEST_VERSION}"

echo "Versão mais recente disponível: $LATEST_DEB_VERSION"
echo

# Detectar versão da API do Perl do sistema
SYSTEM_PERL_API=$(perl -V:api_versionstring 2>/dev/null | cut -d"'" -f2)
REQUIRED_PERL_API="5.38.2"

SKIP_IEC=false
if [ "$SYSTEM_PERL_API" != "$REQUIRED_PERL_API" ]; then
    echo "Perl API do sistema: $SYSTEM_PERL_API"
    echo "IEC61850 requer perlapi $REQUIRED_PERL_API. Módulo será ignorado."
    SKIP_IEC=true
else
    echo "Perl compatível para módulo IEC61850 detectado."
fi

echo

declare -A PACKAGES
PACKAGES["glpi-agent"]="glpi-agent_${LATEST_DEB_VERSION}_all.deb"
PACKAGES["glpi-agent-task-network"]="glpi-agent-task-network_${LATEST_DEB_VERSION}_all.deb"
PACKAGES["glpi-agent-task-collect"]="glpi-agent-task-collect_${LATEST_DEB_VERSION}_all.deb"
PACKAGES["glpi-agent-task-deploy"]="glpi-agent-task-deploy_${LATEST_DEB_VERSION}_all.deb"
PACKAGES["glpi-agent-task-esx"]="glpi-agent-task-esx_${LATEST_DEB_VERSION}_all.deb"

if [ "$SKIP_IEC" = false ]; then
    PACKAGES["libiec61850-glpi-agent"]="libiec61850-glpi-agent_${LATEST_DEB_VERSION}_${ARCH}.deb"
    OPTIONAL_PACKAGES=("libiec61850-glpi-agent")
else
    OPTIONAL_PACKAGES=()
fi

DOWNLOAD_LIST=()
UPDATED=false

for PKG in "${!PACKAGES[@]}"; do
    FILE="${PACKAGES[$PKG]}"
    INSTALLED_VERSION=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || echo "none")

    if [ "$INSTALLED_VERSION" = "none" ]; then
        echo "➡ $PKG não instalado. Será instalado."
        DOWNLOAD_LIST+=("$FILE")
    else
        if dpkg --compare-versions "$INSTALLED_VERSION" ge "$LATEST_DEB_VERSION"; then
            echo "✔ $PKG já está atualizado ($INSTALLED_VERSION)"
        else
            echo "⬆ $PKG desatualizado ($INSTALLED_VERSION). Será atualizado."
            DOWNLOAD_LIST+=("$FILE")
        fi
    fi
done

echo
if [ ${#DOWNLOAD_LIST[@]} -eq 0 ]; then
    echo "Todos os componentes já estão na versão mais recente."
    exit 0
fi

echo "Baixando apenas os pacotes necessários..."
for FILE in "${DOWNLOAD_LIST[@]}"; do
    wget -q --show-progress "${BASE_URL}/${FILE}"
done

echo "Instalando pacotes com resolução automática de dependências..."
apt-get update -qq

for deb in *.deb; do
    PKG_NAME=$(dpkg-deb -f "$deb" Package)

    if apt-get install -y "./$deb"; then
        echo "✔ Instalado: $PKG_NAME"
        UPDATED=true
    else
        if [[ " ${OPTIONAL_PACKAGES[@]} " =~ " ${PKG_NAME} " ]]; then
            echo "⚠ Pacote opcional $PKG_NAME não pôde ser instalado. Ignorando."
            apt-get remove -y "$PKG_NAME" 2>/dev/null || true
        else
            echo "❌ Falha ao instalar pacote obrigatório: $PKG_NAME"
            exit 1
        fi
    fi
done

if [ "$UPDATED" = true ]; then
    echo "Atualizando sistema..."
    apt-get update -y
    apt-get upgrade -y
    apt-get dist-upgrade -y
    apt-get autoremove -y
    apt-get autoclean -y
    apt-get clean

    echo "Reiniciando serviço glpi-agent..."
    systemctl restart glpi-agent || true
fi

echo "Limpando instaladores..."
rm -f *.deb

echo "Processo concluído com sucesso."
