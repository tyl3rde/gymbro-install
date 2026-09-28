# Installation

Eigene Instanz von „Where's Gymbro?" auf einem Server. Vorgebautes Image, ein
Skript, ~5 Minuten.

## Voraussetzungen

- **Server:** Ubuntu 24.04 oder Debian 12, **arm64 oder amd64**,
  2 vCPU / 2 GB RAM / 20 GB SSD genügen (es wird nichts kompiliert — das
  Image ist fertig). Empfohlen 4 GB, damit Platz für Backups bleibt.
- **Dedizierte IPv4** und eine **Domain/Subdomain**, deren A-Record
  (optional AAAA) **schon auf den Server zeigt** — sonst gibt es kein
  TLS-Zertifikat. Bei Cloudflare: Proxy auf „DNS only" (graue Wolke).
- **Ports 80 und 443** von außen erreichbar.
- Root-/sudo-Zugang per SSH.

Getestet u. a. auf einem kleinen Netcup-VPS (x86, 2 vCPU, 2 GB RAM, Ubuntu
24.04). Läuft auf dem Server schon ein Reverse-Proxy, siehe den Abschnitt
[Server mit bestehendem Reverse-Proxy](#server-mit-bestehendem-reverse-proxy).

## Installation

Ein Befehl, per SSH auf dem Server:

```bash
curl -fsSL https://raw.githubusercontent.com/tyl3rde/gymbro-install/main/install.sh | sudo bash
```

Wer das Skript vorher lesen will (gute Idee bei allem, was als root läuft):

```bash
curl -fsSL https://raw.githubusercontent.com/tyl3rde/gymbro-install/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

Der Installer liegt öffentlich in
[tyl3rde/gymbro-install](https://github.com/tyl3rde/gymbro-install) und wird
bei jedem stabilen Release aus dem App-Repo nachgezogen. Mit Zugang zum
App-Repo geht auch `git clone` und dann `sudo ./install.sh` im Checkout.

Das Skript fragt Domain, E-Mail (Let's Encrypt), Admin-Name und Admin-PIN.
Gibt es eine Testversion, die neuer ist als die letzte stabile, fragt es
außerdem „Beta installieren? [j/N]" — Enter nimmt die stabile Version
(`latest`, Updates per Klick), `j` den neuesten Prerelease als feste Version.
Eine bestimmte Version ohne Frage: `curl … | sudo GYMBRO_IMAGE=ghcr.io/tyl3rde/gymbro:1.1.3 bash`.
Dann erledigt es:

1. Docker installieren (falls nicht vorhanden)
2. Secrets erzeugen (Session, PIN-Pepper, Cron) **und ein VAPID-Keypair** für
   Push-Benachrichtigungen
3. `/opt/gymbro` anlegen: `.env` (chmod 600), `docker-compose.yml`, `Caddyfile`
4. Optional die Firewall (ufw) einrichten
5. Image ziehen und starten — Caddy holt das TLS-Zertifikat automatisch
6. Den Admin-Account anlegen
7. Prüfen, dass `https://<deine-domain>/login` wirklich antwortet

Danach: einloggen, und unter **Einstellungen → Nutzerverwaltung** die übrigen
Leute anlegen (jeder bekommt eine 4-stellige PIN).

> Das Image ist **öffentlich** — für die Installation ist keine Anmeldung bei
> GHCR nötig. Nur falls das Package einmal privat gestellt wird, braucht der
> Server `docker login ghcr.io` (GitHub-User + PAT mit `read:packages`); das
> Skript fragt in dem Fall danach.

## Server mit bestehendem Reverse-Proxy

`install.sh` geht von einem frischen Server aus und bringt eigenen Caddy auf
80/443 mit. Läuft dort schon ein zentraler Proxy, nimm stattdessen
`release/docker-compose.proxy.yml`: kein Caddy, keine veröffentlichten Ports,
die App hängt in einem bestehenden Docker-Network.

```bash
# Die App läuft im Container als uid 1000, nicht als root — ohne chown kann
# sie ihre Datenbank nicht anlegen (SQLITE_CANTOPEN).
sudo mkdir -p /opt/gymbro/data/updater
sudo chown -R 1000:1000 /opt/gymbro/data

# WICHTIG als docker-compose.yml ablegen — der updater-Sidecar ruft
# `docker compose` ohne -f auf und findet sonst nichts.
sudo curl -fsSL -o /opt/gymbro/docker-compose.yml \
  https://raw.githubusercontent.com/tyl3rde/gymbro-install/main/release/docker-compose.proxy.yml

# Secrets + VAPID-Keypair erzeugen und .env schreiben
cd /opt/gymbro
VAPID=$(docker run --rm node:22-alpine node -e '
  const c=require("crypto"),k=c.generateKeyPairSync("ec",{namedCurve:"prime256v1"}),
  j=k.privateKey.export({format:"jwk"}),b=s=>Buffer.from(s,"base64url");
  console.log(Buffer.concat([Buffer.from([4]),b(j.x),b(j.y)]).toString("base64url"));
  console.log(j.d);')
sudo tee .env >/dev/null <<EOF
GYMBRO_IMAGE=ghcr.io/tyl3rde/gymbro:latest
PROXY_NETWORK=web                      # Name des vorhandenen Proxy-Networks
SESSION_SECRET=$(openssl rand -hex 32)
PIN_PEPPER=$(openssl rand -hex 32)
CRON_SECRET=$(openssl rand -hex 32)
VAPID_PUBLIC_KEY=$(echo "$VAPID" | sed -n 1p)
VAPID_PRIVATE_KEY=$(echo "$VAPID" | sed -n 2p)
VAPID_EMAIL=mailto:du@example.com
COOKIE_SECURE=true
ADMIN_USER_ID=gymbro_admin
EOF
sudo chmod 600 .env

sudo docker compose up -d
# Die Datenbank entsteht erst beim ersten Seitenaufruf, nicht beim Start.
# Sobald `docker compose ps` die App als healthy zeigt, einmal anstoßen:
sudo docker compose exec -T wheres-gymbro wget -qO /dev/null http://127.0.0.1:3000/login
# PIN verdeckt abfragen und per stdin übergeben — als Argument wäre sie in `ps`
# sichtbar. (Ältere Images kennen nur die Form mit der PIN als 2. Argument.)
read -rsp "Admin-PIN: " PIN; echo
printf '%s\n' "$PIN" | sudo docker compose exec -T wheres-gymbro node scripts/bootstrap-admin.mjs "<Name>"; unset PIN
```

Im vorhandenen Proxy dann auf `gymbro-app:3000` weiterleiten, z. B. Caddy:

```caddyfile
gymbro.example.de {
  encode zstd gzip
  reverse_proxy gymbro-app:3000
}
```

Die Sicherheits-Header (CSP, HSTS, `X-Frame-Options`, …) liefert in diesem
Setup **dein** Proxy — übernimm sie aus `release/Caddyfile`, sonst fehlen sie.

> ‼️ **Der App-Service darf kein `ports:` bekommen.** Der Brute-Force-Schutz
> beim Login zählt Fehlversuche pro IP und liest die IP aus `X-Forwarded-For`,
> weil davor immer ein Proxy steht. Wird die App direkt veröffentlicht, kann
> jeder diesen Header fälschen und damit Lockout und IP-Bann aushebeln. Sie
> darf ausschließlich über den Proxy erreichbar sein.

Beim Update-Knopf ändert sich nichts: Der `updater`-Sidecar liegt in dieser
Variante genauso bei und aktualisiert nur den App-Container — der Proxy bleibt
unberührt.

## Betrieb

```bash
cd /opt/gymbro
docker compose logs -f            # Logs
docker compose pull && docker compose up -d   # Update
docker compose down               # Stoppen
```

### Updates

Läuft der Update-Check (Standard), prüft die Instanz **einmal täglich**, ob ein
neues Release vorliegt, und zeigt Admins einen Hinweis mit drei Optionen:
**installieren**, **Changelog öffnen** oder **ausblenden** (der Hinweis kommt
dann erst bei der nächsten Version wieder).

**Installiert wird nie automatisch.** Das ist bewusst so: ein automatischer
Rollout würde ein kompromittiertes Release ungefragt auf alle Instanzen
bringen. Es gibt deshalb keine „automatisch installieren"-Option — nur den
Klick eines Admins.

**Privates Repo?** Der Check braucht dafür **nichts** extra: Antwortet die
GitHub-Releases-API mit 404 (privates Repo ohne Token), fragt die App die
Tag-Liste der Container-Registry ab — die ist bei öffentlichem Package ohne
Anmeldung lesbar. Optional geht auch ein GitHub-PAT mit Lesezugriff als
`UPDATE_TOKEN` in der `.env`; das liefert zusätzlich das Veröffentlichungsdatum.
Ist auch das **Package** privat, braucht der Host einmal `docker login ghcr.io`
(der One-Click-Updater nutzt diese Anmeldung mit) und der Check ein
`UPDATE_TOKEN`.

Abschalten geht auf zwei Wegen:
- **In der App:** Einstellungen → Analytics (`/admin`) → Schalter bei „Updates".
- **Per Env:** `UPDATE_CHECK=off` in `/opt/gymbro/.env`, dann
  `docker compose up -d`. Dann gehen gar keine Anfragen an GitHub raus.

Der **One-Click-Button** funktioniert über den `updater`-Container. Der hat den
Docker-Socket gemountet (= Root-Rechte auf dem Host) und wird **nur** aktiv,
wenn die App auf Admin-Klick eine Trigger-Datei schreibt. Wer das nicht
möchte: den `updater`-Service aus `docker-compose.yml` löschen und
`UPDATER_ENABLED=false` setzen — der Hinweis bleibt, das Einspielen läuft dann
per SSH (`docker compose pull && up -d`).

### Backups

Alle Daten liegen in `/opt/gymbro/data` (SQLite-DB, Avatare, Session-Fotos,
AU-Belege). Die App legt zusätzlich täglich ein DB-Backup in `data/backups/`
ab (7 Tage Rotation) — **das liegt aber auf derselben Platte**. Für echten
Schutz `data/` regelmäßig woandershin kopieren, z. B. vom eigenen Rechner:

```bash
rsync -az <user>@<server>:/opt/gymbro/data/ ~/gymbro-backup/
```

`data/` enthält Gesundheitsdaten (AU-Belege) — entsprechend behandeln.
Vor jedem Update ein Backup zu haben ist die einfachste Rollback-Versicherung
(zurück geht es mit `GYMBRO_IMAGE=ghcr.io/tyl3rde/gymbro:<alte-version>` in
der `.env` plus `docker compose up -d`). Danach für künftige Klick-Updates
wieder auf `…:latest` zurückstellen — auf einer festen Version kann der
Updater nichts ausrichten, und die App weist darauf hin.

> Als Rollback-Ziel taugen nur Versionen **ab 1.1.2**. Die Images von 1.0.0
> und 1.1.0 sind mit Provenance-Attestierungen gebaut; Docker ab Version 29
> löst mit dem containerd-Store den vollständigen Index auf und ist dabei
> empfindlich gegenüber deren Zustand (siehe Issue #2). Ab 1.1.2 werden keine
> Attestierungen mehr erzeugt, der Index enthält nur die beiden
> Plattform-Images.

### Admin-PIN vergessen?

```bash
cd /opt/gymbro
read -rsp "Neue PIN: " PIN; echo
printf '%s\n' "$PIN" | docker compose exec -T wheres-gymbro node scripts/bootstrap-admin.mjs "<Name>"; unset PIN
```

Setzt Name/PIN des Admins neu und meldet alle alten Sessions ab.

## Konfiguration (`/opt/gymbro/.env`)

| Variable | Bedeutung |
|---|---|
| `APP_DOMAIN` | Domain, unter der die App läuft |
| `ACME_EMAIL` | Kontakt für Let's Encrypt |
| `GYMBRO_IMAGE` | Image-Tag. **Für Updates per Klick muss es beweglich sein** (Default `…/gymbro:latest`). Eine feste Version wie `…/gymbro:1.2.0` ist nur für Rollbacks gedacht — dann deaktiviert die App den One-Click-Button und erklärt den manuellen Weg |
| `SESSION_SECRET` | Signiert Login-Cookies. Ändern = alle ausloggen |
| `PIN_PEPPER` | Fließt in die PIN-Hashes. **Nie ändern** — sonst funktioniert keine PIN mehr |
| `CRON_SECRET` | Schützt den internen Reminder-Endpunkt |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | WebPush-Schlüsselpaar |
| `ADMIN_USER_ID` | User-ID mit Admin-Rechten (Default `gymbro_admin`) |
| `ANALYTICS_USER_IDS` | Optional: komma-getrennte User-IDs, die zusätzlich die Analytics lesen dürfen — ohne Nutzerverwaltung, Updates, Feature-Schalter und Gyms |
| `UPDATE_CHECK` | `on` (Default) / `off` — täglicher Release-Check |
| `UPDATE_REPO` | Repo für den Check (Default `tyl3rde/gymbro`) |
| `UPDATE_TOKEN` | Optionales GitHub-PAT. Nur nötig, wenn auch das Package privat ist — bei öffentlichem Package findet der Check die Versionen über die Registry |
| `UPDATER_ENABLED` | `true` = One-Click-Update-Button sichtbar |
| `PROXY_NETWORK` | Nur in der Reverse-Proxy-Variante: Name des bestehenden Docker-Networks (Default `web`) |

**Die `.env` niemals committen oder weitergeben.** Sie ist der Generalschlüssel
der Instanz.

## Anpassen (Fork)

Gyms, Trainingstypen und Texte sind auf einen bestimmten Freundeskreis
zugeschnitten und stecken in `lib/constants.js`. Für eine eigene Crew: Repo
forken, dort anpassen, eigenes Image bauen (`docker compose build` im
Repo-Root) oder in der Fork-CI bauen lassen und `UPDATE_REPO` auf den Fork
zeigen lassen.

## Lizenz

AGPL-3.0-or-later. Wer eine **veränderte** Version für andere betreibt, muss
deren Quellcode anbieten (§13) — siehe [LICENSE](LICENSE).
