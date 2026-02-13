#!/bin/bash
# Instalador automático do GLPI no Debian 13
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Versão: 1.1
# Veja o link: https://wiki.projetoroot.com.br/index.php?title=GLPI_11
# 2026

PATH=$PATH:/sbin:/usr/sbin

set -e

echo "=== Instalador GLPI para Debian 13 ==="
echo ""
echo "Este script instala automaticamente o GLPI, Apache, PHP e MariaDB."
echo "Ele também cria o banco de dados, usuário e ajusta permissões e configurações básicas."
read -p "Deseja continuar? (S/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Abortando..."
    exit 0
fi

read -p "Digite o domínio ou IP do servidor (ex: glpi.seudominio.com.br): " DOMAIN
read -p "Digite uma senha segura para o banco de dados GLPI: " DB_PASS

echo ""
echo "=== Atualizando repositórios e instalando pacotes necessários ==="
apt update -y
apt install -y sudo curl wget tar unzip nano apache2 mariadb-server php php-{cli,ldap,xmlrpc,soap,curl,snmp,zip,apcu,gd,mbstring,mysql,xml,bz2,intl,bcmath}

echo ""
echo "=== Verificando banco de dados existente ==="
if mysql -u root -e "USE glpidb;" 2>/dev/null; then
    echo "Banco de dados glpidb já existe. Removendo..."
    mysql -u root <<EOF
DROP DATABASE glpidb;
DROP USER IF EXISTS 'glpi'@'localhost';
FLUSH PRIVILEGES;
EOF
    echo "Banco e usuário removidos com sucesso."
fi

echo ""
echo "=== Criando novo banco de dados e usuário GLPI ==="
mysql -u root <<EOF
CREATE DATABASE glpidb CHARACTER SET utf8;
CREATE USER 'glpi'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON glpidb.* TO 'glpi'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

echo "Banco de dados criado com sucesso."
echo ""

echo "=== Baixando a versão mais recente do GLPI ==="
LATEST=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep "tag_name" | cut -d '"' -f4)
wget "https://github.com/glpi-project/glpi/releases/download/${LATEST}/glpi-${LATEST}.tgz"
tar -xzf "glpi-${LATEST}.tgz"
rm "glpi-${LATEST}.tgz"

echo "=== Movendo GLPI para o diretório do Apache ==="
rm -rf /var/www/html/glpi
mv glpi /var/www/html/
chown -R www-data:www-data /var/www/html/glpi
chmod -R 775 /var/www/html/glpi

echo ""
echo "=== Criando configuração do Apache ==="
cat > /etc/apache2/conf-available/glpi.conf <<EOL
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html/glpi/public

    <Directory /var/www/html/glpi/public>
        AllowOverride All
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
</VirtualHost>
EOL

echo ""
echo "=== Habilitando módulos e configuração do Apache ==="
a2enmod rewrite
a2enconf glpi.conf
systemctl restart apache2

echo ""
echo "=== Ajustando configurações do PHP ==="
PHP_VER=$(php -v | head -n1 | awk '{print $2}' | cut -d'.' -f1,2)
PHP_INI="/etc/php/${PHP_VER}/apache2/php.ini"

sed -i 's/^memory_limit = .*/memory_limit = 256M/' $PHP_INI
sed -i 's/^post_max_size = .*/post_max_size = 256M/' $PHP_INI
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 256M/' $PHP_INI

# Ativa segurança recomendada (para utilizar https remova os comentários abaixo)
#grep -q '^session.cookie_httponly' $PHP_INI || echo "session.cookie_httponly = On" >> $PHP_INI
#grep -q '^session.cookie_secure' $PHP_INI || echo "session.cookie_secure = On" >> $PHP_INI

echo "=== Recarregando o Apache ==="
systemctl reload apache2

# Criar config_db.php para GLPI
echo "Criando arquivo config_db.php"
CONFIG_FILE="/var/www/html/glpi/config/config_db.php"

if [ ! -f "$CONFIG_FILE" ]; then
cat > "$CONFIG_FILE" <<EOL
<?php
class DB extends DBmysql {
  public \$dbhost = 'localhost';
  public \$dbuser = 'glpi';
  public \$dbpassword = '${DB_PASS}';
  public \$dbdefault = 'glpidb';
}
?>
EOL

chown www-data:www-data "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"

echo "Arquivo config_db.php criado com sucesso."
fi

# Instalar o Banco no GLPI por Console
echo "=== Instalar o Banco no GLPI por Console ==="
sudo -u www-data php /var/www/html/glpi/bin/console db:install \
  --db-host=localhost \
  --db-name=glpidb \
  --db-user=glpi \
  --db-password="${DB_PASS}" \
  --default-language=pt_BR \
  --reconfigure \
-n

# Ajuste de TimeZone
echo "=== Ativando suporte a Timezone no MariaDB e GLPI ==="
sudo -u www-data php /var/www/html/glpi/bin/console database:update -n
# Definir timezone global no MariaDB
sudo mariadb -e "SET GLOBAL time_zone = 'SYSTEM';"
# Carregar informações de timezone no MariaDB
sudo mariadb-tzinfo-to-sql /usr/share/zoneinfo | sudo mariadb mysql
# Ativar suporte a timezone no GLPI
sudo -u www-data php /var/www/html/glpi/bin/console database:enable_timezones
sudo -u www-data php /var/www/html/glpi/bin/console cache:configure --use-default

echo "=== Reiniciando o Apache ==="
systemctl restart apache2

echo ""
read -p "Deseja realizar tuning e hardening para melhorar desempenho e segurança do GLPI? (S/N): " TUNING

if [[ "$TUNING" =~ ^[Ss]$ ]]; then
    echo "=== Baixando e executando o script de tuning ==="
    wget -O /tmp/tuning.sh https://raw.githubusercontent.com/projetoroot/glpi/refs/heads/main/tuning.sh
    chmod +x /tmp/tuning.sh
    /tmp/tuning.sh
    echo ""
    echo "=== Tuning e hardening concluídos ==="
fi

echo "=== Instalação concluída ==="
echo ""
echo "Acesse o GLPI pelo navegador em: http://${DOMAIN} ou http://<IP_DO_SERVIDOR>/glpi"
echo "Banco de dados: glpidb"
echo "Usuário: glpi"
echo "Senha: ${DB_PASS}"
echo "Diretório: /var/www/html/glpi"
echo "Arquivo de conf: /etc/apache2/conf-available/glpi.conf"
echo ""
echo "Instalação concluida com sucesso, utilizar usuário e senha padrão do GLPI para acessar."
echo "============================"
echo ""
