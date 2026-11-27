#!/usr/bin/env bash
# Instalace Zabbix 8.0 LTS (server + web + Agent 2) s MariaDB na Debianu 13.
# Spouští ho Vagrant jako root (config.vm.provision "shell").
# Skript jde spustit opakovaně – existující databázi ani hesla nepřepíše.

set -Eeuo pipefail
trap 'echo "CHYBA: řádek $LINENO, příkaz: $BASH_COMMAND" >&2' ERR

ZBX_VERSION="8.0"
ZBX_HOSTNAME="${ZBX_HOSTNAME:-mejp-debian13}"
ZBX_SERVER_NAME="Lada Rozenský · SPOŠ DK · Zabbix ${ZBX_VERSION}"
DB_NAME="zabbix"
DB_USER="zabbix"
SECRET_DIR="/root/zabbix-secrets"       # hesla jen ve VM, čitelná jen pro root
TIMEZONE="Europe/Prague"

export DEBIAN_FRONTEND=noninteractive
log() { printf '\n==> %s\n' "$*"; }
die() { echo "CHYBA: $*" >&2; exit 1; }
apt_install() { apt-get install -y -q --no-install-recommends "$@"; }

[[ $EUID -eq 0 ]] || die "skript musí běžet jako root"
grep -q '^VERSION_ID="13"' /etc/os-release || die "očekávám Debian 13 (trixie)"

# ---------------------------------------------------------------------------
log "Základní nastavení systému (časová zóna, locale)"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
apt-get update -q
apt_install ca-certificates wget curl jq gnupg locales openssl
# Web Zabbixu potřebuje en_US.UTF-8, čeština se hodí pro překlad rozhraní
sed -i -E 's/^#\s*(en_US\.UTF-8 UTF-8)/\1/; s/^#\s*(cs_CZ\.UTF-8 UTF-8)/\1/' /etc/locale.gen
locale-gen >/dev/null

# ---------------------------------------------------------------------------
log "Oficiální repozitář Zabbix ${ZBX_VERSION} pro Debian 13"
if ! grep -rqs "zabbix/${ZBX_VERSION}" /etc/apt/sources.list.d/; then
    tmp=$(mktemp -d)
    # Název balíčku podle aktuální dokumentace Zabbix 8.0; druhá URL je záloha
    # pro starší pojmenování "latest_8.0+debian13".
    base="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/debian/pool/main/z/zabbix-release"
    wget -q -O "$tmp/zabbix-release.deb" "$base/zabbix-release_latest+debian13_all.deb" \
      || wget -q -O "$tmp/zabbix-release.deb" "$base/zabbix-release_latest_${ZBX_VERSION}+debian13_all.deb" \
      || die "nepodařilo se stáhnout zabbix-release balíček"
    dpkg -i "$tmp/zabbix-release.deb"
    rm -rf "$tmp"
fi
apt-get update -q

# ---------------------------------------------------------------------------
log "Instalace MariaDB, Zabbix serveru, webu (Apache) a Agenta 2"
apt_install mariadb-server mariadb-client \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent2 zabbix-get

# Kontrola, že balíčky jsou opravdu z repa Zabbix a ve verzi 8.0
srv_ver=$(dpkg-query -W -f='${Version}' zabbix-server-mysql)
[[ $srv_ver == *"${ZBX_VERSION}."* ]] || die "zabbix-server-mysql má verzi $srv_ver, čekám ${ZBX_VERSION}.x"
echo "zabbix-server-mysql $srv_ver"

systemctl enable --now mariadb

# ---------------------------------------------------------------------------
log "Hesla (generují se ve VM, do Gitu se nikdy nedostanou)"
install -d -m 700 "$SECRET_DIR"
if [[ ! -s $SECRET_DIR/db-password ]]; then
    # Heslo lze předat i zvenku: ZBX_DB_PASSWORD=... vagrant up
    if [[ -n ${ZBX_DB_PASSWORD:-} ]]; then
        [[ $ZBX_DB_PASSWORD =~ ^[A-Za-z0-9._-]{12,}$ ]] \
          || die "ZBX_DB_PASSWORD: aspoň 12 znaků, jen písmena, číslice a . _ -"
        printf '%s\n' "$ZBX_DB_PASSWORD" > "$SECRET_DIR/db-password"
    else
        openssl rand -hex 24 > "$SECRET_DIR/db-password"
    fi
    chmod 600 "$SECRET_DIR/db-password"
fi
DB_PASSWORD=$(<"$SECRET_DIR/db-password")

# ---------------------------------------------------------------------------
log "Databáze '$DB_NAME' (utf8mb4) a uživatel s právy jen k ní"
# root se do MariaDB přihlašuje přes unix_socket – žádné heslo není potřeba
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Schéma importujeme právě jednou – poznáme to podle tabulky dbversion
has_schema=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables
                          WHERE table_schema='${DB_NAME}' AND table_name='dbversion'")
if [[ $has_schema == "0" ]]; then
    schema=""
    for f in /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
             /usr/share/zabbix-sql-scripts/mysql/server.sql.gz; do
        [[ -f $f ]] && { schema=$f; break; }
    done
    [[ -n $schema ]] || die "nenašel jsem server.sql.gz ze zabbix-sql-scripts"
    log "První import schématu z $schema (chvíli to trvá)"
    mysql -e "SET GLOBAL log_bin_trust_function_creators = 1;"
    zcat "$schema" | mysql --default-character-set=utf8mb4 "$DB_NAME"
    mysql -e "SET GLOBAL log_bin_trust_function_creators = 0;"
else
    echo "Schéma už existuje – import přeskočen."
fi

# ---------------------------------------------------------------------------
log "Konfigurace Zabbix serveru"
SERVER_CONF=/etc/zabbix/zabbix_server.conf
[[ -f $SERVER_CONF ]] || die "chybí $SERVER_CONF"
[[ -f $SERVER_CONF.orig ]] || cp -p "$SERVER_CONF" "$SERVER_CONF.orig"
# Odstraníme případné staré hodnoty a přidáme vlastní na konec souboru
sed -i -E '/^\s*(DBHost|DBName|DBUser|DBPassword)=/d' "$SERVER_CONF"
cat >> "$SERVER_CONF" <<EOF
DBHost=localhost
DBName=${DB_NAME}
DBUser=${DB_USER}
DBPassword=${DB_PASSWORD}
EOF
chown root:zabbix "$SERVER_CONF"
chmod 640 "$SERVER_CONF"

# ---------------------------------------------------------------------------
log "Konfigurace Zabbix Agenta 2 (monitoruje tento server)"
AGENT_CONF=/etc/zabbix/zabbix_agent2.conf
[[ -f $AGENT_CONF ]] || die "chybí $AGENT_CONF"
[[ -f $AGENT_CONF.orig ]] || cp -p "$AGENT_CONF" "$AGENT_CONF.orig"
sed -i -E '/^\s*(Server|ServerActive|Hostname)=/d' "$AGENT_CONF"
cat >> "$AGENT_CONF" <<EOF
Server=127.0.0.1
ServerActive=127.0.0.1
Hostname=${ZBX_HOSTNAME}
EOF

# ---------------------------------------------------------------------------
log "Webové rozhraní: zabbix.conf.php (bez PHP wizardu)"
WEB_CONF=/etc/zabbix/web/zabbix.conf.php
install -d -m 750 -o www-data -g www-data /etc/zabbix/web
cat > "$WEB_CONF" <<EOF
<?php
// Vygenerováno skriptem scripts/install-zabbix.sh – ručně neupravovat.
\$DB['TYPE']        = 'MYSQL';
\$DB['SERVER']      = 'localhost';
\$DB['PORT']        = '0';
\$DB['DATABASE']    = '${DB_NAME}';
\$DB['USER']        = '${DB_USER}';
\$DB['PASSWORD']    = '${DB_PASSWORD}';
\$DB['SCHEMA']      = '';
\$DB['ENCRYPTION']  = false;
\$DB['KEY_FILE']    = '';
\$DB['CERT_FILE']   = '';
\$DB['CA_FILE']     = '';
\$DB['VERIFY_HOST'] = false;
\$DB['CIPHER_LIST'] = '';
\$DB['VAULT']       = '';
\$DB['VAULT_URL']   = '';
\$DB['VAULT_PREFIX'] = '';
\$DB['VAULT_DB_PATH'] = '';
\$DB['VAULT_TOKEN'] = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE'] = '';
\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '${ZBX_SERVER_NAME}';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF
chown www-data:www-data "$WEB_CONF"
chmod 600 "$WEB_CONF"

# PHP: časová zóna a limity podle požadavků Zabbixu
for d in /etc/php/*/apache2/conf.d; do
    [[ -d $d ]] || continue
    cat > "$d/99-zabbix.ini" <<EOF
date.timezone = ${TIMEZONE}
max_execution_time = 300
max_input_time = 300
memory_limit = 256M
post_max_size = 16M
upload_max_filesize = 2M
EOF
done

# Přesměrování http://127.0.0.1:8080/ -> /zabbix/
cat > /etc/apache2/conf-available/zabbix-root-redirect.conf <<'EOF'
RedirectMatch 302 ^/$ /zabbix/
EOF
a2enconf -q zabbix-root-redirect
apache2ctl configtest

# ---------------------------------------------------------------------------
log "Spuštění a povolení služeb"
SERVICES=(mariadb zabbix-server zabbix-agent2 apache2)
systemctl enable "${SERVICES[@]}"
systemctl restart zabbix-server zabbix-agent2 apache2

sleep 3
for s in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$s" || { systemctl status "$s" --no-pager || true; die "služba $s neběží"; }
    printf '  %-15s %s\n' "$s" "$(systemctl is-active "$s")"
done

log "Instalace hotová – web: http://127.0.0.1:8080/zabbix/"
