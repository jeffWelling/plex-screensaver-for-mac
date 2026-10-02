# Montage

Montage is a macOS screensaver that displays a rotating mosaic of artwork from Plex, Jellyfin, or a local artwork folder. It supports macOS 15 and later, on Apple silicon and Intel.

![Montage running with title reveal](docs/screenshots/montage-grid.png)

## Features

- Browser sign-in and server discovery for Plex; username/password sign-in for Jellyfin.
- Backgrounds, posters, or both, with selectable libraries for each account and server.
- Mosaic, Poster Wall, and Calm presets; adjustable grids, display-aware columns, framing choices, and title reveal.
- Connection-scoped artwork caches, offline readiness, and cancellable artwork preparation.
- Prompt first images, bounded background downloads, and automatic recovery from temporary outages.
- Multiple-display coordination and bounded recent-title history to improve variety across sessions.
- Genre, collection, favorite, and watched-status filters according to each server's capabilities.
- Read-only local folder access, automatic power and thermal adaptation, and suspension while displays sleep.
- Options with a live artwork preview, Cancel, advanced display controls, and private diagnostic summaries.

## Installation

Download and unzip `Montage.saver.zip` from [Releases](https://github.com/jeffWelling/plex-screensaver-for-mac/releases), then double-click `Montage.saver`. On current macOS, open **System Settings → Wallpaper → Screen Saver… → Custom**, expand **Other → Show All**, scroll down and select **Montage**, then open **Options…** to connect your server. On macOS 15, use the **Screen Saver** settings pane.

### Build from source

Requires Xcode 16 or later and macOS 15 or later.

```sh
git clone https://github.com/jeffWelling/plex-screensaver-for-mac.git
cd plex-screensaver-for-mac
make test
make install
```

`make build` performs an incremental universal Release build in `build/xcode`. Installation validates the exact bundle, verifies the staged copy, and replaces `~/Library/Screen Savers/Montage.saver`. A previous stable installation is retained as the hidden `.Montage-backups/Previous.saver` recovery copy. Older versioned Montage bundles are removed only when their bundle identifier matches Montage and the replacement has been installed successfully. Reopen System Settings after an update.

`make version` reports source and installed versions. `make uninstall` removes only identified Montage bundles. Local builds are unsigned by default; they are distinct from signed distribution releases.

## Configuration

| Setting | Default | Behavior |
|---------|---------|----------|
| Rows | 3 | One to ten rows |
| Columns | 4 | One to ten columns, or fitted to each display |
| Delay between changes | 5 seconds | Two to 120 seconds |
| Framing | Fill frame | Crop to fill cells, or show full artwork against black |
| Transition | 1 second | 0.2 to 3 seconds, adjusted for accessibility and power |
| Artwork | Backgrounds | Backgrounds, Posters, or Both |
| Title reveal | On | Reveal the outgoing title before changing artwork |
| Libraries | All | Explicit selection is stored per connection; selecting none shows the setup message |

Choose **Mosaic**, **Poster Wall**, or **Calm** for a presentation preset. Presets retain the connection, selected libraries, and content filters. Expand Advanced for individual layout, timing, and title controls. Both artwork chooses backgrounds for wide cells and posters for tall cells, falling back to another available image when needed.

**Live Preview** shows the actual screensaver inside Options using the draft connection and display choices. It does not save preferences or credentials, or contribute to the installed screensaver's recent-title history. Hide the preview when finished; applying or canceling stops it automatically.

Changes are saved together through **Apply and Close**. **Cancel**, Escape, and closing the Options window discard unsaved display and connection changes. Sign-out and disconnect are staged until Apply. Cache-management actions are separate operations; Cancel does not undo artwork already downloaded or deliberately cleared.

Saved connections refresh their available libraries when Options opens. Use **Test / Refresh** after changing server availability or library contents. Filters are saved separately for each connection: Plex supports genres, collections, and unwatched titles; Jellyfin supports genres, favorites, and unwatched titles. Values within one category are alternatives; separate enabled categories must all match. Unwatched Plex series include partly watched series. Unknown watch or favorite status does not qualify for an enabled filter.

### Jellyfin

Enter the complete server URL, including any reverse-proxy base path, for example `https://media.example/Jellyfin`. Server paths retain their case. HTTPS is recommended; Options explains when an explicitly selected HTTP connection sends credentials without encryption.

The password is used only for authentication and is not saved. Access tokens are stored in Keychain. Credential errors are reported explicitly; Montage does not silently fall back to saving tokens in plaintext preferences.

### Plex

Sign in through the browser and select a server. Discovery checks advertised secure connections for reachability. Montage can retry another advertised HTTPS connection for the same physical server after a network failure; it does not silently downgrade an HTTPS connection to HTTP.

### Local artwork folder

Choose **Local folder** as the artwork source, then select a folder using the macOS folder picker. Supported images in subfolders are included; hidden files, packages, and symbolic links are skipped. Filename captions omit the extension. Folder access is stored as a read-only security-scoped bookmark, and artwork never requires a media-server account. If the folder moves or permission becomes unavailable, choose it again in Options.

Local files follow the same bounded decoder and cache budgets as server artwork. Separate files retain their identity even when they have the same name. A single image file is limited to 16 MiB; folders with more than 50,000 visited entries require choosing a smaller folder.

## Cache and offline playback

Artwork is stored under `~/Library/Caches/com.montage.Montage/artwork-v2/`, separated by provider, server, and account. JPEG records retain titles, years, library identity, artwork revisions, requested pixel dimensions, and download dates.

Available cached artwork appears during startup and can continue rotating offline. A seven-day freshness interval controls artwork revalidation; accessing a cached image does not make it fresh, and stale artwork remains usable offline. The disk cache has a 512 MiB limit per connection. Decoded image caching has a shared 96 MiB process budget, pending artwork has a 32 MiB budget per display, and prepared images are limited to eight megapixels. Visible images are a separate working set. Downloads also have explicit byte limits and deadlines.

**Refresh artwork** checks the current catalog and updates saved metadata while preserving working artwork. A failed request does not erase the offline collection. **Clear cache** deliberately removes the current connection's artwork. Applying a staged sign-out removes the relevant saved connection and cached content.

Offline readiness counts valid cached titles prepared for the draft libraries, artwork choice, filters, and requested layout. Original image resolution and the decoder's eight-megapixel limit can reduce detail on very large displays; smaller cached variants remain usable as an offline fallback. Multiple image-size variants count as one title. **Prepare offline artwork** downloads up to 200 eligible titles per pass, prioritizing missing artwork, and can be canceled. Repeat to prepare more; the 512 MiB cache limit still applies, so large collections may not fit in full. The completion status and readiness count report what is actually retained. Downloading is suspended on display sleep or severe thermal pressure.

Recent-title history is scoped to each connection, stores hashed title identities, and is bounded. It influences selection rather than forbidding repeats, so small libraries can keep rotating. Power adaptation reduces prefetch and rotation under Low Power Mode or thermal pressure; severe pressure uses cached artwork, and critical pressure pauses rotation. Old account-unscoped cache data is retained but not used by this version, so the first start after upgrading can download artwork once again.

## Development

SaverTest runs Montage in a regular window with sample artwork and isolated settings, credentials, and cache by default:

```sh
make build SCHEME=SaverTest CONFIG=Debug
open build/xcode/Build/Products/Debug/SaverTest.app
```

Use `-MontageUseInstalledSettings` explicitly when debugging the installed server configuration. The development interface can simulate latency and failures without contacting a live server.

```sh
make test
log stream --predicate 'subsystem CONTAINS "montage" OR subsystem CONTAINS "Montage"' --level debug
```

Tests cover lifecycle cancellation, reservation ownership, cache coordination and limits, library/account isolation, settings validation, provider requests, pagination, authentication, safe endpoint fallback, and artwork decoding. Network tests use fixtures and do not contact Plex or Jellyfin accounts.

## Release validation

`Version.xcconfig` holds the shared marketing version and build number for both targets. `make bump-patch`, `make bump-minor`, and `make bump-major` update it consistently.

CI builds a universal Release screensaver, verifies both architectures, builds SaverTest, and runs tests with complete Swift concurrency checking on macOS 15 and 26. CI retains a clearly labelled unsigned artifact.

Signed distribution requires a Developer ID Application identity and an existing `notarytool` Keychain profile:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notary-profile" \
make release
```

This explicit release command signs with hardened runtime, submits to Apple's notarization service, staples the accepted ticket, and produces `build/release/Montage.saver.zip`. No credentials are embedded in repository files.

Before distributing a release, check real host behavior on both supported macOS generations:

- System Settings thumbnail and full preview; Options sheet opening, applying, and reopening.
- Screensaver activation, lock/unlock, and immediate stop/start or re-entry.
- One and multiple monitors, Retina/non-Retina scale changes, and display resizing.
- Small and empty libraries, offline startup, server recovery, and expired credentials.
- Keychain access while locked and unlocked, with unavailable access reported without a runtime prompt.
- Reduce Motion, Reduce Transparency, Increase Contrast, keyboard navigation, and long-session energy and memory use.
- Installation of the signed artifact in a clean account or machine.

Automated builds and SaverTest complement these checks; they do not establish compatibility with the actual System Settings and screensaver hosts.

## Troubleshooting

**No artwork source configured:** Open Options and sign in with Plex or Jellyfin, or choose a local folder.

**No libraries selected:** Enable All libraries or select at least one discovered library, then apply.

**Artwork is unavailable:** Check the server address and credentials with Test / Refresh. Existing cached artwork continues offline; temporary failures are retried.

**Credential storage failed:** Read the Keychain error shown in Options and use Unlock saved credentials after unlocking macOS. A failed sign-out is reported so it is not mistaken for a completed logout. The screensaver uses noninteractive credential reads; sharing access between Options and Apple’s playback host still requires validation in those actual hosts.

**Unexpected artwork or cache size:** Check the selected libraries and filters, use Refresh artwork to update the catalog, or deliberately Clear cache. Copy Diagnostics provides versions and aggregate status without credentials, addresses, or media titles.

**Montage does not appear in System Settings:** Confirm `Montage.saver` exists in `~/Library/Screen Savers/` and reopen System Settings. On current macOS, choose Wallpaper → Screen Saver… → Custom → Other → Show All, then scroll to Montage. Automatic hides the custom gallery. Avoid installing multiple copies of the same screensaver.

**Options does not open after an update:** Close the screensaver picker with Done, quit System Settings, and reopen it so the remote screensaver host loads the updated bundle.

## License

[GNU General Public License v3.0](LICENSE).

## Created by

The initial project was created with [Claude Code](https://claude.ai/claude-code). Montage is maintained with human review and AI-assisted development.
