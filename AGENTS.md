# AGENTS.md — Where's Gymbro? installieren

Hinweise für KI-Agenten, die jemandem beim Aufsetzen einer eigenen Instanz von
„Where's Gymbro?" helfen. Dieses Repo enthält nur den Installer. Der Quellcode
der App liegt in einem privaten Repo, das fertige Image ist öffentlich:
`ghcr.io/tyl3rde/gymbro` (linux/amd64, linux/arm64).

## Der Installer in einem Satz

`install.sh` richtet auf einem **frischen** Server Docker ein, stellt ein
paar Fragen, schreibt `/opt/gymbro`, startet vier Container und legt den
ersten Admin an:

```bash
curl -fsSL https://raw.githubusercontent.com/tyl3rde/gymbro-install/main/install.sh | sudo bash
```

## Vorher prüfen

Diese Punkte sind die häufigsten Ursachen für einen abgebrochenen Lauf. Prüf
sie, bevor der Mensch den Befehl startet:

| Prüfung | Befehl auf dem Server | Erwartung |
|---|---|---|
| Betriebssystem | `. /etc/os-release; echo $PRETTY_NAME` | Ubuntu 24.04 oder Debian 12 |
| Architektur | `uname -m` | `x86_64` oder `aarch64` |
| RAM | `free -h` | ab 2 GB |
| DNS zeigt auf den Server | `curl -4 -s ifconfig.me` und `getent ahostsv4 <domain>` | dieselbe IPv4 |
| Ports frei | `ss -ltnp '( sport = :80 or sport = :443 )'` | keine Ausgabe |
| Kein Gymbro auf dem Host | `docker compose ls 2>/dev/null` | kein Projekt `gymbro`, kein `/opt/gymbro` |

Stolperfallen beim DNS:

- **Cloudflare:** Der Eintrag muss auf „DNS only" stehen (graue Wolke). Mit
  Proxy (orange) bekommt Caddy kein Let's-Encrypt-Zertifikat.
- **Platzhalter-Einträge** (`*.example.de`) beantworten auch Namen, die es
  gar nicht gibt. Löst die Domain auf, heißt das noch nicht, dass der
  richtige Eintrag gesetzt ist — IP vergleichen.

**Läuft auf dem Host schon etwas auf 80/443 oder ein anderes Gymbro:** nicht
`install.sh` nehmen. Der Installer nutzt fest den Compose-Projektnamen
`gymbro` und das Verzeichnis `/opt/gymbro` und würde eine vorhandene Instanz
ersetzen. Für Server mit bestehendem Reverse-Proxy gibt es
`release/docker-compose.proxy.yml`, beschrieben in [INSTALL.md](INSTALL.md).

## Die Fragen

In dieser Reihenfolge, alle über das Terminal:

1. **Domain**, z. B. `gymbro.example.de` (nur Buchstaben, Ziffern, `.`, `-`)
2. **E-Mail für Let's Encrypt** (muss ein `@` enthalten)
3. **Name des Admin-Accounts** (1–30 Zeichen)
4. **PIN für den Admin**, zweimal (genau 4 Ziffern, verdeckte Eingabe)
5. **Beta installieren? [j/N]** — nur, wenn es einen Prerelease gibt, der
   neuer ist als die letzte stabile Version. Enter = stabil
   (`ghcr.io/tyl3rde/gymbro:latest`, Updates per Klick), `j` = der neueste
   Prerelease als feste Version (kein Update per Klick). Die Versionen liest
   der Installer anonym aus GHCR; klappt das nicht, nimmt er stabil.
   Soll eine bestimmte Version ohne Frage installiert werden:
   `curl … | sudo GYMBRO_IMAGE=ghcr.io/tyl3rde/gymbro:<version> bash`
6. **Firewall (ufw)** einrichten? Auf einem frischen Server Vorauswahl „Ja",
   sonst „Nein"

Stimmt die DNS-Prüfung nicht, fragt er zusätzlich, ob er trotzdem
weitermachen soll.

**Lass den Menschen den Befehl selbst in seinem Terminal starten und die
Antworten tippen**, vor allem die PIN. Sie ist das Admin-Passwort der
Instanz und gehört nicht in deinen Kontext, in Logs oder in eine
Automatisierung. Ein Agent kann Voraussetzungen prüfen, den Befehl nennen,
mitlesen und hinterher prüfen.

Der Installer braucht ein Terminal: Per Pipe gestartet liest er die Fragen
von `/dev/tty`. Ohne Terminal (CI, Cron, `ssh` ohne `-t`) bricht er mit
„Kein Terminal für die Fragen" ab.

In manchen eingebetteten Web-Terminals kommt die Rücktaste als Steuerzeichen
an und die Zeile sieht danach kaputt aus. Die Werte stimmen meist trotzdem.
Im Zweifel die Zeilen in `/opt/gymbro/.env` prüfen (`cat -v`), ohne die
Secrets auszugeben.

## Was danach auf dem Server liegt

- `/opt/gymbro/.env` — Secrets (Session, PIN-Pepper, Cron, VAPID), Domain,
  Image. Rechte 600. **Nie ausgeben oder weitergeben.**
- `/opt/gymbro/docker-compose.yml`, `/opt/gymbro/Caddyfile`
- `/opt/gymbro/data/` — Datenbank, Fotos, tägliche Backups. Gehört uid 1000,
  weil die App im Container als Nutzer `node` (uid 1000) läuft.
- Container `gymbro-wheres-gymbro-1` (App), `gymbro-caddy-1` (HTTPS),
  `gymbro-cron-1` (stündliche Erinnerungen), `gymbro-updater-1` (Update per
  Klick; hat den Docker-Socket gemountet, reagiert nur auf eine Trigger-Datei
  der App)

## Hinterher prüfen

```bash
cd /opt/gymbro
docker compose ps                                  # vier Container, App "healthy"
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/login   # 200
docker compose exec -T wheres-gymbro printenv GYMBRO_VERSION        # installierte Version
docker compose logs --tail 50 wheres-gymbro        # keine Fehler
```

Die Datenbank entsteht erst beim ersten Seitenaufruf, nicht beim Start des
Containers. Der Installer stößt das selbst an. Fehlt `data/gymbro.db` nach
einem manuellen Setup, einmal `/login` aufrufen.

## Häufige Fehler

| Meldung | Ursache |
|---|---|
| `SQLITE_CANTOPEN` im App-Log | `data/` gehört nicht uid 1000 → `chown -R 1000:1000 /opt/gymbro/data` |
| „Domain noch nicht erreichbar" am Ende | DNS noch nicht verteilt, Proxy (orange Wolke) an, oder Port 80/443 zu → `docker compose logs caddy` |
| „docker compose kann … nicht lesen" | `.env` oder `docker-compose.yml` beschädigt, die Meldung darüber nennt die Zeile |
| Pull schlägt fehl | Tippfehler im Image-Namen oder Tag existiert nicht; das Image ist öffentlich, `docker login` ist nicht nötig |

## Erneut ausführen

Der Installer ist wiederholbar. Er übernimmt die Secrets aus der vorhandenen
`/opt/gymbro/.env` (Logins und Push bleiben gültig), fragt aber alles neu ab
und schreibt Domain, E-Mail und Image neu. Den Admin legt er dabei nicht
doppelt an: Name und PIN werden aktualisiert, alle bestehenden Sitzungen des
Admins ungültig.

## Updates und Versionen

- `latest` ist immer die neueste **stabile** Version. Nur mit diesem Tag
  funktioniert das Update per Klick in der App.
- Eine feste Version (`ghcr.io/tyl3rde/gymbro:1.3.0`) bleibt, wo sie ist. Die
  App blendet den Update-Knopf dann aus. Prereleases (`…-rc.N`) bekommen nie
  `latest` und kommen nur mit fester Version auf einen Server.
- Version wechseln: `GYMBRO_IMAGE` in `/opt/gymbro/.env` ändern, dann
  `cd /opt/gymbro && docker compose pull && docker compose up -d`.
  Datenbank-Migrationen laufen beim ersten Zugriff automatisch.

## Nicht tun

- Den App-Container nie direkt mit `ports:` veröffentlichen. Der Login-Schutz
  zählt Fehlversuche pro IP aus `X-Forwarded-For` und verlässt sich darauf,
  dass immer ein Proxy davor steht.
- Kein CDN vorschalten, auch nicht nachträglich die orange Wolke bei
  Cloudflare. Caddy ist als einziger Hop vor der App konfiguriert und sähe
  dann nur Edge-Adressen: Alle Nutzer teilten sich eine Handvoll IPs, und
  der IP-Bann beim Login sperrte die ganze Instanz auf einmal.
- `/opt/gymbro/data` nie löschen oder mit `rsync --delete` überschreiben, ohne
  vorher ein Backup zu haben — dort liegen alle Daten der Nutzer.
- Die `.env` nicht neu erzeugen, wenn schon Nutzer existieren: Ein neuer
  `PIN_PEPPER` macht alle PINs ungültig, ein neues `SESSION_SECRET` meldet
  alle ab.

## Deinstallieren

```bash
cd /opt/gymbro && docker compose down     # Container weg, Daten bleiben
rm -rf /opt/gymbro                        # löscht auch alle Daten — vorher sichern
```
