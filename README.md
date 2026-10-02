# Montage

Montage is a macOS screensaver that displays a rotating mosaic of artwork from Plex or Jellyfin. It supports macOS 15 and later, on Apple silicon and Intel.

![Montage running with title reveal](docs/screenshots/montage-grid.png)

## Features

- Browser sign-in and server discovery for Plex; username/password sign-in for Jellyfin.
- Backgrounds, posters, or both, with selectable libraries for each account and server.
- Adjustable grid, display-aware column fitting, progressive artwork loading, and optional title reveal.
- Connection-scoped artwork caches with image-size variants and offline playback.
- Prompt first images, bounded background downloads, and automatic recovery from temporary outages.
- Multiple-display coordination to keep the same title from appearing twice.
- Options with a layout preview, labelled controls, cache management, and private diagnostic summaries.

## Installation

Download and unzip `Montage.saver.zip` from [Releases](https://github.com/jeffWelling/plex-screensaver-for-mac/releases), then double-click `Montage.saver`. Select Montage in **System Settings → Screen Saver** and open **Options…** to connect your server.

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
| Delay between changes | 5 seconds | Two to thirty seconds |
| Artwork | Backgrounds | Backgrounds, Posters, or Both |
| Title reveal | On | Reveal the outgoing title before changing artwork |
| Libraries | All | Explicit selection is stored per connection; selecting none shows the setup message |

Changes are saved together through **Apply and Close**. Saved connections refresh their available libraries when Options opens. Use **Test / Refresh** after changing server availability or library contents.

### Jellyfin

Enter the complete server URL, including any reverse-proxy base path, for example `https://media.example/Jellyfin`. Server paths retain their case. HTTPS is recommended; Options explains when an explicitly selected HTTP connection sends credentials without encryption.

The password is used only for authentication and is not saved. Access tokens are stored in Keychain. Credential errors are reported explicitly; Montage does not silently fall back to saving tokens in plaintext preferences.

### Plex

Sign in through the browser and select a server. Discovery checks advertised secure connections for reachability. Montage can retry another advertised HTTPS connection for the same physical server after a network failure; it does not silently downgrade an HTTPS connection to HTTP.

## Cache and offline playback

Artwork is stored under `~/Library/Caches/com.montage.Montage/artwork-v2/`, separated by provider, server, and account. JPEG records retain titles, years, library identity, artwork revisions, requested pixel dimensions, and download dates.

Available cached artwork appears during startup and can continue rotating offline. A seven-day freshness interval controls artwork revalidation; accessing a cached image does not make it fresh, and stale artwork remains usable offline. The disk cache has a 512 MiB limit per connection. Decoded image caching has a shared 96 MiB process budget, pending artwork has a 32 MiB budget per display, and prepared images are limited to eight megapixels. Visible images are a separate working set. Downloads also have explicit byte limits and deadlines.

**Clear cache** removes the current connection's artwork. **Refresh artwork** clears it and checks the connection. Signing out removes the relevant saved connection and cached content. Old account-unscoped cache data is retained but not used by this version, so the first start after upgrading can download artwork once again.

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

**No server configured:** Open Options and sign in with Plex or Jellyfin.

**No libraries selected:** Enable All libraries or select at least one discovered library, then apply.

**Artwork is unavailable:** Check the server address and credentials with Test / Refresh. Existing cached artwork continues offline; temporary failures are retried.

**Credential storage failed:** Read the Keychain error shown in Options and use Unlock saved credentials after unlocking macOS. A failed sign-out is reported so it is not mistaken for a completed logout. The screensaver uses noninteractive credential reads; sharing access between Options and Apple’s playback host still requires validation in those actual hosts.

**Unexpected artwork or cache size:** Use the current connection's Clear Cache or Refresh Artwork controls. Copy Diagnostics provides versions and aggregate status without credentials, addresses, or media titles.

**Montage does not appear in System Settings:** Confirm `Montage.saver` exists in `~/Library/Screen Savers/` and reopen System Settings. Avoid installing multiple copies of the same screensaver.

## License

[GNU General Public License v3.0](LICENSE).

## Created by

The initial project was created with [Claude Code](https://claude.ai/claude-code). Montage is maintained with human review and AI-assisted development.
