# TokenMaccer: Datenschutzhinweis

[English](privacy.md) · Stand: 3. November 2026

Dieser Hinweis gilt für die herunterladbare TokenMaccer-App und ihr freiwilliges Leaderboard. Er beschreibt, was der Code in diesem Repository tut. Wo eine Angabe nicht vom Code abhängt, sondern von einem Dienstleister (etwa wie lange Supabase seine Logs aufbewahrt), steht das dabei, zusammen mit der Angabe des Dienstleisters.

## Ohne Teilnahme am Leaderboard

TokenMaccer liest die Transkripte von Claude Code auf deinem Mac (`~/.claude/projects`, dorthin schreibt Claude Code im Terminal und in der Claude-Desktop-App) und speichert dort Tagessummen (`~/Library/Application Support/TokenMaccer/`, dazu `widget.json` im App-Group-Container für das Widget). Nichts davon verlässt deinen Mac. Die App stellt keine Anfrage an den Leaderboard-Server, und es gibt kein Konto für dich.

Die einzige Netzwerkanfrage ist die **Update-Prüfung** ([Sparkle](https://sparkle-project.org)): Die App lädt `appcast.xml` aus dem neuesten GitHub-Release dieses Repositorys, automatisch einmal am Tag (abschaltbar unter **Einstellungen … › Updates**) und wenn du **Nach Updates suchen …** wählst; steht dort eine neue Version, lädt sie diese aus demselben Release. Wie bei jedem Download sieht GitHub deine IP-Adresse und den Anfrage-Header mit Name und Version der App. Die Prüfung sendet nichts über dich oder deine Nutzung.

Die Installation mit `install.sh` (aus dem Quellcode gebaut) stellt überhaupt keine Netzwerkanfragen.

## Die Website tokenmaccer.app

Die Website (Download-Seite, dieser Hinweis, Einladungslinks) wird bei [Vercel](https://vercel.com) gehostet. Wie jeder Webserver erhält Vercel deine IP-Adresse, die aufgerufene Adresse (bei einem Einladungslink also auch den Einladungscode der Gruppe) und die Anfrage-Header deines Browsers und hält Anfragen in seinen Logs fest. Im Tarif dieser Website (Pro) zeigt Vercel diese Logs dem Maintainer einen Tag lang an; wie lange Vercel sie darüber hinaus auf eigenen Systemen aufbewahrt, gibt Vercel nicht an. Der Maintainer exportiert oder kopiert diese Logs nicht. Die Seiten setzen keine Cookies, nutzen keine Analyse und laden nichts von anderen Servern. Deine Sprachwahl merken sie sich nur in deinem Browser (Local Storage). Eine Einladungsseite gibt den Code an die App auf deinem Mac weiter und sendet ihn sonst nirgendwohin.

## Wenn du dem Leaderboard beitrittst

Der Beitritt ist freiwillig und standardmäßig aus. Du meldest dich in einem Anmeldefenster des Systems über Supabase Auth mit GitHub an.

### Was auf dem Server gespeichert wird

Der Server ist ein Supabase-Projekt des Maintainers in der Region **eu-west-1** (AWS, Irland).

| Was | Inhalt | Für andere Teilnehmende sichtbar |
|---|---|---|
| Anmeldekonto (Supabase Auth) | Was GitHub bei der Anmeldung übergibt: deine GitHub-Nutzer-ID, dein Nutzername, Name, deine E-Mail-Adresse und der Link zu deinem Avatar; wann das Konto angelegt wurde und wann du dich zuletzt angemeldet hast | Nur der Nutzername |
| Anmeldesitzungen (Supabase Auth) | Je Anmeldung: IP-Adresse, User-Agent (Programmname, Version und Systemversion, wie macOS sie sendet) und das Refresh-Token | Nein |
| Profil | Deine Konto-ID, dein GitHub-Nutzername, der von dir gewählte Anzeigename, wann du beigetreten bist, wann deine letzte Meldung ankam | Anzeigename und GitHub-Nutzername |
| Summen | Für jeden der sechs Zeiträume (heute, 7 Tage, 30 Tage, seit Jahresbeginn, 1 Jahr, gesamt): Eingabe-Token, Ausgabe-Token, ihr Gegenwert in USD zu API-Listenpreisen, der erste Tag des Zeitraums, wann zuletzt aktualisiert | Ja, zusammen mit deinem Platz |
| Meldegrenze | Deine GitHub-Nutzer-ID und der Zeitpunkt deiner letzten angenommenen Meldung (höchstens eine Meldung je 8 Minuten) | Nein |
| Gruppen (freiwillig) | Je Gruppe: ihr Name, ihr Einladungscode, die Konto-ID der Person, der sie gehört, wann sie angelegt wurde | Nur für die Mitglieder der Gruppe: Name, Einladungscode und wem sie gehört |
| Gruppenmitgliedschaften (freiwillig) | Je Gruppe, in der du bist: deine Konto-ID und wann du beigetreten bist | Nur für die Mitglieder der Gruppe: dein Anzeigename, GitHub-Nutzername und dein Platz und deine Summen in der Rangliste der Gruppe |
| Beitrittsversuche | Deine GitHub-Nutzer-ID (sonst deine Konto-ID) und wie oft du je Stunde versucht hast, einer Gruppe beizutreten (höchstens 30 je Stunde) | Nein |
| Server-Logs | Supabase protokolliert Anfragen an seine API, die Anmeldung und die Edge Functions in eigenen Logs, auch mit IP-Adressen. Die Edge Functions von TokenMaccer schreiben dort nur Fehlercodes hinein | Nein |

Nie gesendet werden Projektnamen, Prompts, Dateinamen, Modelle oder andere Inhalte deiner Sitzungen. Der Collector meldet alle 10 Minuten, solange sich deine Summen ändern, sonst alle 30 Minuten, nach seinem regulären Durchlauf; die App selbst sendet keine Meldungen.

Beitreten können nur Konten mit GitHub-Anmeldung: Für jedes andere Konto legt der Server kein Ranglisten-Profil an.

### Leaderboard-Fenster und Profilbilder

Nach seiner Meldung holt der Collector auch die Ranglisten für das Leaderboard-Fenster der App: je Zeitraum und Einheit die ersten 50 Plätze (Anzeigename, GitHub-Nutzername, Summe) und deinen eigenen Platz. Danach lädt er die GitHub-Profilbilder der Teilnehmenden auf diesen Ranglisten von `avatars.githubusercontent.com`, über den GitHub-Nutzernamen: höchstens 12 je Durchlauf, jedes erneut nach sieben Tagen. Diese Anfragen enthalten keinen Schlüssel, kein Token und kein Cookie von TokenMaccer; wie bei jedem Download sieht GitHub deine IP-Adresse und die Anfrage. Vor dem Beitritt und nach dem Austritt wird kein Bild geladen. Die Apps anderer Teilnehmender laden dein GitHub-Profilbild auf dieselbe Weise über deinen Nutzernamen; es ist auf GitHub ohnehin öffentlich.

Die Teilen-Karte („#3 von 120 diese Woche“) entsteht auf deinem Mac. **Teilen …** schickt nur eine kurze Nachricht mit einem Link zu tokenmaccer.app dorthin, wohin du sie im Teilen-Menü schickst; Apps mit Linkvorschau laden sie von tokenmaccer.app. Die Karte selbst verlässt deinen Mac nur, wenn du sie mit **Bild kopieren** kopierst und irgendwo einfügst.

### Gruppen

Gruppen sind freiwillig und setzen das Leaderboard voraus. Wer den Einladungslink einer Gruppe (`https://tokenmaccer.app/join/…` oder `tokenmaccer://join/…`) oder ihren Code hat, kann ihr beitreten. Nur die Mitglieder einer Gruppe sehen, dass es sie gibt, ihren Namen, ihren Einladungscode, wer in ihr ist (Anzeigename, GitHub-Nutzername, wem sie gehört) und ihre Rangliste; ein falscher Code verrät nichts über irgendeine Gruppe. Die Rangliste einer Gruppe zeigt, was das globale Leaderboard von allen Teilnehmenden ohnehin zeigt (Anzeigename, GitHub-Nutzername, Summen), beschränkt auf die Mitglieder der Gruppe. Wem die Gruppe gehört, kann sie umbenennen, einen neuen Link erzeugen (der alte gilt sofort nicht mehr), Mitglieder entfernen und die Gruppe löschen. Grenzen: höchstens 10 eigene Gruppen, insgesamt 20 Gruppen, 100 Mitglieder je Gruppe, 30 Beitrittsversuche je Stunde.

Nach jeder Meldung, direkt nach jeder Änderung an Gruppen, die du in der App vornimmst, und wenn du das Leaderboard-Fenster öffnest, dort eine Gruppe wählst oder **Gruppen …** öffnest (höchstens einmal pro Minute), holt der Collector deine Gruppen, ihre Mitglieder und ihre Ranglisten (je Zeitraum und Einheit die ersten 50 Plätze und deinen eigenen) und danach die Profilbilder der Personen auf diesen Ranglisten, auf dieselbe Weise wie oben für die globalen Ranglisten. Die Einladungskarte einer Gruppe entsteht auf deinem Mac; **Teilen …** schickt nur die Nachricht mit dem Einladungslink, die Karte selbst nur, wenn du sie kopierst und einfügst.

### Was auf deinem Mac gespeichert wird

- `leaderboard.json` in `~/Library/Application Support/TokenMaccer/`: dein Anzeigename, GitHub-Nutzername, deine Konto-ID, deine letzten Plätze, die Zeitpunkte der letzten Meldung und des letzten Versuchs, der letzte Fehler.
- Der Schlüsselbund-Eintrag „TokenMaccer leaderboard sign-in“ mit Access- und Refresh-Token. Lesen kann ihn nur der Hintergrund-Collector von TokenMaccer.
- `leaderboard-top.json` (die Ranglisten des Leaderboard-Fensters, siehe oben) und der Ordner `avatars/` mit den zwischengespeicherten Profilbildern, im selben Ordner wie `leaderboard.json`.
- `leaderboard-groups.json` im selben Ordner: deine Gruppen (Name, Einladungscode, ob sie dir gehören), ihre Mitglieder (Anzeigename, GitHub-Nutzername, eine Mitglieds-Kennung, mit der die Besitzerin oder der Besitzer jemanden entfernt) und ihre Ranglisten.
- `leaderboard-widget.json` im App-Group-Container: eine Kopie für das Leaderboard-Widget, je Rangliste die ersten acht Plätze und deinen eigenen, dasselbe für jede deiner Gruppen (mit dem Namen der Gruppe), mit den Profilbildern dieser Personen.

### Wie lange

- **Konto, Sitzungen, Profil und Summen:** bis du austrittst. Inaktive Teilnehmende werden nicht automatisch gelöscht: Wenn du die Hintergrund-Aktualisierung stoppst, ohne auszutreten, bleiben deine letzten Summen auf dem Server; nach drei Tagen ohne Meldung verschwinden sie aus der Rangliste, gelöscht werden sie aber erst mit dem Austritt. Auch der Maintainer entfernt inaktive Konten nicht; von Hand entfernt er ein Konto nur auf deine Bitte hin oder um Missbrauch zu stoppen.
- **Meldegrenze:** bleibt nach dem Austritt bestehen, damit Austreten und erneutes Beitreten das 25-Minuten-Limit nicht umgehen. Es wird mit der ersten Meldung gelöscht, die der Server erhält, sobald es älter als eine Stunde ist.
- **Gruppen und Mitgliedschaften:** bis du die Gruppe oder das Leaderboard verlässt, die Besitzerin oder der Besitzer dich entfernt oder die Gruppe löscht.
- **Beitrittsversuche:** bleiben nach dem Austritt bestehen; Einträge, die älter als einen Tag sind, werden beim nächsten Beitrittsversuch gelöscht, den irgendjemand unternimmt.
- **Server-Logs:** so lange, wie Supabase sie für dieses Projekt aufbewahrt. Das Projekt läuft im kostenlosen Supabase-Tarif, für den Supabase eine Log-Aufbewahrung von einem Tag angibt („API & Database“). Supabase speichert seine Logs in Rechenzentren in der EU. Die Dauer legt Supabase fest, nicht TokenMaccer, und sie ändert sich mit dem Tarif.

### Austreten und Löschen

**Austreten …** in der App löscht dein Anmeldekonto auf dem Server. Profil, Summen, Sitzungen, Gruppenmitgliedschaften und deine GitHub-Identität auf dem Server werden mitgelöscht. Gruppen, die dir gehören, gehen an das Mitglied über, das als Erstes beigetreten ist; eine Gruppe ohne weiteres Mitglied wird gelöscht. Danach entfernt die App die Anmeldung aus deinem Schlüsselbund, `leaderboard.json`, `leaderboard-top.json`, `leaderboard-groups.json`, `leaderboard-widget.json` und die zwischengespeicherten Profilbilder. Erfolg meldet sie erst, wenn der Server die Löschung bestätigt hat. Nicht durch Austreten gelöscht werden der Eintrag der Meldegrenze, die Beitrittsversuche (siehe oben) und Einträge in den Logs von Supabase.

**Gruppe verlassen …** (Leaderboard-Fenster › Gruppen …) entfernt nur diese eine Mitgliedschaft, mit derselben Übergabe, wenn dir die Gruppe gehört; dein Eintrag im Leaderboard bleibt.

Meldest du dich beim Austreten mit einem anderen GitHub-Konto an als dem, das beigetreten ist, lehnt die App das ab und löscht das Konto, das diese Anmeldung auf dem Server angelegt hat, wieder, es sei denn, dieses Konto nimmt selbst am Leaderboard teil.

**Stoppen › Hintergrund-Updates stoppen und Daten entfernen …** tritt zuerst aus dem Leaderboard aus und entfernt nichts, solange das scheitert.

## Verantwortlich und Kontakt

Verantwortlich für das Leaderboard und die Website: PAUS UG (haftungsbeschränkt), Gustav-Poensgen-Str. 49, 40215 Düsseldorf, vertreten durch den Geschäftsführer Valentin Herrera, der dieses Repository pflegt (GitHub: [valentinherrera](https://github.com/valentinherrera)). E-Mail: valentin@paus.works. Impressum: <https://tokenmaccer.app/impressum>.

Dienstleister: [Supabase](https://supabase.com) betreibt den Server (Datenbank, Anmeldung, Edge Functions); [Vercel](https://vercel.com) hostet die Website. Beide verarbeiten die Daten in unserem Auftrag nach ihren Auftragsverarbeitungsverträgen. GitHub stellt die Anmeldung bereit; für dein GitHub-Konto gilt die Datenschutzerklärung von GitHub. Updates werden von GitHub Releases geladen.

### Rechtsgrundlage

- **Leaderboard und Gruppen:** Art. 6 Abs. 1 lit. b DSGVO. Das Speichern und Anzeigen deines Anzeigenamens, Benutzernamens, deiner Summen und deines Platzes sowie deiner Gruppen ist die Leistung, die du mit dem Beitritt anforderst; du beendest sie jederzeit mit **Austreten …**. Die Profilbilder, die die App von GitHub lädt, gehören zu dieser Rangliste.
- **Name und E-Mail-Adresse aus GitHub:** Das Leaderboard nutzt sie nicht; Supabase Auth speichert sie, weil GitHub sie bei der Anmeldung übergibt. Art. 6 Abs. 1 lit. f, unser berechtigtes Interesse an einer Anmeldung über GitHub statt eines eigenen Kontosystems.
- **Report-Limit, Zähler für Beitrittsversuche und die Sicherheitsprüfungen dahinter:** Art. 6 Abs. 1 lit. f, unser berechtigtes Interesse, das Leaderboard vor Manipulation und Überlastung zu schützen.
- **Server-Logs bei Supabase und Vercel:** Art. 6 Abs. 1 lit. f, unser berechtigtes Interesse an Betrieb und Sicherheit von Server und Website.
- **Update-Prüfung:** Sie läuft direkt von deinem Mac zu GitHub, wir erhalten daraus nichts. Art. 6 Abs. 1 lit. f, unser Interesse, Sicherheits- und Fehlerkorrekturen auszuliefern; du kannst sie abschalten.

Die Teilnahme am Leaderboard ist weder gesetzlich noch vertraglich vorgeschrieben. Trittst du nicht bei, funktioniert die App genauso, nur ohne Leaderboard. Es gibt keine automatisierte Entscheidungsfindung und kein Profiling.

### Übermittlungen außerhalb der EU

Datenbank, Anmeldung und Backups des Leaderboards liegen in der Supabase-Region eu-west-1 (AWS, Irland), und Supabase speichert seine Logs in der EU. Vertragspartner ist Supabase Pte. Ltd. in Singapur, unterstützt von Supabase, Inc. in den USA; Übermittlungen an sie stützen sich auf die EU-Standardvertragsklauseln im Auftragsverarbeitungsvertrag von Supabase (Art. 46 Abs. 2 lit. c DSGVO).

Vercel Inc. (USA) ist unter dem EU-U.S. Data Privacy Framework zertifiziert; Übermittlungen an Vercel stützen sich daher auf den Angemessenheitsbeschluss der EU-Kommission dazu (Art. 45 DSGVO); der Auftragsverarbeitungsvertrag von Vercel enthält zusätzlich die EU-Standardvertragsklauseln.

GitHub (USA), über das du dich anmeldest und von dem Updates und Profilbilder geladen werden, ist ebenfalls unter dem EU-U.S. Data Privacy Framework zertifiziert und verarbeitet diese Daten als eigener Verantwortlicher nach GitHubs Datenschutzerklärung.

### Deine Rechte

Du hast das Recht auf Auskunft über deine Daten (Art. 15 DSGVO), auf Berichtigung (Art. 16), Löschung (Art. 17), Einschränkung der Verarbeitung (Art. 18) und Datenübertragbarkeit (Art. 20). Soweit wir uns auf unser berechtigtes Interesse stützen (Art. 6 Abs. 1 lit. f), kannst du der Verarbeitung aus Gründen, die sich aus deiner besonderen Situation ergeben, widersprechen (Art. 21). Schreib dazu an valentin@paus.works. **Austreten …** in der App löscht dein Konto und deine Leaderboard-Daten sofort (was bleibt und wie lange, steht unter „Austreten und Löschen“ und „Wie lange“).

Außerdem hast du das Recht, dich bei einer Datenschutz-Aufsichtsbehörde zu beschweren. Für uns zuständig ist die Landesbeauftragte für Datenschutz und Informationsfreiheit Nordrhein-Westfalen, Postfach 20 04 44, 40102 Düsseldorf, <https://www.ldi.nrw.de>.

Fragen, Anliegen zu deinen Daten oder Hinweise auf ein Problem: als Issue unter <https://github.com/valentinherrera/tokenmaccer/issues>. Issues sind öffentlich; bitte dort keine personenbezogenen Daten posten. Für alles Private schreib an valentin@paus.works.
