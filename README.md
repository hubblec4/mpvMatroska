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

#### Test version

For the moment, a [test version](https://gleitz.info/index.php?attachment/100235-mpvmatroska-zip/) can be downloaded here.

## working Matroska features

- Hard-Linking
- Nested chapters
- Ordered chapters
- Nested-Ordered chapters
- Linking chapters (with chapter duration)
- Linked-Edition chapters
- Multiple chapter names
- Multiple edition names

## mpvMatroska features

- Automatic switching of edition and chapter names when the audio or subtitle track is changed
- Improved title display: the current edition name is appended to the file name
- Correct edition list: the standard short-cut "E" is processed internally using its own switching method
