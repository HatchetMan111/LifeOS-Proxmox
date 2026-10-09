# LifeOS auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil, LXC nativ)

> Upstream-App (kein Teil dieses Repos): `https://github.com/edrisranjbar/lifeos`
> (Self-hosted Life OS – Habits, Goals, Kanban, Finance, Focus, Notizen, MCP-Server, MIT)
> Dieses Repo enthält **nur den Proxmox-Installer**: Host-Script + Gast-Setup + systemd-Unit.
> Die App läuft **nativ** (Apache + PHP 8.2 + MariaDB) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
# 1. Installieren – das war's schon:
#    CT-ID wird vorgeschlagen (immer die nächste freie), Hostname/Resources/Login
#    werden interaktiv abgefragt, DB-Passwort + API-Token generiert:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LifeOS-Proxmox/main/install/lifeos.sh)"
```

Weitere Anpassungen (Flags oder Env-Vars, non-interaktiv möglich):

```bash
CTID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LifeOS-Proxmox/main/install/lifeos.sh)"
bash lifeos.sh --ctid 150 --hostname lifeos --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash lifeos.sh --non-interactive --user me --password '...'   # ohne Prompts (z. B. für Tests)
bash lifeos.sh --version main       # bestimmte Upstream-Version statt main
bash lifeos.sh --debug              # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/lifeos-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / CT-Name | `lifeos` |
| Zweck | Self-hosted Life OS – Habits, Goals, Kanban, Finanzen, Fokus-Timer, Notizen, AI via MCP |
| Tech-Stack | Nativ: Apache (`:8080` → `public_html/`) + PHP 8.2 (`pdo_mysql`, `mbstring`, `curl`) + MariaDB 10.11, kein Build-Step |
| GitHub-Repo (Upstream) | `https://github.com/edrisranjbar/lifeos` |
| Web UI | `http://<CT-IP>:8080` (Apache `Listen 8080`, `0.0.0.0`) |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk (Minimum 1 / 1024 / 4) |
| CT-ID | Vorschlag ist immer die **nächste freie ID** (`pvesh get /cluster/nextid`); belegte ID → Ausweichen, existierende ID + `--ctid` → Update-Modus |
| Template | Debian-12-Standard (`pveam`, `debian-12-standard*.tar.*`) |
| CT-Features | `onboot: 1`, `nesting: 1` (MariaDB-Hardening), unprivileged, DHCP, DNS `1.1.1.1 8.8.8.8` |

Das Host-Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools (root, `pct/pvesh/pvesm`), fragt CT-ID (Default: nächste freie), Hostname,
   Ressourcen, Bridge/Storage und LifeOS-Login interaktiv ab (alles per Flag/Env übersteuerbar),
   erkennt Disk-Storage (bevorzugt `local-lvm`), lädt das Debian-12-Template falls nötig,
2. erstellt den CT `lifeos` (`onboot: 1`, `nesting: 1`, unprivileged, DHCP, Hostname `lifeos`, zufälliges Root-PW),
   startet ihn und wartet auf die Gast-IP,
3. lädt `install/setup.sh` + `systemd/lifeos.service` aus diesem Repo, pusht sie per `pct push`
   in den Gast und führt das Setup aus: Apache + PHP + MariaDB, Upstream-Clone nach
   `/opt/lifeos`, `config.php` (nur Erstinstall – Updates überschreiben nie Credentials),
   Apache-vHost auf `:8080`, `lifeos.service` (Boot-Health-Check), `systemctl enable --now`,
4. verifiziert `systemctl is-active apache2 mariadb lifeos` + HTTP auf `/login.php`
   und gibt die finale URL + CT-IP + einmalig Login- und Root-Passwort aus.

## Nach der Installation

- Web UI: `http://<CT-IP>:8080` (Login beim Prompt vergeben; DB-Tabellen entstehen beim ersten Login automatisch)
- Credentials im CT: `/root/lifeos.credentials` (0600), API-Token in `/opt/lifeos/config.php`
- Services: `pct enter <ID>` → `systemctl status apache2 mariadb lifeos`
- Logs: `journalctl -u lifeos -f`, Apache: `/var/log/apache2/lifeos_error.log`
- MCP-Server (optional, Upstream-Doku): braucht Node.js 22 + `LIFEOS_API_TOKEN` aus `config.php`

## Update / Deinstall / Reboot-Test

```bash
# Update (idempotent: git pull, config.php bleibt unangetastet):
bash lifeos.sh --ctid <ID>
# oder im CT: pct enter <ID> → git -C /opt/lifeos pull --ff-only && systemctl restart apache2

# Deinstall:
pct stop <ID> && pct destroy <ID>

# Reboot-Test (erwartet: nach ~60s wieder HTTP 200):
pct reboot <ID> && sleep 60 && curl -fs http://<CT-IP>:8080/login.php && echo REBOOT-OK
```

## Troubleshooting

- Installer bricht mit `mariadb startet nicht` ab → CT braucht `nesting=1`
  (aktuelles Script setzt das automatisch; Alt-CTs: `pct set <ID> --features nesting=1`).
- Web UI im CT erreichbar (`pct exec <ID> -- curl -fs http://127.0.0.1:8080/login.php`),
  aber nicht vom Host/LAN → CT-IP prüfen (`pct exec <ID> -- ip -4 addr`, DHCP kann
  sich nach Reboot ändern) und Proxmox-Firewall (Datacenter → Firewall, CT-Optionen) prüfen.

## Erwartete Ausgabe (Kurzform)

```
[OK]    Template vorhanden: debian-12-standard_...tar.zst
[OK]    CT 101 erstellt (onboot=1, unprivileged).
[OK]    Gast-IP: 192.168.1.101
[GAST] OK: apache2 + mariadb + lifeos active, Web UI antwortet auf :8080.
[OK]    Web UI antwortet (HTTP 200 auf localhost:8080/login.php).
════════════════ INSTALLATION ERFOLGREICH ════════════════
  Web UI       : http://192.168.1.101:8080
  ...
```
