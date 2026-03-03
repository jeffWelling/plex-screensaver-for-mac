# PlexSaver — Plex Grid Screensaver for macOS

A macOS screensaver that connects to your Plex Media Server and displays a rotating mosaic of media artwork. Inspired by the classic Kodi grid screensaver — the "guess the movie" experience.

## Features

- **Plex OAuth sign-in** — Browser-based authentication, no manual token needed
- **Server auto-discovery** — Finds your Plex servers automatically after sign-in
- **Configurable grid** — Adjustable rows, columns, and rotation interval
- **Crossfade transitions** — Smooth per-cell staggered image transitions
- **Multiple image sources** — Fanart, posters, or mixed
- **Library selection** — Choose which Plex libraries to display
- **Status feedback** — Loading and error messages shown on screen

## Installation

### From Release

1. Download `PlexSaver.saver.zip` from [Releases](https://github.com/jeffWelling/plex-screensaver-for-mac/releases)
2. Unzip and double-click `PlexSaver.saver` to install
3. Open **System Settings → Screen Saver** and select PlexSaver
4. Click **Options...** to sign in with Plex and configure the grid

### Build from Source

Requires Xcode 16+ and macOS 15+.

```bash
git clone https://github.com/jeffWelling/plex-screensaver-for-mac.git
cd plex-screensaver-for-mac
xcodebuild -scheme PlexSaver -configuration Release build
```

The built `.saver` bundle will be in `~/Library/Developer/Xcode/DerivedData/PlexSaver-*/Build/Products/Release/`.

Double-click the `.saver` file to install, or copy it to `~/Library/Screen Savers/`.

### Development

Use the SaverTest app target for development — it runs the screensaver in a regular window without needing to install:

```bash
xcodebuild -scheme SaverTest -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/PlexSaver-*/Build/Products/Debug/SaverTest.app
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Grid Rows | 3 | Number of rows in the image grid |
| Grid Columns | 4 | Number of columns in the image grid |
| Rotation Interval | 5s | Seconds between image transitions per cell |
| Image Source | Fanart | Fanart (backgrounds), Posters, or Mixed |
| Libraries | All | Which Plex libraries to pull images from |

## Architecture

- `ScreenSaverView` subclass with `CALayer`-based grid rendering
- Dual-layer crossfade pattern per cell (GPU-accelerated)
- Actor-based `ImagePool` with background prefetch and LRU cache
- Plex API via async/await `URLSession`
- SwiftUI configuration sheet hosted in `NSHostingController`

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

## Created By

This project was created entirely by [Claude Code](https://claude.ai/claude-code) with Anthropic's Claude Opus 4.6.
