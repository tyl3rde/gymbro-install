#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Where's Gymbro? — One-Shot-Installer für einen frischen VPS
#
#   curl -fsSL https://raw.githubusercontent.com/tyl3rde/gymbro-install/main/install.sh | sudo bash
#
# oder aus einem Checkout heraus: sudo ./install.sh
#
# Was er tut (interaktiv, fragt vorher):
#   1. Docker installieren (falls nicht vorhanden)
#   2. Secrets generieren (Session, Pepper, Cron) + VAPID-Keypair für WebPush
#   3. /opt/gymbro anlegen: .env, docker-compose.yml, Caddyfile
#   4. Container starten (fertiges Image von GHCR — kein Build auf dem Server)
#   5. Admin-Account anlegen
#   6. Erreichbarkeit über die Domain verifizieren
#
# Voraussetzungen: Ubuntu 24.04 / Debian 12 (arm64 oder amd64), dedizierte
# IPv4, DNS-A-Record der Domain zeigt bereits auf diesen Server (nötig fürs
# TLS-Zertifikat). Details: INSTALL.md
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_DIR="/opt/gymbro"
DEFAULT_IMAGE="ghcr.io/tyl3rde/gymbro:latest"
# Von hier kommen docker-compose.yml und Caddyfile, wenn der Installer nicht
# aus einem Checkout läuft (curl … | sudo bash). Das öffentliche Repo zieht
# die Release-Pipeline bei jedem stabilen Release nach; das App-Repo selbst
# ist privat und für raw.githubusercontent.com nicht lesbar.
INSTALL_BASE="${GYMBRO_INSTALL_BASE:-https://raw.githubusercontent.com/tyl3rde/gymbro-install/main}"

# Aus einem Checkout gestartet (./install.sh) liegt release/ neben dem Skript.
# Per Pipe gibt es keinen Skriptpfad, dann bleibt RELEASE_DIR leer und main()
# lädt die Dateien aus INSTALL_BASE.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
RELEASE_DIR="${SCRIPT_DIR:+$SCRIPT_DIR/release}"

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Liest KEY=VALUE-Zeilen einer .env und setzt nur die bekannten Secrets.
# Kommentare, Leerzeilen und fremde Schlüssel werden übersprungen, umschließende
# Anführungszeichen entfernt. Nichts davon wird als Shell-Code ausgewertet.
load_env_secrets() {
  local line key val
  local re_line='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  local re_dq='^"(.*)"$'
  local re_sq="^'(.*)'\$"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $re_line ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    case "$key" in
      SESSION_SECRET|PIN_PEPPER|CRON_SECRET|VAPID_PUBLIC_KEY|VAPID_PRIVATE_KEY) ;;
      *) continue ;;
    esac
    if [[ "$val" =~ $re_dq ]] || [[ "$val" =~ $re_sq ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    printf -v "$key" '%s' "$val"
  done < "$1"
}

# docker-compose.yml und Caddyfile in ein Temp-Verzeichnis laden (Pipe-Start).
fetch_release_files() {
  RELEASE_DIR="$(mktemp -d)"
  trap 'rm -rf "$RELEASE_DIR"' EXIT
  say "Lade docker-compose.yml und Caddyfile ($INSTALL_BASE) …"
  local f
  for f in docker-compose.yml Caddyfile; do
    curl -fsSL --max-time 30 "$INSTALL_BASE/release/$f" -o "$RELEASE_DIR/$f" \
      || die "release/$f nicht ladbar von $INSTALL_BASE"
  done
  grep -q '^services:' "$RELEASE_DIR/docker-compose.yml" \
    || die "Die geladene docker-compose.yml sieht nicht nach einer Compose-Datei aus."
}

# Alles Weitere steckt in main(), aufgerufen erst in der letzten Zeile. Bei
# `curl … | sudo bash` liest bash das Skript aus der Pipe: So ist es komplett
# gelesen, bevor irgendetwas läuft (ein abgebrochener Download führt nichts
# halb aus), und die Fragen können vom Terminal lesen statt aus der Pipe.
main() {
[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen: curl -fsSL …/install.sh | sudo bash (bzw. sudo ./install.sh)"
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
command -v openssl >/dev/null || { apt-get update -qq && apt-get install -y -qq openssl; }
if [ -z "$RELEASE_DIR" ] || [ ! -f "$RELEASE_DIR/docker-compose.yml" ] || [ ! -f "$RELEASE_DIR/Caddyfile" ]; then
  fetch_release_files
fi

# ── 1. Docker ────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null; then
  say "Docker ist nicht installiert — installiere über get.docker.com …"
  curl -fsSL https://get.docker.com | sh
  ok "Docker installiert."
else
  ok "Docker vorhanden: $(docker --version)"
fi
docker compose version >/dev/null 2>&1 || die "Docker-Compose-Plugin fehlt (docker compose). Docker-Installation prüfen."

# ── 2. Fragen ────────────────────────────────────────────────────────────────
echo
read -rp "Domain (z. B. gymbro.example.de): " DOMAIN
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Das sieht nicht nach einer Domain aus."
read -rp "E-Mail für Let's Encrypt: " ACME_EMAIL
[[ "$ACME_EMAIL" == *@* ]] || die "Das sieht nicht nach einer E-Mail aus."
read -rp "Name des Admin-Accounts (z. B. Berno): " ADMIN_NAME
[ -n "$ADMIN_NAME" ] || die "Admin-Name fehlt."
while :; do
  read -rsp "PIN für den Admin (4 Ziffern): " ADMIN_PIN; echo
  read -rsp "PIN wiederholen: " ADMIN_PIN2; echo
  [[ "$ADMIN_PIN" =~ ^[0-9]{4}$ ]] || { warn "PIN muss genau 4 Ziffern sein."; continue; }
  [ "$ADMIN_PIN" = "$ADMIN_PIN2" ] || { warn "PINs stimmen nicht überein."; continue; }
  break
done
read -rp "Docker-Image [$DEFAULT_IMAGE]: " GYMBRO_IMAGE
GYMBRO_IMAGE="${GYMBRO_IMAGE:-$DEFAULT_IMAGE}"

# ── 3. DNS-Vorabcheck (nur Warnung, kein Abbruch) ────────────────────────────
SERVER_IP="$(curl -fsS4 --max-time 10 https://ifconfig.me 2>/dev/null || true)"
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
if [ -n "$SERVER_IP" ] && [ "$DNS_IP" != "$SERVER_IP" ]; then
  warn "DNS-Check: $DOMAIN zeigt auf '${DNS_IP:-nichts}', dieser Server hat $SERVER_IP."
  warn "Ohne passenden A-Record bekommt Caddy KEIN Zertifikat (TLS schlägt fehl)."
  read -rp "Trotzdem fortfahren? [j/N] " CONT
  [[ "${CONT,,}" == j* ]] || die "Abgebrochen — erst den A-Record setzen, dann erneut starten."
else
  ok "DNS zeigt auf diesen Server ($SERVER_IP)."
fi

# ── 4. Verzeichnis + .env ────────────────────────────────────────────────────
# Das Image läuft als Nutzer node (uid/gid 1000), nicht als root. data/ ist
# ein Bind-Mount und behält die Rechte vom Host: gehört es root, kann die App
# weder ihre Datenbank anlegen (SQLITE_CANTOPEN) noch eine Update-Anfrage
# für den updater schreiben. data/updater gleich mit anlegen, sonst erzeugt
# Docker ihn beim Start als root. (Auf dem Pi fiel das nie auf, weil der
# Host-Nutzer dort zufällig auch uid 1000 hat.)
mkdir -p "$APP_DIR/data/updater"
chown -R 1000:1000 "$APP_DIR/data"
cp "$RELEASE_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"
cp "$RELEASE_DIR/Caddyfile" "$APP_DIR/Caddyfile"

if [ -f "$APP_DIR/.env" ]; then
  warn "Es existiert schon eine .env in $APP_DIR — sie wird WEITERVERWENDET"
  warn "(Secrets bleiben stabil; nur Domain/E-Mail/Image werden aktualisiert)."
  # Bestehende Secrets einlesen, damit PINs/Sessions/Push den Re-Run überleben.
  # Gelesen als Daten, nicht per "." als Shell-Code ausgeführt (#45): das
  # Skript läuft als root, und eine .env mit $(…) oder Backticks darin würde
  # sonst beim Re-Run ausgeführt. Übernommen werden nur die Werte, die unten
  # wiederverwendet werden.
  load_env_secrets "$APP_DIR/.env"
  SESSION_SECRET="${SESSION_SECRET:-$(openssl rand -hex 32)}"
  PIN_PEPPER="${PIN_PEPPER:-$(openssl rand -hex 32)}"
  CRON_SECRET="${CRON_SECRET:-$(openssl rand -hex 32)}"
else
  say "Generiere Secrets …"
  SESSION_SECRET="$(openssl rand -hex 32)"
  PIN_PEPPER="$(openssl rand -hex 32)"
  CRON_SECRET="$(openssl rand -hex 32)"
fi

if [ -z "${VAPID_PUBLIC_KEY:-}" ] || [ -z "${VAPID_PRIVATE_KEY:-}" ]; then
  say "Generiere VAPID-Keypair für WebPush (via node-Container) …"
  VAPID_OUT="$(docker run --rm node:22-alpine node -e '
    const c = require("crypto");
    const k = c.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const j = k.privateKey.export({ format: "jwk" });
    const b = (s) => Buffer.from(s, "base64url");
    const pub = Buffer.concat([Buffer.from([4]), b(j.x), b(j.y)]).toString("base64url");
    console.log(pub); console.log(j.d);
  ')"
  VAPID_PUBLIC_KEY="$(echo "$VAPID_OUT" | sed -n 1p)"
  VAPID_PRIVATE_KEY="$(echo "$VAPID_OUT" | sed -n 2p)"
  [ -n "$VAPID_PUBLIC_KEY" ] && [ -n "$VAPID_PRIVATE_KEY" ] || die "VAPID-Generierung fehlgeschlagen."
fi

# Erst leer mit 600 anlegen, dann füllen — sonst stehen die Secrets bis zum
# chmod mit den Rechten der umask (meist 644) auf der Platte.
: > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
# Kommentare in einem QUOTIERTEN Heredoc: Im unquotierten führt die Shell
# Backticks und $(…) auch in Kommentarzeilen aus. Genau so landete die
# komplette Hilfe von `docker compose` in der .env, und Compose brach mit
# "key cannot contain a space" ab (seit cf60796, betraf v1.1.3 bis 1.3.0-rc.2).
cat >> "$APP_DIR/.env" <<'EOF'
# Where's Gymbro? — Laufzeit-Secrets. NIEMALS committen oder kopierbar ablegen.
# GYMBRO_DIR muss auf dieses Verzeichnis zeigen: die Bind-Mounts im Compose
# sind absolut, weil der updater-Sidecar `docker compose` aus seinem eigenen
# Arbeitsverzeichnis aufruft und relative Pfade dort falsch auflösen würden.
EOF
cat >> "$APP_DIR/.env" <<EOF
GYMBRO_DIR=$APP_DIR
APP_DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
GYMBRO_IMAGE=$GYMBRO_IMAGE
SESSION_SECRET=$SESSION_SECRET
PIN_PEPPER=$PIN_PEPPER
CRON_SECRET=$CRON_SECRET
VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY
VAPID_PRIVATE_KEY=$VAPID_PRIVATE_KEY
VAPID_EMAIL=mailto:$ACME_EMAIL
COOKIE_SECURE=true
ADMIN_USER_ID=gymbro_admin
EOF
ok ".env geschrieben ($APP_DIR/.env, chmod 600)."

# ── 5. Firewall (optional) ───────────────────────────────────────────────────
# Auf einem frischen VPS ist das Einrichten richtig und die Vorauswahl "Ja".
# Läuft dort aber schon etwas, kann ein `ufw --force enable` mit nur diesen
# drei Regeln bestehende Dienste abschneiden — dann ist die Vorauswahl "Nein"
# und der Admin muss bewusst zustimmen (Issue #3).
if command -v ufw >/dev/null; then
  UFW_ACTIVE=0
  ufw status 2>/dev/null | grep -qi "^Status: active" && UFW_ACTIVE=1
  RUNNING_CONTAINERS="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"

  if [ "$UFW_ACTIVE" = "1" ] || [ "${RUNNING_CONTAINERS:-0}" -gt 0 ]; then
    warn "Dieser Server ist nicht frisch:"
    [ "$UFW_ACTIVE" = "1" ] && warn "  • ufw ist bereits aktiv (eigene Regeln vorhanden)"
    [ "${RUNNING_CONTAINERS:-0}" -gt 0 ] && warn "  • $RUNNING_CONTAINERS Container laufen bereits"
    warn "Ein Einrichten setzt NUR SSH/80/443 frei — anderes könnte abgeschnitten werden."
    read -rp "ufw trotzdem jetzt einrichten? [j/N] " UFW
    UFW_DO=0; [[ "${UFW,,}" == j* ]] && UFW_DO=1
  else
    read -rp "ufw-Firewall einrichten (SSH, 80, 443 erlauben + aktivieren)? [J/n] " UFW
    UFW_DO=1; [[ "${UFW,,}" == n* ]] && UFW_DO=0
  fi

  if [ "$UFW_DO" = "1" ]; then
    ufw allow OpenSSH >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    ufw --force enable >/dev/null
    ok "ufw aktiv (OpenSSH, 80, 443)."
  else
    say "ufw übersprungen — Ports 80/443 müssen anderweitig erreichbar sein."
  fi
fi

# ── 6. Image ziehen + starten ────────────────────────────────────────────────
cd "$APP_DIR"
# Erst prüfen, ob Compose .env und docker-compose.yml überhaupt lesen kann.
# Sonst scheitert unten der Pull, und die Hinweise auf ein privates Package
# schicken einen auf die falsche Fährte.
docker compose config -q || die "docker compose kann $APP_DIR/.env oder docker-compose.yml nicht lesen (Meldung oben)."
say "Ziehe Image $GYMBRO_IMAGE …"
if ! docker compose pull; then
  # Zwei häufige Ursachen, und sie sehen im Log unterschiedlich aus. Früher
  # behauptete diese Stelle pauschal "erst anmelden" und schickte damit Leute
  # auf die falsche Fährte (Issue #2).
  warn "Pull von $GYMBRO_IMAGE fehlgeschlagen. Häufige Ursachen:"
  warn "  1) Kein Zugriff (privates Package) → docker login ghcr.io"
  warn "     GitHub-Benutzername + PAT mit read:packages"
  warn "  2) 'content ... not found' trotz Zugriff → der Index dieses Tags ist"
  warn "     unvollständig. Dann NICHT anmelden, sondern ein anderes Tag nehmen:"
  warn "     GYMBRO_IMAGE=$DEFAULT_IMAGE (bzw. eine Version >= 1.1.2)"
  echo
  read -rp "Bei GHCR anmelden und erneut versuchen? [J/n] " RETRY
  if [[ "${RETRY,,}" == n* ]]; then
    die "Abgebrochen. Bei Ursache 2 hilft ein Anmelden nicht — Tag wechseln."
  fi
  docker login ghcr.io
  docker compose pull || die "Pull scheitert weiterhin — siehe Ursache 2 oben (anderes Tag versuchen)."
fi
say "Starte Container …"
docker compose up -d

say "Warte auf App-Start …"
for i in $(seq 1 45); do
  if docker compose exec -T wheres-gymbro wget -qO- http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    ok "App ist gesund."
    break
  fi
  [ "$i" -eq 45 ] && die "App wurde nicht gesund — Logs: cd $APP_DIR && docker compose logs wheres-gymbro"
  sleep 2
done

# Die App öffnet ihre Datenbank erst beim ersten Zugriff, nicht beim Start,
# und /api/health rührt sie nicht an. Auf einem frischen Server gäbe es
# gymbro.db sonst noch nicht, und bootstrap-admin bricht mit "Datenbank nicht
# gefunden" ab. Die Login-Seite liest die Nutzer und legt sie damit an
# (Schema + Migrationen). Klappt mit jeder Image-Version.
say "Lege die Datenbank an …"
for i in $(seq 1 30); do
  docker compose exec -T wheres-gymbro wget -qO /dev/null http://127.0.0.1:3000/login >/dev/null 2>&1 || true
  if docker compose exec -T wheres-gymbro test -f /app/data/gymbro.db; then
    ok "Datenbank angelegt."
    break
  fi
  [ "$i" -eq 30 ] && die "Datenbank wurde nicht angelegt (Rechte von $APP_DIR/data? Muss uid 1000 gehören) — Logs: cd $APP_DIR && docker compose logs wheres-gymbro"
  sleep 2
done

# ── 7. Admin anlegen ─────────────────────────────────────────────────────────
say "Lege Admin-Account an …"
# PIN über stdin, nicht als Argument (#45): Argumente sind für jeden Nutzer
# des Hosts in `ps` sichtbar. Ältere Images (vor der stdin-Unterstützung)
# kennen nur die Argument-Form — dann bleibt es bei der, mit Hinweis.
if docker compose exec -T wheres-gymbro grep -q GYMBRO_BOOTSTRAP_PIN_STDIN scripts/bootstrap-admin.mjs 2>/dev/null; then
  printf '%s\n' "$ADMIN_PIN" | docker compose exec -T wheres-gymbro node scripts/bootstrap-admin.mjs "$ADMIN_NAME"
else
  warn "Dieses Image kennt die PIN-Übergabe per stdin noch nicht — PIN geht als Argument."
  docker compose exec -T wheres-gymbro node scripts/bootstrap-admin.mjs "$ADMIN_NAME" "$ADMIN_PIN"
fi

# ── 8. Verifikation über die echte Domain ────────────────────────────────────
say "Prüfe https://$DOMAIN (Zertifikatsausstellung kann ~30 s dauern) …"
VERIFIED=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 10 "https://$DOMAIN/login" 2>/dev/null | grep -q "Where.s Gymbro"; then
    VERIFIED=1
    break
  fi
  sleep 3
done
if [ "$VERIFIED" -eq 1 ]; then
  ok "https://$DOMAIN antwortet mit der Login-Seite."
else
  warn "Domain noch nicht erreichbar — meist DNS-Propagation oder Zertifikat."
  warn "Später prüfen:  curl -s https://$DOMAIN/login | grep Gymbro"
  warn "Caddy-Logs:     cd $APP_DIR && docker compose logs caddy"
fi

echo
ok "Fertig! 🎉"
cat <<EOF

  URL:        https://$DOMAIN
  Admin:      $ADMIN_NAME (Login über die Nutzerauswahl, deine 4-stellige PIN)
  Nutzer:     als Admin unter https://$DOMAIN/admin/users anlegen
  Verzeichnis:$APP_DIR   (Daten in data/, Secrets in .env — sichern!)

  Update:     cd $APP_DIR && docker compose pull && docker compose up -d
  Logs:       cd $APP_DIR && docker compose logs -f
  Backup:     $APP_DIR/data komplett sichern (DB, Fotos, tägliche Backups
              liegen in data/backups/ — zusätzlich extern wegkopieren!)
EOF
}

# Per Pipe gestartet (stdin ist das Skript selbst): Fragen vom Terminal lesen.
if [ -t 0 ]; then
  main "$@"
elif { : </dev/tty; } 2>/dev/null; then
  main "$@" </dev/tty
else
  die "Kein Terminal für die Fragen. Bitte interaktiv starten: curl -fsSL …/install.sh | sudo bash"
fi
