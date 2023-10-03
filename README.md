# mpvMatroska

mpvMatroska is a Lua script for mpv which almost turns mpv into a full Matroska player.

The project is under construction and not much is working yet and a lot will change over time.
Nevertheless, there are already some working Matroska features.

## mpvMatroska development

To test the Matroska features I use my [Matroska-Playback](https://github.com/hubblec4/Matroska-Playback) repo.

## Installation

mpvMatroska uses some other Lua modules.
But to keep everything simple, mpvMatroska uses the `mpv folder system` for scripts that consist of several modules.

All you have to do is copy the mpvMatroska folder into the mpv-scripts folder.

It is also possible to use mpvMatroska as a single script, in which case the required modules must be available in mpv `~~/script-modules/` folder.

### uosc

mpvMatroska uses the GUI from [uosc](https://github.com/tomasklaen/uosc) to display lists and buttons.
mpvMatroska still works without uosc, but then you don't have any selection lists.

#### Test version

For the moment, a [test version](https://gleitz.info/index.php?attachment/100237-mpvmatroska-zip/) can be downloaded here.

## working Matroska features

- Hard-Linking
- Nested chapters
- Ordered chapters
- Nested-Ordered chapters
- Linking chapters (with chapter duration)
- Linked-Edition chapters
- Multiple chapter names
- Multiple edition names
- Video rotation (with `ProjectionPoseRoll` element)

## mpvMatroska features

- Automatic switching of edition and chapter names when the audio or subtitle track is changed
- Improved title display: the current edition name is appended to the file name
- Correct edition list: the standard short-cut "E" is processed internally using its own switching method
- Video rotation: with the Matroska Tags (not official in the Matroska specifications)
- Matroska Content-Grouping: not yet officially included in the Matroska specifications

### Matroska Content-Grouping

This Matroska feature is about grouping the content in a Matroska file in a meaningful way.
The content is all track types as well as the editions/chapters.
This is the basic basis of Haali TRACKSETEX.
The Matroska Attachments could be used as additional content, for example to specifically load a font for a subtitle.

The hotkey `g` is available to switch through existing content groups.
Furthermore, a freely selectable hotkey can be set up in the mpv `input.conf` using the `script-message-to` system.

To switch the content groups with the "k" key, the following line is used.

```text
k script-message-to mpvMatroska cycle-contentgroups
```

If uosc is installed you can open the selection menu with the hotkey `ALT+g`.
You can also assign your own hotkey to open the selection menu.

```text
G script-message-to mpvMatroska open-contentgroups
```

You can also install your own button in the control menu in uosc.
To do this you have to adapt the line `controls=` in `uosc.conf`.
I use the following code for this.

```text
command:hub:script-binding mpvMatroska/open-contentgroups?Content-Groups
```

### Matroska Editions

Currently mpv doesn't handle multiple editions correctly and even creates an incorrect list when linking chapters come into play.
Therefore, the mpv internal method should not be used to switch editions.

You can also assign a separate hotkey to switch between editions.

```text
your-key script-message-to mpvMatroska cycle-editions
```

A separate editions button can (and should) be created in the uosc control menu.
To do this you have to adapt the line `controls=` in `uosc.conf`.

```text
command:bookmarks:script-binding mpvMatroska/open-editions?Editions
```
