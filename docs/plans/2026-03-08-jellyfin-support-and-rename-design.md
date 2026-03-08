# Montage: Jellyfin Support & Rename Design

**Date:** 2026-03-08
**Status:** Approved

## Summary

Add Jellyfin as a second media provider to PlexSaver, and rename the project to **Montage** to reflect its multi-provider nature.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Jellyfin auth | Username/password | Standard Jellyfin client pattern, no admin access needed |
| Multi-provider mode | Either/or | Simpler state management; protocol abstraction makes upgrade easy later |
| Config UI | Segmented control (Plex / Jellyfin) | Matches macOS conventions, makes mutual exclusivity obvious |
| Project name | Montage | Describes the crossfade grid mechanic perfectly |
| Rename strategy | Clean break | New bundle ID, no migration of old prefs/cache |
| Architecture | Protocol abstraction | Clean separation, testable, extensible |
| Image source options | Same as Plex (fanart/posters/mixed) | Consistent UX across providers |

## Architecture

### Protocol Layer

```swift
struct MediaItem {
    let id: String
    let title: String
    let year: Int?
    let artPaths: [ImageSourceType: String]
}

struct MediaLibrary {
    let id: String
    let name: String
    let type: String  // "movies", "tvshows", "music"
}

protocol MediaProvider: Actor {
    var serverName: String { get }
    func fetchLibraries() async throws -> [MediaLibrary]
    func fetchItems(libraryId: String) async throws -> [MediaItem]
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage
}

protocol MediaAuthenticator {
    func authenticate() async throws -> (any MediaProvider)
    func testConnection() async throws -> Bool
}
```

### Jellyfin Provider

- **JellyfinAuth** implements `MediaAuthenticator`
  - POST `/Users/AuthenticateByName` with username/password
  - Returns `AccessToken` and `UserId`
  - All requests use `Authorization: MediaBrowser Client="Montage", Device="Mac", DeviceId="{uuid}", Version="{ver}", Token="{token}"`

- **JellyfinProvider** implements `MediaProvider`
  - `fetchLibraries()` → `GET /Users/{userId}/Views`
  - `fetchItems(libraryId:)` → `GET /Users/{userId}/Items?ParentId={id}&Recursive=true`
  - `fetchImage(path:width:height:)` → `GET {path}?maxWidth={w}&maxHeight={h}&format=Jpg` (unauthenticated)
  - Image path mapping: `.poster` → `/Items/{id}/Images/Primary`, `.fanart` → `/Items/{id}/Images/Backdrop`

### Plex Provider

- Wraps existing `PlexClient` + `PlexAuth` into `PlexProvider` conforming to `MediaProvider`
- `PlexAuthenticator` conforming to `MediaAuthenticator`
- Internal implementation unchanged

### Configuration UI

Segmented control swaps auth section:

```
┌──────────┐ ┌───────────┐
│   Plex   │ │ Jellyfin  │  ← Segmented control
└──────────┘ └───────────┘

Plex: [Sign In with Plex] button (existing browser PIN flow)
Jellyfin: Server URL + Username + Password fields + [Connect] button

Shared: Library selection, image source, grid size, rotation interval
```

### Preferences Changes

New fields:
- `providerType: ProviderType` (.plex / .jellyfin)
- `jellyfinServerURL: String`
- `jellyfinUsername: String`
- `jellyfinAccessToken: String`
- `jellyfinUserId: String`

Password is not persisted — only the access token is stored after successful auth.

### Rename Scope

| Item | Old | New |
|------|-----|-----|
| Bundle ID | `com.plexsaver.PlexSaver` | `com.montage.Montage` |
| Product | PlexSaver.saver | Montage.saver |
| Main class | `PlexSaverView` | `MontageView` |
| Main file | `PlexSaverView.swift` | `MontageView.swift` |
| Test target | SaverTest | MontageTest |
| Cache path | `~/Library/Caches/com.plexsaver.PlexSaver/` | `~/Library/Caches/com.montage.Montage/` |
| Logger | `com.plexsaver.PlexSaver` | `com.montage.Montage` |

Files that keep their names (accurate as provider-specific code):
- `PlexClient.swift`, `PlexAuth.swift`, `PlexModels.swift`

### Data Flow

```
Config Sheet → Preferences (providerType, credentials)
    → MontageView creates provider based on providerType
    → MediaProvider (PlexProvider or JellyfinProvider)
    → [MediaItem] fed to ImagePool (provider-agnostic)
    → 3-tier cache (memory → disk → network)
    → GridManager → GridCells → CALayer render
```

The three-tier cache (ImageCache, DiskCache) is entirely provider-agnostic — no changes needed.
