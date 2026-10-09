#!/usr/bin/env bash
#
# LifeOS Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      LifeOS – Self-hosted Life OS (Habits, Goals, Kanban, Finance, Focus + MCP)
# Upstream: https://github.com/edrisranjbar/lifeos (MIT, kein Teil dieses Repos)
# Stack:    Apache + PHP 8.2 + MariaDB 10.11 nativ im LXC (kein Build-Step, kein Docker)
# Laeuft:   vollstaendig lokal in einem LXC-Container, keine Cloud noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Gast!)
# Modus:    Zweistufer – dieses Script (Host: pct create/push/exec) +
#           install/setup.sh (Gast: Pakete, Clone, config.php, vHost, systemd)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LifeOS-Proxmox/main/install/lifeos.sh)"
#   CTID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LifeOS-Proxmox/main/install/lifeos.sh)"
#   bash lifeos.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="lifeos"                                    # CT-Name
APP_PORT="8080"                                 # Web UI (Apache Listen + vHost)
UPSTREAM_REPO="https://github.com/edrisranjbar/lifeos"
UPSTREAM_REF="main"                             # Branch/Tag von Upstream
INSTALLER_REPO="https://github.com/HatchetMan111/LifeOS-Proxmox"
INSTALLER_REF="main"                            # Branch dieses Installer-Repos
SETUP_URL="https://raw.githubusercontent.com/HatchetMan111/LifeOS-Proxmox/main/install/setup.sh"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/LifeOS-Proxmox/main/systemd/lifeos.service"

DEFAULT_HOSTNAME="lifeos"
DEFAULT_CORES="2"                               # vCPU
DEFAULT_RAM="2048"                              # RAM in MB
DEFAULT_DISK="8"                                # Disk in GB
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE=""                              # leer = auto (bevorzugt local-lvm)
DEFAULT_TEMPLATE_STORAGE="local"                # Storage fuer Container-Templates (vztmpl)
DEBIAN_TEMPLATE="debian-12-standard"            # pveam-Template-Präfix (PHP 8.2, MariaDB 10.11)
DEFAULT_LIFEOS_USER="admin"

APP_DIR="/opt/lifeos"
GUEST_UNITS="apache2 mariadb lifeos"

# Umgebungs-Overrides: CTID=150 CORES=2 RAM=2048 DISK=8 LIFEOS_USER=me ./lifeos.sh
CTID_ARG="${CTID:-}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
HOSTNAME_ARG="${CT_HOSTNAME:-${HOSTNAME_ARG:-}}"
LIFEOS_USER_ARG="${LIFEOS_USER:-}"
LIFEOS_PASSWORD_ARG="${LIFEOS_PASSWORD:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  # shellcheck disable=SC2034 # Farbpalette (BOLD/CYAN fuer spaetere Meldungen reserviert)
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Stapel, Log)
# shellcheck disable=SC2154 # ec wird im Trap zugewiesen, nicht ausserhalb
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Aufrufstapel: ${FUNCNAME[*]:-main}"; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer (nativ: Apache + PHP + MariaDB, upstream-nah)

Usage:
  bash lifeos.sh [OPTIONEN]
  CTID=150 bash lifeos.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/main/install/lifeos.sh)"

Optionen:
  --ctid ID            CT-ID (Default: interaktiv, Vorschlag = naechste freie ID; existiert sie -> Update-Modus)
  --hostname NAME      CT-Hostname (Default: ${DEFAULT_HOSTNAME})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       Disk-Storage (Default: auto, bevorzugt local-lvm)
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --ref REF            Installer-Branch (Default: ${INSTALLER_REF})
  --version VER        Upstream-Branch/Tag (Default: ${UPSTREAM_REF})
  --user NAME          LifeOS-Login (Default: interaktiv, Vorschlag ${DEFAULT_LIFEOS_USER})
  --password PW        LifeOS-Passwort (Default: interaktiv, Vorschlag = generiert)
  --non-interactive    keine Prompts (Defaults + Env-Vars)
  --password-root PW   Root-Passwort im CT (Default: zufaellig, wird einmalig angezeigt)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CTID_ARG" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
HOSTNAME_VAL="$HOSTNAME_ARG" STORAGE_ARG="$DEFAULT_STORAGE" BRIDGE="$DEFAULT_BRIDGE"
REF="$INSTALLER_REF" VERSION="$UPSTREAM_REF" ROOTPW=""
LIFEOS_USER="$LIFEOS_USER_ARG" LIFEOS_PASSWORD="$LIFEOS_PASSWORD_ARG"
CTID_EXPLICIT=0
[[ -n "$CTID_ARG" ]] && CTID_EXPLICIT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; CTID_EXPLICIT=1; shift 2;;
    --hostname) HOSTNAME_VAL="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --ref) REF="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --user) LIFEOS_USER="$2"; shift 2;;
    --password) LIFEOS_PASSWORD="$2"; shift 2;;
    --password-root) ROOTPW="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE="1"; shift;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    _) shift;;  # Platzhalter fuer Einzeiler-Trick: ...)" _ --flags
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

rand_hex() { openssl rand -hex "${1:-16}" 2>/dev/null || head -c "$(( ${1:-16} * 2 ))" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ask() {
  # ask VAR "Prompt" "Default" – interaktiv, sonst Default; Ergebnis in $REPLY_ASK
  local prompt="$1" def="$2" secret="${3:-0}" ans
  if [[ "$NON_INTERACTIVE" == "1" ]] || [[ ! -t 0 ]]; then
    REPLY_ASK="$def"
    return 0
  fi
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$prompt [Enter = generiertes Passwort uebernehmen, bitte ohne Hochkomma]: " ans || true
    echo ""
  else
    read -r -p "$prompt [$def]: " ans || true
  fi
  REPLY_ASK="${ans:-$def}"
}

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }
command -v pvesm >/dev/null || { msg_error "pvesm nicht gefunden."; exit 1; }
command -v openssl >/dev/null || msg_warn "openssl fehlt – Fallback /dev/urandom fuer Passwoerter."

NEXT_ID="$(pvesh get /cluster/nextid)"
if [[ -z "$CTID" ]]; then
  ask "CT-ID" "$NEXT_ID"
  CTID="$REPLY_ASK"
fi
if pct status "$CTID" >/dev/null 2>&1; then
  if [[ "$CTID_EXPLICIT" == "1" ]]; then
    msg_info "CT $CTID existiert – Update-Modus (idempotent)."
  else
    msg_warn "CTID $CTID belegt – weiche auf freie ID $NEXT_ID aus."
    CTID="$NEXT_ID"
  fi
else
  msg_info "CT-ID: $CTID (naechste freie waere $NEXT_ID)"
fi

if [[ -z "$HOSTNAME_VAL" ]]; then
  ask "CT-Hostname" "$DEFAULT_HOSTNAME"
  HOSTNAME_VAL="$REPLY_ASK"
fi
ask "vCPU" "$CORES"; CORES="$REPLY_ASK"
ask "RAM (MB)" "$RAM"; RAM="$REPLY_ASK"
ask "Disk (GB)" "$DISK"; DISK="$REPLY_ASK"

if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status 2>/dev/null | grep -q '^local-lvm[[:space:]]'; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein CT-Disk-Storage gefunden."; exit 1; }
ask "Bridge" "$BRIDGE"; BRIDGE="$REPLY_ASK"
ask "Disk-Storage" "$STORAGE_ARG"; STORAGE_ARG="$REPLY_ASK"
msg_info "Storage: $STORAGE_ARG | Bridge: $BRIDGE | CT-Name: $HOSTNAME_VAL | Upstream: $VERSION"

if [[ -z "$LIFEOS_USER" ]]; then
  ask "LifeOS-Login (Username)" "$DEFAULT_LIFEOS_USER"
  LIFEOS_USER="$REPLY_ASK"
fi
GEN_PASS="$(rand_hex 12)"
if [[ -z "$LIFEOS_PASSWORD" ]]; then
  ask "LifeOS-Passwort" "$GEN_PASS" 1
  LIFEOS_PASSWORD="$REPLY_ASK"
fi
DB_PASS="$(rand_hex 12)"
API_TOKEN="$(rand_hex 32)"
msg_info "DB-Passwort + API-Token werden generiert (liegen spaeter in /root/lifeos.credentials im CT)."

[[ "$RAM" -ge 1024 ]] || msg_warn "Unter 1024 MB wird MariaDB+Apache eng (gewaehlt: $RAM)."
[[ "$DISK" -ge 4 ]] || msg_warn "Unter 4 GB wird es eng (gewaehlt: $DISK)."

# ---------------------------------------------------------------------------
# 2. Template sicherstellen
# ---------------------------------------------------------------------------
TEMPLATE_FILE="$(pveam list "$DEFAULT_TEMPLATE_STORAGE" 2>/dev/null | grep -oP "${DEBIAN_TEMPLATE}[^\s]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE_FILE:-}" ]]; then
  msg_info "Aktualisiere Template-Liste und lade ${DEBIAN_TEMPLATE} ..."
  pveam update
  CANDIDATE="$(pveam available 2>/dev/null | grep -oP "^(?:${DEFAULT_TEMPLATE_STORAGE}:vztmpl/)?\\K${DEBIAN_TEMPLATE}[^\\s]*\\.tar\\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
  [[ -n "${CANDIDATE:-}" ]] || { msg_error "Kein ${DEBIAN_TEMPLATE}-Template via pveam verfuegbar."; exit 1; }
  pveam download "$DEFAULT_TEMPLATE_STORAGE" "$CANDIDATE"
  TEMPLATE_FILE="$CANDIDATE"
  msg_ok "Template geladen: $TEMPLATE_FILE"
else
  msg_ok "Template vorhanden: $TEMPLATE_FILE"
fi
OSTEMPLATE="${DEFAULT_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, nur Gast provisionieren)
# ---------------------------------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "CT $CTID existiert – ueberspringe Erstellung (Update-Modus)."
  msg_info "Heile CT-Config (idempotent): onboot=1, nesting=1 (MariaDB braucht Mount-Namespace), Hostname=$HOSTNAME_VAL ..."
  pct set "$CTID" --onboot 1 --features nesting=1 --hostname "$HOSTNAME_VAL" \
    || msg_warn "pct set schlug fehl – weiter mit bestehender CT-Config."
else
  [[ -n "$ROOTPW" ]] || ROOTPW="$(rand_hex 12)"
  msg_info "Erstelle CT $CTID ($HOSTNAME_VAL): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CTID" "$OSTEMPLATE" \
    --hostname "$HOSTNAME_VAL" \
    --password "$ROOTPW" \
    --cores "$CORES" --memory "$RAM" --swap 512 \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --onboot 1 \
    --features "nesting=1" \
    --unprivileged 1 \
    --nameserver "1.1.1.1 8.8.8.8"
  msg_ok "CT $CTID erstellt (onboot=1, nesting=1, unprivileged)."
  pct start "$CTID" \
    || { msg_error "pct start scheiterte (oft RAM/Storage voll). free -m und pvesm status pruefen."; exit 1; }
  msg_ok "CT $CTID laeuft."
fi

pct start "$CTID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Gast-IP warten
# ---------------------------------------------------------------------------
msg_info "Warte auf Gast-IP (max. 2 Min, DHCP) ..."
CT_IP=""
for i in $(seq 1 12); do
  sleep 10
  CT_IP="$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)"
  if [[ -n "${CT_IP:-}" ]]; then
    msg_ok "Gast-IP: $CT_IP"
    break
  fi
  [[ $((i % 3)) == 0 ]] && msg_info "noch keine IP nach $((i * 10))s ..."
done
if [[ -z "${CT_IP:-}" ]]; then
  msg_error "Keine Gast-IP nach 2 Min. Diagnose-Dump:"
  msg_error "--- pct status ---"; pct status "$CTID" || true
  msg_error "--- pct config ---"; pct config "$CTID" || true
  msg_error "Naechste Schritte:"
  msg_error " 1) pct enter $CTID -> ip -4 addr; systemctl status networking"
  msg_error " 2) DHCP auf $BRIDGE pruefen; ggf. statische IP: pct set $CTID --net0 name=eth0,bridge=$BRIDGE,ip=192.168.1.50/24,gw=192.168.1.1"
  msg_error " 3) Update-Modus: bash lifeos.sh --ctid $CTID (CT bleibt bestehen, idempotent)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Setup-Script + systemd-Unit aus Installer-Repo holen und pushen
# ---------------------------------------------------------------------------
SETUP_URL="${SETUP_URL/main\//${REF}/}"
SERVICE_URL="${SERVICE_URL/main\//${REF}/}"
TMP_SETUP="/tmp/lifeos-setup-${CTID}.sh"
TMP_SERVICE="/tmp/lifeos-${CTID}.service"
msg_info "Lade Setup-Script ($REF) ..."
wget -qO "$TMP_SETUP" "$SETUP_URL" \
  || { msg_error "Setup-Script nicht ladbar: $SETUP_URL"; exit 1; }
bash -n "$TMP_SETUP" || { msg_error "Syntaxfehler in setup.sh (bash -n)."; exit 1; }
pct push "$CTID" "$TMP_SETUP" /root/setup-lifeos.sh
msg_ok "setup.sh in CT uebertragen."

if wget -qO "$TMP_SERVICE" "$SERVICE_URL"; then
  msg_ok "lifeos.service aus Repo uebernommen."
  pct push "$CTID" "$TMP_SERVICE" /etc/systemd/system/lifeos.service
else
  msg_warn "Service-URL nicht erreichbar – setup.sh schreibt Fallback-Unit."
fi

# ---------------------------------------------------------------------------
# 6. LifeOS im Gast (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Provisioniere LifeOS im Gast (Apache + PHP + MariaDB + Upstream $VERSION) ..."
pct exec "$CTID" -- bash /root/setup-lifeos.sh \
  "$LIFEOS_USER" "$LIFEOS_PASSWORD" "$DB_PASS" "$API_TOKEN" "$APP_PORT" "$VERSION" "$APP_DIR"

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now mariadb apache2 lifeos

# ---------------------------------------------------------------------------
# 7. Verifikation: Services + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
for unit in $GUEST_UNITS; do
  pct exec "$CTID" -- systemctl is-active "$unit" \
    || { msg_error "systemd-Service $unit ist nicht active."; pct exec "$CTID" -- systemctl status "$unit" --no-pager || true; exit 1; }
  msg_ok "Service laeuft (systemctl is-active $unit = active)."
done

msg_info "Warte auf Web UI (max. 2 Min) ..."
WEB_OK=0
for _ in $(seq 1 12); do
  if pct exec "$CTID" -- curl -fs -m 10 "http://127.0.0.1:${APP_PORT}/login.php" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
if [[ "$WEB_OK" != "1" ]]; then
  msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/login.php."
  pct exec "$CTID" -- systemctl status apache2 --no-pager || true
  pct exec "$CTID" -- journalctl -u lifeos --no-pager --lines=50 || true
  pct exec "$CTID" -- tail -n 100 /var/log/apache2/lifeos_error.log || true
  exit 1
fi
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/login.php)."

pct config "$CTID" | grep -q "onboot: 1" && msg_ok "onboot=1 gesetzt." || msg_warn "onboot nicht 1 – bitte pruefen."

# Credentials-Ablage im CT (0600) – Ueberlebt Updates, kein Ueberschreiben von config.php
pct exec "$CTID" -- bash -c "cat > /root/lifeos.credentials <<EOF
LifeOS CT $CTID – $(date -u +%F-%T UTC)
Web UI : http://${CT_IP}:${APP_PORT}
Login  : ${LIFEOS_USER} / (siehe unten)
DB     : lifeos / ${DB_PASS}
EOF
chmod 600 /root/lifeos.credentials"

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : LifeOS – Self-hosted Life OS"
echo "  Upstream     : $UPSTREAM_REPO ($VERSION)"
echo "  Installer    : $INSTALLER_REPO ($REF)"
echo "  CT           : $CTID (Name: $HOSTNAME_VAL, onboot=1, nesting=1, unprivileged)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Login        : ${LIFEOS_USER} / ${LIFEOS_PASSWORD} (nur jetzt angezeigt!)"
if [[ -n "${ROOTPW:-}" ]]; then
echo "  Root-PW (CT) : ${ROOTPW} (nur jetzt angezeigt!)"
fi
echo "  Hinweis      : DB-Tabellen entstehen beim ersten Login automatisch."
echo "                 API-Token steht in /opt/lifeos/config.php (api_token)"
echo "                 und in /root/lifeos.credentials im CT."
echo "  Services     : pct enter $CTID -> systemctl status apache2 mariadb lifeos"
echo "  Logs         : pct enter $CTID -> journalctl -u lifeos -f"
echo "  Update       : Skript erneut laufen lassen (idempotent: git pull, config.php bleibt)"
echo "  Deinstall    : pct stop $CTID && pct destroy $CTID"
echo "  Reboot-Test  : pct reboot $CTID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/login.php"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
