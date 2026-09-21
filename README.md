# ubuntu-server-initial-setup

Setup-Skripte für frisch installierte Ubuntu-Server-VMs. Automatisieren die
Grundkonfiguration: System-Update, Anlegen eines Nicht-Root-Users, Verteilen der
SSH-Keys, Wechsel auf einen zufälligen SSH-Port, SSH-Härtung und Firewall.

| Skript | Zweck |
|---|---|
| `ubuntu-setup.sh` | aktuelle Version, sichere Reihenfolge inkl. Verbindungs-Check vor der Härtung |
| `server-setup.sh` | ältere/einfachere Variante ohne Zwischenprüfung |

## Ablauf von `ubuntu-setup.sh`

1. System-Update und Basis-Pakete
2. Nicht-Root-Benutzer anlegen
3. SSH-Keys einspielen (Einfügen oder Drop-Ordner)
4. SSH-Port auf zufälligen Port im Bereich 5XXXX ändern
5. **Verifikation:** neue SSH-Verbindung muss in einem zweiten Terminal funktionieren
6. erst danach: Root-Login und Passwort-Authentifizierung abschalten
7. erst danach: Firewall aktivieren, neuer SSH-Port freigegeben

Schritt 5 ist der Grund für die Reihenfolge — ohne bestätigte Zweitverbindung
sperrt man sich bei falschem Key aus.

## Voraussetzungen

- frisch installierter Ubuntu Server (getestet auf 22.04/24.04)
- Root-Zugang oder `sudo`
- öffentlicher SSH-Key des Admins zur Hand
- **zweites Terminal offen halten**, bis Schritt 5 bestätigt ist

## Nutzung

```bash
git clone https://github.com/Pro-Discount-Import-Export-e-K/ubuntu-server-initial-setup.git
cd ubuntu-server-initial-setup
chmod +x ubuntu-setup.sh
sudo ./ubuntu-setup.sh
```

Das Skript führt interaktiv durch die Schritte. Der gewählte SSH-Port wird am
Ende ausgegeben — notieren, sonst ist der Server nach dem Neustart nicht mehr
erreichbar.
