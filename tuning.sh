#!/bin/bash
# Hardening + Tuning Script com Benchmark para GLPI 11
# Compatível Debian 13 / Ubuntu 24
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Versão: 1.1
# Veja o link: https://wiki.projetoroot.com.br/index.php?title=GLPI_11
# 2026
set -e
PATH=$PATH:/sbin:/usr/sbin
echo " "
echo "##### Hardening + Tuning Script com Benchmark para GLPI 11 #####"
echo "##### Configura o seu sistema para aumentar a performance e a segurança no ambiente GLPI 11 #####"
echo " "
# =========================
# DEPENDÊNCIAS
# =========================
echo "* Verificando dependências..."

REQUIRED_PKGS="bc procps ufw sysbench jq curl wget sudo"
MISSING_PKGS=""

for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    echo "* Instalando dependências:$MISSING_PKGS"
    apt update -qq
    apt install -y $MISSING_PKGS >/dev/null
else
    echo "* Nenhuma instalação necessária"
fi

echo "* Dependências OK"

BACKUP_DIR="/var/backups/glpi-tuner/$(date +%s)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/apache2 "$BACKUP_DIR/" || true
cp -r /etc/mysql "$BACKUP_DIR/" || true
cp -r /etc/php "$BACKUP_DIR/" || true


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
# CAPTURA VARIÁVEIS MARIADB
# =========================
read_mysql_var() {
    mysql -N -e "SHOW VARIABLES LIKE '$1';" 2>/dev/null | awk '{print $2}'
}

MYSQL_BEFORE_MAX_CONN=$(read_mysql_var max_connections)
MYSQL_BEFORE_WAIT=$(read_mysql_var wait_timeout)
MYSQL_BEFORE_INTER=$(read_mysql_var interactive_timeout)
MYSQL_BEFORE_QCACHE=$(read_mysql_var query_cache_size)
MYSQL_BEFORE_JOIN=$(read_mysql_var join_buffer_size)
MYSQL_BEFORE_TABLE=$(read_mysql_var table_open_cache)
MYSQL_BEFORE_POOL=$(read_mysql_var innodb_buffer_pool_size)
MYSQL_BEFORE_LOG=$(read_mysql_var innodb_log_file_size)

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
# PHP / Apache / MariaDB TUNING
# =========================
apply_php_apache_mysql_tuning() {

    echo "* Aplicando tuning PHP, Apache e MariaDB..."

    # =========================
    # PHP TUNING POR RAM
    # =========================

    calc_php_mem() {
        if [ "$RAM_MB" -lt 1024 ]; then echo 128M
        elif [ "$RAM_MB" -lt 2048 ]; then echo 192M
        elif [ "$RAM_MB" -lt 4096 ]; then echo 256M
        elif [ "$RAM_MB" -lt 8192 ]; then echo 384M
        elif [ "$RAM_MB" -lt 16384 ]; then echo 512M
        else echo 768M
        fi
    }

    PHP_MEM=$(calc_php_mem)
    PHP_INI=$(php -r "echo php_ini_loaded_file();" 2>/dev/null)

    if [ -f "$PHP_INI" ]; then
        sed -i "s/^memory_limit.*/memory_limit = $PHP_MEM/" "$PHP_INI"
        sed -i "s/^max_execution_time.*/max_execution_time = 300/" "$PHP_INI"
        sed -i "s/^post_max_size.*/post_max_size = 128M/" "$PHP_INI"
        sed -i "s/^upload_max_filesize.*/upload_max_filesize = 128M/" "$PHP_INI"
    fi

    # =========================
    # APACHE TUNING REAL (RAM + CPU)
    # =========================

    APACHE_MPM=$(apachectl -V 2>/dev/null | grep -i mpm | awk -F: '{print $2}' | tr -d ' ')

    calc_workers() {
        MEM_PER_CHILD=60
        MAX_RAM=$((RAM_MB / MEM_PER_CHILD))
        MAX_CPU=$((CPU_CORES * 40))

        if [ "$MAX_RAM" -lt "$MAX_CPU" ]; then
            echo "$MAX_RAM"
        else
            echo "$MAX_CPU"
        fi
    }

    MAX_REQ=$(calc_workers)

    if [ "$APACHE_MPM" = "prefork" ]; then

cat <<EOF > /etc/apache2/conf-available/glpi-mpm.conf
StartServers             $CPU_CORES
MinSpareServers          $CPU_CORES
MaxSpareServers          $((CPU_CORES*2))
MaxRequestWorkers        $MAX_REQ
MaxConnectionsPerChild   1000
EOF

    else

cat <<EOF > /etc/apache2/conf-available/glpi-mpm.conf
StartServers              2
ThreadsPerChild           25
MinSpareThreads           50
MaxSpareThreads           150
MaxRequestWorkers         $((MAX_REQ*2))
MaxConnectionsPerChild    2000
EOF

    fi

    a2enconf glpi-mpm >/dev/null 2>&1 || true
    systemctl reload apache2 >/dev/null 2>&1 || true


    # =========================
    # MariaDB TUNING
    # =========================

    if systemctl is-active mariadb >/dev/null 2>&1; then

        MYSQL_TUNED="/etc/mysql/mariadb.conf.d/99-glpi-tuned.cnf"

        calc_pool_mb() {
            if [ "$RAM_MB" -lt 2048 ]; then echo 256
            elif [ "$RAM_MB" -lt 4096 ]; then echo 512
            elif [ "$RAM_MB" -lt 8192 ]; then echo 1536
            elif [ "$RAM_MB" -lt 16384 ]; then echo 4096
            elif [ "$RAM_MB" -lt 32768 ]; then echo 8192
            else echo 20480
            fi
        }

        POOL_MB=$(calc_pool_mb)
        LOG_MB=$((POOL_MB/4))

        if [ $POOL_MB -ge 1024 ]; then
            BUFFER_POOL="$((POOL_MB/1024))G"
        else
            BUFFER_POOL="${POOL_MB}M"
        fi

        if [ $LOG_MB -ge 1024 ]; then
            LOG_SIZE="$((LOG_MB/1024))G"
        else
            LOG_SIZE="${LOG_MB}M"
        fi

        MAX_CONN=$((CPU_CORES*75))
        [ $MAX_CONN -gt 600 ] && MAX_CONN=600

cat <<EOF > $MYSQL_TUNED
[mysqld]
max_connections = $MAX_CONN
wait_timeout = 120
interactive_timeout = 120

query_cache_type = 0
query_cache_size = 0

join_buffer_size = 512K
sort_buffer_size = 512K
read_buffer_size = 256K
read_rnd_buffer_size = 256K

table_open_cache = 4000
table_definition_cache = 2000

innodb_buffer_pool_size = $BUFFER_POOL
innodb_log_file_size = $LOG_SIZE
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
innodb_io_capacity = 800
innodb_io_capacity_max = 1600
EOF

        if mariadbd --verbose --help >/dev/null 2>&1; then
            systemctl restart mariadb
        fi

        sleep 4

        EXPECTED=$(mysql -Nse "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" | awk '{print $2}')

        if [ -n "$EXPECTED" ]; then
            echo "* MariaDB tuning carregado"
        else
            echo "* Falha ao validar tuning MariaDB"
        fi

    fi

    echo "* Tuning aplicado"
}

sleep 5

MYSQL_TUNED="/etc/mysql/mariadb.conf.d/99-glpi-tuned.cnf"
EXPECTED_RAW=$(grep innodb_buffer_pool_size "$MYSQL_TUNED" | awk -F= '{print $2}' | xargs)

EXPECTED_BYTES=$(numfmt --from=iec "$EXPECTED_RAW")
APPLIED=$(mysql -Nse "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" | awk '{print $2}')

if [ "$APPLIED" = "$EXPECTED_BYTES" ]; then
    echo "OK: MariaDB carregou o tuning"
else
    echo "ERRO: MariaDB NÃO carregou tuning"
fi



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
# =========================
# CAPTURA AFTER MARIADB
# =========================
echo "* Capturando variáveis MariaDB pós-tuning..."
systemctl is-active mariadb >/dev/null || systemctl start mariadb

sleep 2

MYSQL_AFTER_MAX_CONN=$(read_mysql_var max_connections)
MYSQL_AFTER_WAIT=$(read_mysql_var wait_timeout)
MYSQL_AFTER_INTER=$(read_mysql_var interactive_timeout)
MYSQL_AFTER_QCACHE=$(read_mysql_var query_cache_size)
MYSQL_AFTER_JOIN=$(read_mysql_var join_buffer_size)
MYSQL_AFTER_TABLE=$(read_mysql_var table_open_cache)
MYSQL_AFTER_POOL=$(read_mysql_var innodb_buffer_pool_size)
MYSQL_AFTER_LOG=$(read_mysql_var innodb_log_file_size)

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
echo "===== MARIADB TUNING ====="
echo "VARIÁVEL                     | ANTES        | DEPOIS"
echo "-----------------------------+--------------+--------------"
printf "%-28s | %-12s | %-12s\n" "max_connections" "$MYSQL_BEFORE_MAX_CONN" "$MYSQL_AFTER_MAX_CONN"
printf "%-28s | %-12s | %-12s\n" "wait_timeout" "$MYSQL_BEFORE_WAIT" "$MYSQL_AFTER_WAIT"
printf "%-28s | %-12s | %-12s\n" "interactive_timeout" "$MYSQL_BEFORE_INTER" "$MYSQL_AFTER_INTER"
printf "%-28s | %-12s | %-12s\n" "query_cache_size" "$MYSQL_BEFORE_QCACHE" "$MYSQL_AFTER_QCACHE"
printf "%-28s | %-12s | %-12s\n" "join_buffer_size" "$MYSQL_BEFORE_JOIN" "$MYSQL_AFTER_JOIN"
printf "%-28s | %-12s | %-12s\n" "table_open_cache" "$MYSQL_BEFORE_TABLE" "$MYSQL_AFTER_TABLE"
printf "%-28s | %-12s | %-12s\n" "innodb_buffer_pool_size" "$MYSQL_BEFORE_POOL" "$MYSQL_AFTER_POOL"
printf "%-28s | %-12s | %-12s\n" "innodb_log_file_size" "$MYSQL_BEFORE_LOG" "$MYSQL_AFTER_LOG"
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
