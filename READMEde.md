# mpvMatroska

mpvMatroska ist ein Lua script für mpv wodurch mpv nahezu in einen vollständigen Matroska Player verwandelt wird.

Das Projekt befindet sich im Aufbau und es funktioniert auch noch nicht viel und vieles wird sich ändern mit der Zeit.
Dennoch gibt es auch schon einige funktionierende Matroska Features.

## mpvMatroska Entwicklung

Zum Testen der Matroska Features nutze ich mein [Matroska-Playback](https://github.com/hubblec4/Matroska-Playback) Repo.

## Installation

mpvMatroska benutzt einige andere Lua Module.
Damit aber alles einfach bleibt nutzt mpvMatroska das `mpv Ordner System` für Scripte die aus mehreren Modulen bestehen.

Alles was man tun muss, ist den mpvMatroska Ordner in den mpv Scripte Ordner kopieren.

Ebenso ist es möglich mpvMatroska auch als Single-Script zu verwenden, wobei dann die benötigten Module im mpv `~~/script-modules/` Ordner vorhanden sein müssen.

### uosc

mpvMatroska nutzt die GUI von [uosc](https://github.com/tomasklaen/uosc) für die Darstellung von Listen und Buttons.
mpvMatroska funktioniert auch weiterhin ohne uosc, allerdings hat man dann keine Auswahllisten.

#### Test Version

Für den moment kann hier eine [Test Version](https://gleitz.info/index.php?attachment/100237-mpvmatroska-zip/) heruntergeladen werden.

## funktionierende Matroska Features

- Hard-Linking
- Verschachtelte Kapitel
- Reihenfolgentreue Kapitel
- Verschachtelte-Reihenfolgentreue Kapitel
- Verknüpfende Kapitel (mit Kapitel Dauer)
- Verknüpfte-Version Kapitel
- Multiple Kapitelnamen
- Multiple Versionsnamen
- Video Rotation (mit `ProjectionPoseRoll` Element)

## mpvMatroska Features

- Automatisches Umschalten der Versions- und Kapitel Namen wenn die Audio- oder Untertitelspur gewechselt wird
- Verbesserte Titel Anzeige: der aktuelle Versionsname wird an den Dateinamen angehängt
- Korrekte Versionen Liste: der Standard Short-Cut "E" wird intern mit einer eigenen Durchschalt-Methode verarbeitet
- Video Rotation: mit den Matroska Tags (nicht offiziell in den Matroska Spezifikationen)
- Matroska Inhaltsgruppierung: noch nicht offiziell in den Matroska Spezifikationen enthalten

### Matroska Inhaltsgruppierung

Bei dieser Matroska Eigenschaft geht es darum den Inhalt in einer Matroska Datei sinnvoll zu gruppieren.
Der Inhalt sind alle Spurtypen sowie die Versionen/Kapitel.
Dies ist die Grundbasis von Haali TRACKSETEX.
Als weiterer Inhalt könnten noch die Matroska Anhänge verwendet werden, um zum Beispiel gezielt eine Schriftart für einen Untertitel zu laden.

Für das Durchschalten vorhandener Inhaltsgruppen ist der Hotkey `g` verfügbar.
Weiterhin kann in der mpv `input.conf` ein frei wählbarer Hotkey eingerichtet werden mittels dem `script-message-to` System.

Um die Inhaltsgruppen mit der Taste "k" umzuschalten wird folgende Zeile verwendet.

```text
k script-message-to mpvMatroska cycle-contentgroups
```

Wenn uosc installiert ist kann man mit dem Hotkey `ALT+g` das Auswahlmenü öffnen.
Ebenso kann ein eigener Hotkey vergeben werden um das Auswahlmenü zu öffnen.

```text
G script-message-to mpvMatroska open-contentgroups
```

Weiterhin kann man in uosc einen eigenen Button im Kontrollmenü einbauen.
Dazu muss man in der `uosc.conf` die Zeile `controls=` anpassen.
Ich nutze dazu folgenden code.

```text
command:hub:script-binding mpvMatroska/open-contentgroups?Content-Groups
```

### Matroska Versionen

Momentan verarbeitet mpv multiple Versionen nicht korrekt und erstellt sogar eine falsche Liste wenn verknüpfende Kapitel ins Spiel kommen.
Daher sollte zum Umschaten der Versionen nicht die mpv interne Methode genutzt werden.

Für das Durchschalten der Versionen kann ebenfalls ein eigener Hotkey vergeben werden.

```text
your-key script-message-to mpvMatroska cycle-editions
```

Im uosc Kontrollmenü kann (und sollte) ein eigener Versionen Button erstellt werden.
Dazu muss man in der `uosc.conf` die Zeile `controls=` anpassen.

```text
command:bookmarks:script-binding mpvMatroska/open-editions?Editions
```
