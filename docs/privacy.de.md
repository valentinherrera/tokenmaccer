# TokenMaccer: Datenschutzhinweis

[English](privacy.md) · Stand: 2. November 2026

Dieser Hinweis gilt für die herunterladbare TokenMaccer-App und ihr freiwilliges Leaderboard. Er beschreibt, was der Code in diesem Repository tut. Wo eine Angabe von etwas abhängt, das der Code nicht festlegt (etwa wie lange Supabase seine Logs aufbewahrt), steht das dabei und ist mit **TBD** markiert.

## Ohne Teilnahme am Leaderboard

TokenMaccer liest die Transkripte von Claude Code auf deinem Mac (`~/.claude/projects`) und speichert dort Tagessummen (`~/Library/Application Support/TokenMaccer/`, dazu `widget.json` im App-Group-Container für das Widget). Nichts davon verlässt deinen Mac. Die App stellt keine Anfrage an den Leaderboard-Server, und es gibt kein Konto für dich.

Die einzige Netzwerkanfrage ist die **Update-Prüfung** ([Sparkle](https://sparkle-project.org)): Die App lädt `appcast.xml` aus dem neuesten GitHub-Release dieses Repositorys, automatisch einmal am Tag nur, wenn du auf die Frage der App zugestimmt hast, oder wenn du **Check for Updates…** wählst. Wie bei jedem Download sieht GitHub deine IP-Adresse und den Anfrage-Header mit Name und Version der App. Die Prüfung sendet nichts über dich oder deine Nutzung.

Die Installation mit `install.sh` (aus dem Quellcode gebaut) stellt überhaupt keine Netzwerkanfragen.

## Wenn du dem Leaderboard beitrittst

Der Beitritt ist freiwillig und standardmäßig aus. Du meldest dich in einem Anmeldefenster des Systems über Supabase Auth mit GitHub an.

### Was auf dem Server gespeichert wird

Der Server ist ein Supabase-Projekt des Maintainers in der Region **eu-west-1** (AWS, Irland).

| Was | Inhalt | Für andere Teilnehmende sichtbar |
|---|---|---|
| Anmeldekonto (Supabase Auth) | Was GitHub bei der Anmeldung übergibt: deine GitHub-Nutzer-ID, dein Nutzername, Name, deine E-Mail-Adresse und der Link zu deinem Avatar; wann das Konto angelegt wurde und wann du dich zuletzt angemeldet hast | Nur der Nutzername |
| Anmeldesitzungen (Supabase Auth) | Je Anmeldung: IP-Adresse, User-Agent (Programmname, Version und Systemversion, wie macOS sie sendet) und das Refresh-Token | Nein |
| Profil | Deine Konto-ID, dein GitHub-Nutzername, der von dir gewählte Anzeigename, wann du beigetreten bist, wann deine letzte Meldung ankam | Anzeigename und GitHub-Nutzername |
| Summen | Für jeden der sechs Zeiträume (heute, 7 Tage, 30 Tage, seit Jahresbeginn, 1 Jahr, gesamt): Input-Token, Output-Token, ihr Gegenwert in USD zu API-Listenpreisen, der erste Tag des Zeitraums, wann zuletzt aktualisiert | Ja, zusammen mit deinem Platz |
| Meldelimit | Deine GitHub-Nutzer-ID und der Zeitpunkt deiner letzten angenommenen Meldung (höchstens eine Meldung je 25 Minuten) | Nein |
| Server-Logs | Supabase protokolliert Anfragen an seine API, die Anmeldung und die Edge Functions in eigenen Logs, auch mit IP-Adressen. Die Edge Functions von TokenMaccer schreiben dort nur Fehlercodes hinein | Nein |

Nie gesendet werden Projektnamen, Prompts, Dateinamen, Modelle oder andere Inhalte deiner Sitzungen. Der Collector meldet höchstens alle 30 Minuten, nach seinem regulären Durchlauf; die App selbst sendet keine Meldungen.

Beitreten können nur Konten mit GitHub-Anmeldung: Für jedes andere Konto legt der Server kein Ranglisten-Profil an.

### Leaderboard-Fenster und Profilbilder

Nach seiner Meldung holt der Collector auch die Ranglisten für das Leaderboard-Fenster der App: je Zeitraum und Einheit die ersten 50 Plätze (Anzeigename, GitHub-Nutzername, Summe) und deinen eigenen Platz. Danach lädt er die GitHub-Profilbilder der Teilnehmer auf diesen Ranglisten von `avatars.githubusercontent.com`, über den GitHub-Nutzernamen: höchstens 12 je Durchlauf, jedes erneut nach sieben Tagen. Diese Anfragen enthalten keinen Schlüssel, kein Token und kein Cookie von TokenMaccer; wie bei jedem Download sieht GitHub deine IP-Adresse und die Anfrage. Vor dem Beitritt und nach dem Austritt wird kein Bild geladen. Die Apps anderer Teilnehmer laden dein GitHub-Profilbild auf dieselbe Weise über deinen Nutzernamen; es ist auf GitHub ohnehin öffentlich.

Die Teilen-Karte („#3 von 120 diese Woche“) entsteht auf deinem Mac. Sie geht nur dorthin, wohin du sie aus dem Teilen-Menü schickst, zusammen mit einem Link zur Projektseite auf GitHub (github.com/valentinherrera/tokenmaccer).

### Was auf deinem Mac gespeichert wird

- `leaderboard.json` in `~/Library/Application Support/TokenMaccer/`: dein Anzeigename, GitHub-Nutzername, deine Konto-ID, deine letzten Plätze, die Zeitpunkte der letzten Meldung und des letzten Versuchs, der letzte Fehler.
- Der Schlüsselbund-Eintrag „TokenMaccer leaderboard sign-in“ mit Access- und Refresh-Token. Lesen kann ihn nur der Hintergrund-Collector von TokenMaccer.
- `leaderboard-top.json` (die Ranglisten des Leaderboard-Fensters, siehe oben) und der Ordner `avatars/` mit den zwischengespeicherten Profilbildern, im selben Ordner wie `leaderboard.json`.

### Wie lange

- **Konto, Sitzungen, Profil und Summen:** bis du austrittst. Inaktive Teilnehmende werden nicht automatisch gelöscht: Wenn du die Hintergrund-Aktualisierung stoppst, ohne auszutreten, bleiben deine letzten Summen auf dem Server; nach drei Tagen ohne Meldung verschwinden sie aus der Rangliste, gelöscht werden sie aber erst mit dem Austritt. Ob und wann der Maintainer inaktive Konten sonst entfernt: **TBD**.
- **Meldelimit:** bleibt nach dem Austritt bestehen, damit Austreten und erneutes Beitreten das 25-Minuten-Limit nicht umgehen. Es wird mit der ersten Meldung gelöscht, die der Server erhält, sobald es älter als eine Stunde ist.
- **Server-Logs:** so lange, wie Supabase sie für dieses Projekt aufbewahrt; die Dauer hängt vom Supabase-Tarif ab und wird nicht von TokenMaccer festgelegt: **TBD**.

### Austreten und Löschen

**Leave…** in der App löscht dein Anmeldekonto auf dem Server. Profil, Summen, Sitzungen und deine GitHub-Identität auf dem Server werden mitgelöscht. Danach entfernt die App die Anmeldung aus deinem Schlüsselbund, `leaderboard.json`, `leaderboard-top.json` und die zwischengespeicherten Profilbilder. Erfolg meldet sie erst, wenn der Server die Löschung bestätigt hat. Nicht durch Leave gelöscht werden der Eintrag des Meldelimits (siehe oben) und Einträge in den Logs von Supabase.

Meldest du dich beim Austreten mit einem anderen GitHub-Konto an als dem, das beigetreten ist, lehnt die App das ab und löscht das Konto, das diese Anmeldung auf dem Server angelegt hat, wieder, es sei denn, dieses Konto nimmt selbst am Leaderboard teil.

**Stop › Stop Background Updates & Remove Data…** tritt zuerst aus dem Leaderboard aus und entfernt nichts, solange das scheitert.

## Verantwortlich und Kontakt

Das Leaderboard betreibt der Maintainer dieses Repositorys (GitHub: [valentinherrera](https://github.com/valentinherrera)). Name und Postanschrift der verantwortlichen Person: **TBD**. Rechtsgrundlage der Verarbeitung und Angaben zu Übermittlungen außerhalb der EU: **TBD**.

Dienstleister: [Supabase](https://supabase.com) betreibt den Server (Datenbank, Anmeldung, Edge Functions). GitHub stellt die Anmeldung bereit; für dein GitHub-Konto gilt die Datenschutzerklärung von GitHub. Updates werden von GitHub Releases geladen.

Fragen, Anliegen zu deinen Daten oder Hinweise auf ein Problem: als Issue unter <https://github.com/valentinherrera/tokenmaccer/issues>. Issues sind öffentlich; bitte dort keine personenbezogenen Daten posten. Ein privater Kontaktweg: **TBD**.
