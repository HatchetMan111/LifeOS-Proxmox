#!/usr/bin/env bash
#
# LifeOS Container-Setup – laeuft IM LXC-Gast (via pct exec aus install/lifeos.sh)
# Aufruf: bash /root/setup-lifeos.sh <lifeos_user> <lifeos_pass> <db_pass> <api_token> <port> <upstream_ref> <app_dir>
#
# Idempotent: erneut laufen lassen = Update (git pull --ff-only, config.php bleibt).
#
set -euo pipefail

LIFEOS_USER="${1:?lifeos_user fehlt}"
LIFEOS_PASS="${2:?lifeos_passwort fehlt}"
DB_PASS="${3:?db_passwort fehlt}"
API_TOKEN="${4:?api_token fehlt}"
APP_PORT="${5:-8080}"
UPSTREAM_REF="${6:-main}"
APP_DIR="${7:-/opt/lifeos}"
UPSTREAM_REPO="https://github.com/edrisranjbar/lifeos"

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
echo "[GAST] LifeOS-Setup: user=$LIFEOS_USER port=$APP_PORT upstream=$UPSTREAM_REF dir=$APP_DIR"

# apt-Lock abwarten (Erstboot)
for _ in $(seq 1 12); do
  fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  echo "[GAST] warte auf apt-lock ..."
  sleep 10
done

echo "[GAST] Installiere Pakete (Apache, PHP, MariaDB, git, curl) ..."
apt-get update
apt-get install -y apache2 libapache2-mod-php php php-mysql php-mbstring \
  php-curl php-xml mariadb-server git curl openssl iproute2

# PHP-Version pruefen (LifeOS braucht 8.1+)
PHP_VER="$(php -r 'echo PHP_VERSION;')"
echo "[GAST] PHP $PHP_VER"
php -r 'exit(version_compare(PHP_VERSION, "8.1.0", ">=") ? 0 : 1);' \
  || { echo "[GAST] FEHLER: PHP >= 8.1 noetig, gefunden: $PHP_VER" >&2; exit 1; }
php -m | grep -qi pdo_mysql || { echo "[GAST] FEHLER: pdo_mysql fehlt" >&2; exit 1; }

# ---------------------------------------------------------------------------
# MariaDB: Dienst an, DB + User idempotent anlegen
# ---------------------------------------------------------------------------
if ! systemctl enable --now mariadb; then
  echo "[GAST] FEHLER: mariadb startet nicht – Diagnose:" >&2
  systemctl status mariadb.service --no-pager >&2 || true
  journalctl -u mariadb.service --no-pager --lines=40 >&2 || true
  tail -n 50 /var/log/mysql/error.log >&2 || true
  echo "[GAST] Hinweis: Unprivilegierter LXC braucht dafuer 'nesting=1' (Host: pct set <ID> --features nesting=1)." >&2
  exit 1
fi
echo "[GAST] Warte auf MariaDB ..."
for _ in $(seq 1 12); do
  mariadb-admin ping --silent 2>/dev/null && break
  sleep 5
done
if ! mariadb-admin ping --silent; then
  echo "[GAST] FEHLER: MariaDB antwortet nicht – Diagnose:" >&2
  systemctl status mariadb.service --no-pager >&2 || true
  journalctl -u mariadb.service --no-pager --lines=30 >&2 || true
  exit 1
fi

# Update-Modus: config.php ist fuehrend – Passwort von dort lesen, damit
# ALTER USER und App-Config niemals auseinanderlaufen (Frisch-Install: Arg).
if [[ -f "$APP_DIR/config.php" ]]; then
  EXISTING_DB_PASS="$(grep -oP "'db_password'\\s*=>\\s*'\\K[^']+" "$APP_DIR/config.php" || true)"
  if [[ -n "${EXISTING_DB_PASS:-}" ]]; then
    echo "[GAST] Update-Modus: DB-Passwort aus config.php uebernommen."
    DB_PASS="$EXISTING_DB_PASS"
  fi
fi

mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS lifeos CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'lifeos'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER 'lifeos'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON lifeos.* TO 'lifeos'@'localhost';
FLUSH PRIVILEGES;
SQL
echo "[GAST] Datenbank 'lifeos' + User 'lifeos' bereit."

# ---------------------------------------------------------------------------
# App-Code: Clone oder Update (ff-only)
# ---------------------------------------------------------------------------
if [[ ! -d "$APP_DIR/.git" ]]; then
  rm -rf "$APP_DIR"
  git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "$APP_DIR"
  echo "[GAST] Upstream geklont ($UPSTREAM_REF)."
else
  git -C "$APP_DIR" fetch --depth 1 origin "$UPSTREAM_REF" || true
  git -C "$APP_DIR" checkout -q "$UPSTREAM_REF" 2>/dev/null || true
  git -C "$APP_DIR" pull --ff-only \
    || echo "[GAST] WARN: git pull nicht ff-only moeglich – weiter mit lokalem Stand."
fi
test -f "$APP_DIR/config.example.php" || { echo "[GAST] FEHLER: $APP_DIR sieht nicht wie LifeOS aus." >&2; exit 1; }

# ---------------------------------------------------------------------------
# config.php – nur beim Erstinstall schreiben (niemals Credentials ueberschreiben)
# ---------------------------------------------------------------------------
if [[ -f "$APP_DIR/config.php" ]]; then
  echo "[GAST] config.php existiert – bleibt unveraendert (Update-Modus)."
else
  cat > "$APP_DIR/config.php" <<PHP
<?php

// Erzeugt vom LifeOS-Proxmox-Installer. Nicht committen (enthaelt echte Credentials).
return [
    'db_host' => '127.0.0.1',
    'db_port' => 3306,
    'db_name' => 'lifeos',
    'db_user' => 'lifeos',
    'db_password' => '${DB_PASS}',
    'username' => '${LIFEOS_USER}',
    'password' => '${LIFEOS_PASS}',
    'api_token' => '${API_TOKEN}',
    'api_allow_secret_notes' => false,
];
PHP
  chmod 640 "$APP_DIR/config.php"
  echo "[GAST] config.php geschrieben."
fi

chown -R www-data:www-data "$APP_DIR"
echo "[GAST] Dateirechte: www-data."

# ---------------------------------------------------------------------------
# Apache: Module, Listen-Port, vHost (DocumentRoot = public_html)
# ---------------------------------------------------------------------------
a2enmod rewrite headers >/dev/null
grep -q "^Listen ${APP_PORT}$" /etc/apache2/ports.conf \
  || echo "Listen ${APP_PORT}" >> /etc/apache2/ports.conf

cat > /etc/apache2/sites-available/lifeos.conf <<VHOST
<VirtualHost *:${APP_PORT}>
    ServerName lifeos
    DocumentRoot ${APP_DIR}/public_html

    <Directory ${APP_DIR}/public_html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/lifeos_error.log
    CustomLog \${APACHE_LOG_DIR}/lifeos_access.log combined
</VirtualHost>
VHOST
a2ensite lifeos >/dev/null
apache2ctl configtest || { echo "[GAST] FEHLER: Apache-Config fehlerhaft." >&2; exit 1; }
systemctl enable --now apache2
echo "[GAST] Apache laeuft auf Port ${APP_PORT}."

# ---------------------------------------------------------------------------
# lifeos.service: Stack-Unit (Fallback, falls nicht per pct push uebertragen)
# ---------------------------------------------------------------------------
if [[ ! -f /etc/systemd/system/lifeos.service ]]; then
  echo "[GAST] WARN: lifeos.service fehlte – schreibe Fallback-Unit."
  cat > /etc/systemd/system/lifeos.service <<'UNIT'
[Unit]
Description=LifeOS Stack (Apache + MariaDB Health-Check)
Documentation=https://github.com/edrisranjbar/lifeos
After=network-online.target apache2.service mariadb.service
Wants=network-online.target apache2.service mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lifeos-healthcheck
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
fi

cat > /usr/local/bin/lifeos-healthcheck <<'CHECK'
#!/usr/bin/env bash
# LifeOS Boot-/Health-Check (von lifeos.service aufgerufen)
set -euo pipefail
PORT_FILE="/etc/lifeos.port"
PORT="8080"
[[ -f "$PORT_FILE" ]] && PORT="$(cat "$PORT_FILE")"
mariadb-admin ping --silent || { echo "MariaDB antwortet nicht" >&2; exit 1; }
curl -fs -m 15 "http://127.0.0.1:${PORT}/login.php" >/dev/null \
  || { echo "LifeOS Web UI antwortet nicht auf :${PORT}" >&2; exit 1; }
echo "LifeOS OK (DB + http://127.0.0.1:${PORT}/login.php)"
CHECK
chmod 755 /usr/local/bin/lifeos-healthcheck
echo -n "$APP_PORT" > /etc/lifeos.port

systemctl daemon-reload
systemctl enable --now apache2 mariadb lifeos

# ---------------------------------------------------------------------------
# Verifikation im Gast
# ---------------------------------------------------------------------------
systemctl is-active apache2 >/dev/null || { echo "[GAST] FEHLER: apache2 nicht active." >&2; exit 1; }
systemctl is-active mariadb >/dev/null || { echo "[GAST] FEHLER: mariadb nicht active." >&2; exit 1; }
systemctl is-active lifeos >/dev/null || { echo "[GAST] FEHLER: lifeos nicht active." >&2; exit 1; }
curl -fs -m 15 "http://127.0.0.1:${APP_PORT}/login.php" >/dev/null \
  || { echo "[GAST] FEHLER: Web UI antwortet nicht." >&2; tail -n 50 /var/log/apache2/lifeos_error.log >&2 || true; exit 1; }

echo "[GAST] OK: apache2 + mariadb + lifeos active, Web UI antwortet auf :${APP_PORT}."
echo "[GAST] Hinweis: DB-Tabellen + Login entstehen beim ersten Seitenaufruf automatisch."
