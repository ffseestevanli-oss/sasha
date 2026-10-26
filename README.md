# Sasha

<img width="256" height="256" alt="sasha" src="https://github.com/user-attachments/assets/70827222-2938-48e7-b26e-df9a5c5ad08b" />


**A Music player for Linux, Similar to AIMP, but light on features. It's a non-BS music player with some good features.** A Rust core with a Qt 6 / QML
interface: a frosted-glass player panel on top, your library underneath, sorted into
category tabs, with cover art read from your tags.

## Getting started

1. Build it (below) and open it. Sasha scans your Music folder (`~/Music`) on start.
   Click **Music: ~/Music** in the status bar to pick a different folder.
2. **All Songs → Shuffle all** (or just press **Space**) plays everything shuffled.
3. Double-click a song, an album cover, or a track in an album to play from there.
   Double-click a name in Artists, Album Artists or Genres to play all of their songs.

| Key | Does |
|---|---|
| Space | Play / pause (shuffles the whole library if nothing is loaded) |
| Ctrl+Right / Ctrl+Left | Next / previous |
| Ctrl+F | Search |
| Esc (in search) | Clear search |

Previews: (Know that appearances may differ, as it follows your system's accent color, which can be disabled in settings)
<img width="1688" height="1189" alt="image" src="https://github.com/user-attachments/assets/4ceb46c7-1960-4ae7-8e55-e04cc374af00" />
<img width="1697" height="1196" alt="image" src="https://github.com/user-attachments/assets/eee35b1e-d45b-4bf2-a882-0ef6b8745212" />
<img width="1691" height="1193" alt="image" src="https://github.com/user-attachments/assets/2107ccaf-a049-4062-aaf9-0f2e58b41dae" />

## What's new in 0.1.7

- **Fast start from a saved library.** The first scan is saved to `~/.local/share/sasha/library.cache`, and later launches load from that file instead of rescanning. The scan itself works the same as before.
  - Sasha scans again on its own only when the music folder changes, or when cached cover art has been cleaned out of `~/.cache`.
- **Rescan & Rebuild Library.** This button, at the bottom right, deletes the saved library, scans your music folder again and saves the result. Use it after you edit tags or add albums.
- **Remembers the last song.** Sasha reopens on the last song you played, paused where you left off. Turn on **Settings → Resume playback when Sasha starts** to have it keep playing. The position is saved every 10 seconds while playing, and when you quit.
- **Menu icon fixed.** The menu entry and Dolphin's Open With list now point at the icon file directly, so the icon shows up.

## What's new in 0.1.6

- **One Sasha at a time.** Launching Sasha again brings the running window to the front instead of opening a second copy.
- **Open files from Dolphin.** Sasha registers itself for audio files and .m3u/.m3u8 playlists, so it shows up under Dolphin's **Open With**. Opened files play in the running window. Folders passed on the command line play every song inside them.
  - Files outside your music folder play too. They don't show up in the library tabs.
  - To make Sasha the default for double-clicks, right-click an audio file in Dolphin and choose **Open With → Other Application…**, pick Sasha and tick "Remember application association", or set it in System Settings → Default Applications → File Associations.

## What's new in 0.1.5

- **Shuffle a genre.** On the Genres tab, pick a genre and press **Shuffle all**, next to the search box, to shuffle every song in it.
- **"More" menu for tabs.** When the window is too narrow for every category tab, the ones that don't fit move into a **More ▾** menu at the end of the tab row. More is underlined when the tab you're on is inside it.

## What's new in 0.1.4

- **Jump to the playing album.** Click the cover art in the banner to open the Albums tab scrolled to that album. The album glows briefly in your accent color. If your search would hide the album, the search is cleared first.
- **Plain arrow cursor.** Clickable things no longer switch to the hand pointer.

## What's new in 0.1.3

- **Tuneful is now Sasha.** The name changes everywhere. Your settings and playlists move over on first launch, from `~/.local/share/tuneful/playlists` to `~/.local/share/sasha/playlists`. The build script reuses the old `tuneful-build` container and replaces the old Tuneful menu entry with Sasha's. Environment variables are now `SASHA_*` (they used to be `TUNEFUL_*`).
- **Minigun app icon.** There are three designs. C (tilted, spinning) is the default, and you can switch to A (bold outline) or B (flat on accent) under Settings → App icon. Plasma may take a moment to pick up the new icon in the menu and task bar.
- **Folders has one view.** The song list always includes every subfolder, so the "Include subfolders" switch is gone.
- **Seek-bar visualizer rests when idle.** Its bars hide while playback is stopped or paused.

## What's new in 0.1.2

- **Playlists tab:** make, rename and delete playlists (deleting moves the file to the trash).
  Drag songs onto a playlist from any tab, drag rows to reorder, and press Delete or drag
  rows out of the list to remove them. Playlists are plain `.m3u8` files in
  `~/.local/share/sasha/playlists`, so other players can open them too.
- **Folders tab:** your music folder as a tree, with song counts and cover thumbnails. Click a
  folder to see its songs, flip **Include subfolders** to list everything below it, and use
  Play / Shuffle (or double-click a folder in the tree) to play it all.
- **Right-click menu** on songs everywhere: Play, Play next, Add to playlist (or a new one),
  and Open file location (shows the file selected in Dolphin). Folders get the same menu.
- **Multi-select:** Ctrl+click, Shift+click and Ctrl+A. The menu and dragging act on the
  whole selection.
- The player panel now follows the exact title-bar colours Breeze uses (the colour scheme's
  Header colours, active and inactive).
- "Play in order" is gone from All Songs; Shuffle all stays.

| Key | Does |
|---|---|
| Ctrl+A | Select all songs in the list |
| Delete | Remove the selected songs from the open playlist |

## What's new in 0.1.1

- **Visualizer styles:** Small (the box in the corner), **Seek bar** (the bars *are* the seek
  bar: played bars in the accent, click or drag to seek), **Full panel** (bars behind the whole
  player panel), or Off. Pick one in Settings, or click the small visualizer to cycle.
- **Inactive windows:** the player panel fades to Plasma's inactive title bar colour when the
  window loses focus, and the accent controls soften, matching the title bar.
- The visualizer stops while the window is minimised and runs at half rate in the background.

## What's in 0.1.0

- **Library:** scans a folder, reads tags from MP3 (ID3v1/v2), FLAC, Ogg Vorbis, Opus,
  M4A/AAC/ALAC and WAV, and groups songs into albums. Other formats (WavPack, APE, WMA,
  AIFF...) still play and are listed by file name.
- **Cover art** from embedded pictures, or `cover.jpg` / `folder.jpg` / `front.png` (etc.)
  in the album's folder. Embedded covers are saved once to `~/.cache/sasha/sasha/covers`.
- **Tabs:** All Songs (sortable by any column), Artists, Album Artists, Albums, Genres.
- **Playback** through Qt Multimedia (FFmpeg or GStreamer backend, PipeWire/PulseAudio
  output): queue, shuffle, repeat all / repeat one, seek, volume.
- **Spectrum analyser** in the player panel (needs Qt 6.8 or newer).
- **KDE integration:** the player panel matches your Plasma title bar colour (or the accent
  colour if it can't be read), and both follow colour-scheme changes live.
- **Settings** (status bar): turn the panel colour off, or try the **experimental**
  frosted-glass player panel (KWin's blur; needs KF6 WindowSystem at build time). The
  frosted panel can turn see-through for a moment while the window is being moved.
- Remembers your music folder, volume, shuffle, repeat, last tab and settings.

> First build: the Qt side was written without a Qt install to compile against, so if the
> build stops with a C++ or QML error, send `Built Binaries/build.log` (or the terminal
> output when you run `./sasha`) and it'll get fixed.

## Building

The easy way is to drop **Build Sasha.sh** into this folder and double-click it. It
checks for the tools it needs, offers to install what's missing, builds the program, and
writes a launcher into `Built Binaries`. On immutable systems such as Bazzite, Silverblue,
or SteamOS, it builds inside a container.

To build by hand, you need Rust, a C++ compiler and these Qt 6 packages:

| Distro | Package(s) |
|---|---|
| Arch / EndeavourOS / CachyOS | `qt6-base qt6-declarative qt6-multimedia qt6-multimedia-ffmpeg` |
| Fedora KDE | `qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel` |
| Kubuntu / Debian / KDE neon | `qt6-base-dev qt6-base-dev-tools qt6-declarative-dev qt6-multimedia-dev` plus `qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-templates qml6-module-qtquick-window qml6-module-qtqml-workerscript qml6-module-qtqml-models` |
| openSUSE | `qt6-base-devel qt6-declarative-devel qt6-multimedia-devel qt6-declarative-imports` |

Optional, for the frosted-glass header: KF6 WindowSystem (`kwindowsystem` on Arch,
`kf6-kwindowsystem-devel` on Fedora and openSUSE, `libkf6windowsystem-dev` on Debian/Kubuntu).

```sh
cargo run --release
```

`build.rs` finds Qt through pkg-config, then `qmake6`/`qmake`; point it at a specific Qt with
`QMAKE=/path/to/qt6/bin/qmake`, or at moc with `MOC=/path/to/moc`. There are no crate
dependencies, so the build works offline.

### Handy environment variables

| Variable | Effect |
|---|---|
| `SASHA_QML=/path/to/qml/main.qml` | Load the window from that file instead of the copy built into the program, so you can tweak the layout without rebuilding |
| `SASHA_NO_BLUR=1` | Turn off the blur at run time |
| `SASHA_NO_KF6=1` | Build without KF6 WindowSystem even if it's installed |
| `SASHA_SKIP_QT=1` | Skip the Qt part of the build (for `cargo test` on machines without Qt) |

### Troubleshooting

- **"module QtQuick.Controls is not installed"** (or similar) when starting: the Qt Quick
  QML modules are missing. Install the Debian/Kubuntu `qml6-module-*` packages above, or
  `qt6-declarative-imports` on openSUSE.
- **No sound / "No QtMultimedia backends found":** install Qt Multimedia's FFmpeg backend
  (`qt6-multimedia-ffmpeg` on Arch; it ships with `qt6-qtmultimedia` on Fedora).
- **The frosted-glass setting is greyed out or does nothing:** it needs KF6 WindowSystem at
  build time and KWin's Blur effect turned on (System Settings → Window Management →
  Desktop Effects → Blur).

## Layout

```
build.rs            finds Qt 6 (+ moc, + optional KF6), compiles cpp/ into a static lib
assets/sasha.svg  the app icon
cpp/host.cpp        QApplication + QML engine, loads the window
cpp/player.h/.cpp   the object QML talks to: playback, library lists, queue, spectrum,
                    accent colour and blur
qml/main.qml        the whole window (built into the binary)
src/main.rs         C ABI bridge between Qt and the Rust core
src/library.rs      folder scan, album grouping, cover art, hand-off to Qt (+ tests)
src/queue.rs        play queue, shuffle, repeat (+ tests)
src/spectrum.rs     FFT and spectrum bands (+ tests)
src/tags/           ID3, FLAC, Ogg/Opus, MP4 and WAV readers (+ tests)
```

Run the tests with `SASHA_SKIP_QT=1 cargo test`.

## Roadmap

1. ~~Library, albums view with cover art, category tabs, shuffle all, KDE accent and blur~~
2. ~~Saved playlists, folder view, song menu~~; a Now Playing queue panel
3. Tag editing (from the Folders tab)
4. MPRIS (media keys, Plasma's media controls, KDE Connect)
5. Gapless playback, ReplayGain, equalizer
6. Watching the music folder for changes
7. Mini player
