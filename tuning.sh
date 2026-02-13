#!/bin/bash
# Hardening + Tuning Script com Benchmark para GLPI 11
# Compatível Debian 13 / Ubuntu 24
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Versão: 1.0
# Veja o link: https://wiki.projetoroot.com.br/index.php?title=GLPI_11
# 2026

set -e
PATH=$PATH:/sbin:/usr/sbin

# =========================
# DEPENDÊNCIAS
# =========================
echo "* Verificando dependências..."
for pkg in bc procps ufw sysbench jq curl wget sudo; do
    if ! dpkg -s $pkg >/dev/null 2>&1; then
        echo "* Instalando $pkg..."
        apt update -qq
        apt install -y $pkg >/dev/null
    fi
done
echo "* Dependências OK"

BACKUP_DIR="/var/backups/glpi-tuner/$(date +%s)"
mkdir -p "$BACKUP_DIR"

# =========================
# DETECTA HARDWARE
# =========================
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB/1024))
CPU_CORES=$(nproc)

format_ram() {
    if [ $RAM_MB -lt 1024 ]; then
        echo "${RAM_MB}MB"
    else
        GB=$(echo "scale=1; $RAM_MB/1024" | bc)
        echo "${GB}GB"
    fi
}

# =========================
# DETECTA GLPI
# =========================
GLPI_PATH=$(find /var/www/html -maxdepth 1 -type d -name "glpi" | head -n1)

get_glpi_version() {
    if [ -d "$GLPI_PATH/version" ]; then
        VERSION_FILE=$(ls -1 "$GLPI_PATH/version" | head -n1)
        echo "$VERSION_FILE"
    else
        echo "-"
    fi
}

# =========================
# BACKUP
# =========================
echo "* Backup configs em $BACKUP_DIR"
cp -r /etc/ssh /etc/sysctl.d /etc/ufw "$BACKUP_DIR/" || true

echo "Hardware detectado:"
echo "RAM= $(format_ram), CPU=${CPU_CORES} cores"
echo "GLPI detectado em: $GLPI_PATH"
echo

# =========================
# HARDENING SYSCTL
# =========================
SWAPPINESS=20
FIN_TIMEOUT=15
SOMAXCONN=2048
PORT_RANGE_LOW=1024
PORT_RANGE_HIGH=65000

read_sysctl() {
    local key=$1
    sysctl -n "$key" 2>/dev/null || echo "-"
}

apply_sysctl() {
    echo "* Aplicando ajustes sysctl..."
    SYSCTL_FILE="/etc/sysctl.d/99-glpi-tuned.conf"

    # Salvar valores atuais
    BEFORE_SWAPPINESS=$(read_sysctl vm.swappiness)
    BEFORE_SOMAXCONN=$(read_sysctl net.core.somaxconn)
    BEFORE_FIN_TIMEOUT=$(read_sysctl net.ipv4.tcp_fin_timeout)
    BEFORE_PORT_RANGE=$(read_sysctl net.ipv4.ip_local_port_range)

    cat <<EOF > $SYSCTL_FILE
# Kernel hardening e tuning para GLPI
kernel.core_pattern = core
kernel.sysrq = 0
kernel.core_uses_pid = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.core.somaxconn = $SOMAXCONN
vm.swappiness = $SWAPPINESS
net.ipv4.ip_local_port_range = $PORT_RANGE_LOW $PORT_RANGE_HIGH
net.ipv4.tcp_syncookies = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF

    sysctl --system >/dev/null

    # Ler valores após aplicação
    AFTER_SWAPPINESS=$(read_sysctl vm.swappiness)
    AFTER_SOMAXCONN=$(read_sysctl net.core.somaxconn)
    AFTER_FIN_TIMEOUT=$(read_sysctl net.ipv4.tcp_fin_timeout)
    AFTER_PORT_RANGE=$(read_sysctl net.ipv4.ip_local_port_range)
    echo "* Sysctl aplicado"
}

# =========================
# FIREWALL
# =========================
configure_firewall() {
    echo "* Configurando firewall (UFW)..."

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    echo "* Firewall ativo com regras específicas para GLPI"
}

# =========================
# REDE TUNING
# =========================
apply_network_tuning() {
    echo "* Aplicando tuning de rede..."
    NET_FILE="/etc/sysctl.d/99-glpi-network.conf"

    if [ "$RAM_MB" -ge 8192 ]; then
        RMEM_MAX=16777216
        WMEM_MAX=16777216
    else
        RMEM_MAX=8388608
        WMEM_MAX=8388608
    fi

    cat <<EOF > $NET_FILE
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX
net.ipv4.tcp_window_scaling = 1
EOF

    sysctl --system >/dev/null
    echo "* Tuning de rede aplicado"
}

# =========================
# PHP / Apache / MySQL TUNING
# =========================
apply_php_apache_mysql_tuning() {
    echo "* Aplicando tuning de Apache, PHP e MySQL..."

    # PHP
    PHP_INI=$(php -r "echo php_ini_loaded_file();" 2>/dev/null)
    if [ -f "$PHP_INI" ]; then
        sed -i "s/^memory_limit.*/memory_limit = 512M/" "$PHP_INI"
        sed -i "s/^max_execution_time.*/max_execution_time = 300/" "$PHP_INI"
        sed -i "s/^post_max_size.*/post_max_size = 128M/" "$PHP_INI"
        sed -i "s/^upload_max_filesize.*/upload_max_filesize = 128M/" "$PHP_INI"
    fi

    # Apache
    APACHE_CONF="/etc/apache2/apache2.conf"
    if [ -f "$APACHE_CONF" ]; then
        sed -i "s/^StartServers.*/StartServers $((CPU_CORES))/" "$APACHE_CONF" || true
        sed -i "s/^MinSpareServers.*/MinSpareServers $((CPU_CORES*2))/" "$APACHE_CONF" || true
        sed -i "s/^MaxSpareServers.*/MaxSpareServers $((CPU_CORES*4))/" "$APACHE_CONF" || true
        sed -i "s/^MaxRequestWorkers.*/MaxRequestWorkers $((CPU_CORES*50))/" "$APACHE_CONF" || true
    fi

    # MySQL tuning mínimo
    MYSQL_CNF="/etc/mysql/my.cnf"
    if [ -f "$MYSQL_CNF" ]; then
        sed -i "/\[mysqld\]/a innodb_buffer_pool_size=$(($RAM_KB*1024/2))" "$MYSQL_CNF"
        sed -i "/\[mysqld\]/a max_connections=$((CPU_CORES*50))" "$MYSQL_CNF"
    fi

    echo "* Tuning de aplicações aplicado"
}

# =========================
# BENCHMARK SYSBENCH
# =========================
run_benchmark() {
    echo "* Executando benchmark com sysbench..."
    apt install -y sysbench > /dev/null

    # CPU
    CPU_BEFORE=$(sysbench cpu --cpu-max-prime=10000 run | grep "total time:" | awk '{print $3}')
    BENCH_CPU="${CPU_BEFORE}s"

    # Memória
    MEM_BEFORE=$(sysbench memory --memory-block-size=1M --memory-total-size=64M run \
             | grep "transferred" \
             | awk '{print $1, $2 " transferred at " $5}')
    BENCH_MEM="${MEM_BEFORE:-"-"}"

    # Disco
    sysbench fileio --file-total-size=64M --file-test-mode=seqwr prepare >/dev/null
    DISK_BEFORE=$(sysbench fileio --file-total-size=64M --file-test-mode=seqwr run | grep "total time:" | awk '{print $3}')
    sysbench fileio --file-total-size=64M --file-test-mode=seqwr cleanup >/dev/null
    BENCH_DISK="${DISK_BEFORE}s"
}

# =========================
# EXECUÇÃO
# =========================
apply_sysctl
configure_firewall
apply_network_tuning
apply_php_apache_mysql_tuning
run_benchmark

# =========================
# RELATÓRIO FINAL
# =========================
echo
echo "===== RELATÓRIO HARDENING & TUNING ====="
echo "ITEM                  | ANTES      		| DEPOIS    "
echo "----------------------+-------------------------+-----------"
echo "swappiness            | $BEFORE_SWAPPINESS  	  		| $AFTER_SWAPPINESS"
echo "somaxconn             | $BEFORE_SOMAXCONN   	  		| $AFTER_SOMAXCONN"
echo "fin_timeout           | $BEFORE_FIN_TIMEOUT 	  		| $AFTER_FIN_TIMEOUT"
echo "port_range            | $BEFORE_PORT_RANGE  	  	| $AFTER_PORT_RANGE"
echo
echo "===== SEGURANÇA SSH ====="
SSH_PASS=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config || echo "padrão")
SSH_ROOT=$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config || echo "padrão")
echo "PasswordAuthentication    : ${SSH_PASS:-padrão}"
echo "PermitRootLogin           : ${SSH_ROOT:-padrão}"
echo
echo "===== FIREWALL ====="
echo "Status: $(ufw status | head -n1 | awk '{print $2}')"
ufw status | tail -n +2 | awk '{printf "  %-22s %-10s %s\n", $1, $2, $3}'

echo
echo "===== HARDWARE ====="
echo "RAM                       : $(format_ram)"
echo "CPU                       : $CPU_CORES cores"
echo "GLPI Path                 : $GLPI_PATH"
echo "GLPI Version              : $(get_glpi_version)"
echo
echo "===== BENCHMARK SYSBENCH ====="
echo "CPU                       : $BENCH_CPU"
echo "Mem                       : $BENCH_MEM"
echo "Disk                      : $BENCH_DISK"
echo
echo "Finalizado"
