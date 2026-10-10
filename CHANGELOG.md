# Changelog

## 0.2.10 (2026-10-10)

- A little more room above Continue Watching in the Watch tab.

## 0.2.9 (2026-10-10)

- The Help menu links to Joey's website and its new [legal notice](https://joey.kimiyu.ch/legal).
- **Help → Acknowledgements** lists the open-source libraries inside Joey, with their versions, licenses and
  where to get their source code.

## 0.2.8 (2026-10-10)

- Continue Watching cards show each video's quality and file type, like the list below them.

## 0.2.7 (2026-10-10)

- **A tidier video list.** Release names like `Show.Name.S01E02.1080p.WEB…` show as "Show Name · S01E02",
  with episode titles where the file name has them. Episodes are grouped by show, in order, with movies in between.
- Each video shows its quality and file type, when it was added, and how much is left if you stopped partway
  through. Right-click to start one from the beginning.
- Continue Watching, the Dock menu and the menu bar item use the cleaned-up names too.
- Download and upload speeds moved to a status bar at the bottom of the main window, with how many torrents
  are downloading and seeding.

## 0.2.6 (2026-10-10)

- The main window's tabs are now called Download and Watch.

## 0.2.5 (2026-10-10)

- **Videos in the main window.** Switch between Downloads and Videos at the top of the window, or with ⌘1 and
  ⌘2. Joey opens on whichever you used last.
- **Continue Watching.** The Videos tab starts with what you stopped partway through, with how much is left.
- The Dock icon's menu and the menu bar item list your unfinished videos too, one click to pick up where you left off.

## 0.2.4 (2026-10-10)

- ⌘F switches the player to full screen and back, in addition to F.

## 0.2.3 (2026-10-10)

- **Video list in the player.** Pick a video folder in Settings, then open the list from the player's controls
  (or ⌘L): every video in the folder and its subfolders, searchable, with where you left off. Click one to play
  it in the same window.
- The player is always dark, so its menus and the list stay readable over the video.

## 0.2.2 (2026-10-10)

- The player has buttons to skip back and forward 10 seconds.

## 0.2.1 (2026-10-09)

- The screen no longer dims or goes to sleep while a video is playing.

## 0.2 (2026-10-09)

- **Built-in video player.** Play finished downloads from the inspector or the right-click menu, or open any
  video with File → Open Video… or Open With in Finder.
- Plays MKV and most other formats with hardware decoding, including embedded and external subtitles and
  multiple audio tracks.
- Picks up where you left off, plays full screen, and works with the media keys and Now Playing.
- Smooth playback on ProMotion and other high refresh rate displays.
- Joey is now licensed under the GPLv3, since the player is built on mpv and FFmpeg.

## 0.1 (2026-10-09)

- **First release.** A small, native BitTorrent client for macOS.
- Magnet links and .torrent files, from the browser, Finder or drag and drop.
- Choose which files to download, and download in order.
- Seeding limits by ratio or time, and speed limits.
- Menu bar item with live speeds; keeps seeding when the window is closed.
- Notifications, keeps the Mac awake while downloading, and automatic updates.
