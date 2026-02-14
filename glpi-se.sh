#!/bin/bash
# GLPI Stack Evaluation - Teste de Performance para GLPI 11 
# Objetivo avaliar ambiente antes de realizar tuning e após de fazer
# Para ser funcional realize a execução deste script antes do Tuning 
# Aplique o tuning e volte a executar este script
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Versão: 1.0
# Veja o link: https://wiki.projetoroot.com.br/index.php?title=GLPI_11
# 2026

OUTDIR="./glpi_eval"
GLPI_URL="http://localhost"
PHP_TEST="/var/www/html/php_eval.php"
WEB_REPORT="/var/www/html/glpi/public/report.html"

mkdir -p "$OUTDIR"

############################################
# Dependências
############################################
check_deps() {

DEPS=(apache2-utils sysbench gnuplot bc sysstat)

for d in "${DEPS[@]}"; do
    dpkg -s "$d" >/dev/null 2>&1 || {
        echo "Instalando $d"
        apt-get update -qq
        apt-get install -y "$d"
    }
done
}

############################################
# Endpoint PHP
############################################
prepare_php() {

cat <<EOF > $PHP_TEST
<?php
for(\$i=0;\$i<50;\$i++){
    md5(random_bytes(32));
}
usleep(10000);
echo "OK";
EOF

}

############################################
# Coleta sistema
############################################
collect_metrics() {

FILE=$1

for i in $(seq 1 30); do

    ################################
    # CPU e Memória
    ################################
    read CPU MEM <<< $(vmstat 1 2 | tail -1 | awk '{print 100-$15, 100*($3/($3+$4))}')

    ################################
    # Disco busy %
    ################################
    DISK=$(iostat -dx 1 2 | awk '/sda / {print $NF}' | tail -1)

    ################################
    # fallback se disco não detectado
    ################################
    [ -z "$DISK" ] && DISK=0

    echo "$CPU $MEM $DISK" >> "$FILE"

done
}

############################################
# Apache test
############################################
test_apache() {
ab -n 20000 -c 80 http://localhost/ 2>/dev/null \
| awk '/Requests per second/ {print $4}'
}

############################################
# PHP test
############################################
test_php() {
ab -n 15000 -c 60 http://localhost/php_eval.php 2>/dev/null \
| awk '/Requests per second/ {print $4}'
}

############################################
# MariaDB test
############################################
############################################
# MariaDB test (real)
############################################
test_db() {

DB="sbtest"
THREADS=16
TIME=60

# cria database (silencioso)
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS $DB;" 2>/dev/null

# prepara dataset
sysbench oltp_read_only \
 --mysql-db=$DB \
 --mysql-user=root \
 --threads=$THREADS \
 --tables=4 \
 --table-size=10000 \
 prepare >/dev/null 2>&1

# executa benchmark
QPS=$(sysbench oltp_read_only \
 --mysql-db=$DB \
 --mysql-user=root \
 --threads=$THREADS \
 --time=$TIME \
 run 2>/dev/null | awk '/queries:/ {print $2}')

# limpeza
sysbench oltp_read_only \
 --mysql-db=$DB \
 --mysql-user=root \
 cleanup >/dev/null 2>&1

mysql -uroot -e "DROP DATABASE $DB;" 2>/dev/null

# fallback caso algo falhe
[ -z "$QPS" ] && QPS=0

echo "$QPS"
}

############################################
# GLPI autenticado
############################################
test_glpi() {

COOKIE=$(mktemp)

HTML=$(curl -s \
  -c "$COOKIE" \
  -b "$COOKIE" \
  -A "Mozilla/5.0" \
  "${GLPI_URL}/index.php")

TOKEN=$(echo "$HTML" | sed -n 's/.*_glpi_csrf_token" value="\([^"]*\)".*/\1/p')

[ -z "$TOKEN" ] && rm -f "$COOKIE" && echo "0" && return

## ATENCAO ###
### Alterar abaixo login_name=glpi e login_password=glpi para usuário e senha corretos, caso não seja padrão da instalação. ###### 
curl -s -L \
  -c "$COOKIE" \
  -b "$COOKIE" \
  -A "Mozilla/5.0" \
  -e "${GLPI_URL}/index.php" \
  -d "_glpi_csrf_token=$TOKEN" \
  -d "login_name=glpi" \
  -d "login_password=glpi" \
  -d "auth=local" \
  "${GLPI_URL}/front/login.php" >/dev/null

HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE" \
  "${GLPI_URL}/front/central.php")

[ "$HTTP" != "200" ] && rm -f "$COOKIE" && echo "0" && return

REQ=300
CONC=15

START=$(date +%s%N)

for ((i=0;i<REQ;i++)); do
    curl -s -b "$COOKIE" "${GLPI_URL}/front/central.php" >/dev/null &
    (( i % CONC == 0 )) && wait
done
wait

END=$(date +%s%N)
rm -f "$COOKIE"

ELAPSED_NS=$((END-START))
[ "$ELAPSED_NS" -le 0 ] && echo "0" && return

ELAPSED=$(echo "scale=4;$ELAPSED_NS/1000000000" | bc)
RPS=$(echo "scale=2;$REQ/$ELAPSED" | bc)

echo "$RPS"
}

############################################
# Execução
############################################
run_case() {

MODE=$1

check_deps
prepare_php

echo "Executando testes $MODE"

APACHE=$(test_apache)
PHP=$(test_php)
DB=$(test_db)
GLPI=$(test_glpi)

collect_metrics "$OUTDIR/${MODE}_metrics.dat"

echo "$APACHE $PHP $DB $GLPI" > "$OUTDIR/${MODE}_scores.dat"
}

############################################
# Relatório
############################################
make_report() {

read A1 P1 D1 G1 < "$OUTDIR/baseline_scores.dat"
read A2 P2 D2 G2 < "$OUTDIR/tuned_scores.dat"

gain() {
if [ -z "$1" ] || [ -z "$2" ] || [ "$1" = "0" ]; then
    echo "0"
    return
fi
echo "scale=2; (($2-$1)/$1)*100" | bc
}

GA=$(gain $A1 $A2)
GP=$(gain $P1 $P2)
GD=$(gain $D1 $D2)
GG=$(gain $G1 $G2)

############################################
# Função para plotagem de PNG
############################################
plot_png() {
    TITLE="$1"
    COL="$2"
    FILE="$OUTDIR/${TITLE// /_}.png"  # substitui espaços por _
    
    BASE="$OUTDIR/baseline_metrics.dat"
    TUNED="$OUTDIR/tuned_metrics.dat"

    gnuplot <<EOF
set terminal png size 900,420
set output "$FILE"
set title "$TITLE"
set xlabel "Sample"
set ylabel "%"
set grid
plot "$BASE" using $COL title "Baseline" with lines lw 2, \
     "$TUNED" using $COL title "Tuned" with lines lw 2
EOF
}

# Gerar gráficos
plot_png "CPU Usage" 1
plot_png "Memory Usage" 2
plot_png "Disk Busy" 3

AGORA=$(date '+%d/%m/%Y %H:%M:%S')

cat <<EOF > "$OUTDIR/report.html"
<html>
<body style="background:#111;color:#eee;font-family:monospace">

<h1>GLPI Stack Evaluation</h1>

<h3>Gerado em: $AGORA</h3>

<h2>Resumo visual da melhoria</h2>

<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse">
<tr><th>Metrica</th><th>Baseline</th><th>Tuned</th><th>Ganho</th></tr>
<tr><td>Apache RPS</td><td>$A1</td><td>$A2</td><td>${GA}%</td></tr>
<tr><td>PHP RPS</td><td>$P1</td><td>$P2</td><td>${GP}%</td></tr>
<tr><td>MariaDB QPS</td><td>$D1</td><td>$D2</td><td>${GD}%</td></tr>
<tr><td>GLPI Real RPS</td><td>$G1</td><td>$G2</td><td>${GG}%</td></tr>
</table>

<hr>

<h2>Detalhamento</h2>

<h3>Apache RPS</h3>
Baseline $A1<br>
Tuned $A2<br>
Ganho ${GA} %

<h3>PHP RPS</h3>
Baseline $P1<br>
Tuned $P2<br>
Ganho ${GP} %

<h3>MariaDB QPS</h3>
Baseline $D1<br>
Tuned $D2<br>
Ganho ${GD} %

<h3>GLPI Real RPS</h3>
Baseline $G1<br>
Tuned $G2<br>
Ganho ${GG} %

<h2>Detalhamento Graficos</h2>
<h3>CPU Usage</h3>
<img src="CPU_Usage.png"><br>
<h3>Memory Usage</h3>
<img src="Memory_Usage.png"><br>
<h3>Disk Busy</h3>
<img src="Disk_Busy.png"><br>

</body>
</html>
EOF

cp "$OUTDIR/report.html" "$WEB_REPORT"
cp "$OUTDIR"/*.png /var/www/html/glpi/public/
chmod 644 "$WEB_REPORT"

echo
echo "Relatório pronto:"
echo "$OUTDIR/report.html"
echo
echo "Acesse:"
echo "http://glpi/report.html"
echo "ou"
echo "http://IP-do-glpi/report.html"
}

############################################
# Entrada
############################################
case "$1" in

baseline)
run_case baseline
echo
echo "Execute o tuning e depois rode:"
echo "./glpi-se.sh tuned"
;;

tuned)
run_case tuned
echo
echo "Agora gere o relatório:"
echo "./glpi-se.sh report"
;;

report)
make_report
;;

*)
echo
echo "Execute primeiro:"
echo "./glpi-se.sh baseline"
;;
esac
