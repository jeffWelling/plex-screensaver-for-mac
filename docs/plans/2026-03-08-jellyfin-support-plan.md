# Montage: Jellyfin Support & Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename PlexSaver to Montage and add Jellyfin as a second media provider via protocol abstraction.

**Architecture:** Define a `MediaProvider` protocol that both `PlexProvider` and `JellyfinProvider` conform to. `ImagePool` becomes provider-agnostic by accepting `any MediaProvider`. Config UI adds a segmented control to switch between Plex and Jellyfin auth flows. Either/or provider selection — not simultaneous.

**Tech Stack:** Swift 5.9+, macOS 15+, ScreenSaver.framework, SwiftUI, Core Animation, URLSession async/await, Swift Actors

**Design doc:** `docs/plans/2026-03-08-jellyfin-support-and-rename-design.md`

---

## Task 1: Rename — File and Class Names

Rename source files and class/struct names from PlexSaver to Montage. This is the foundation for all other work.

**Files:**
- Rename: `PlexSaver/PlexSaverView.swift` → `PlexSaver/MontageView.swift`
- Rename: `SaverTest/SaverTestApp.swift` → `SaverTest/MontageTestApp.swift`
- Rename: `SaverTest/SaverTestContentView.swift` → `SaverTest/MontageTestContentView.swift`
- Rename: `SaverTest/ScreenSaverRepresentable.swift` → `SaverTest/MontageRepresentable.swift`
- Rename: `PlexSaver/Helpers/InstanceTracker.swift` (update class references)

**Step 1: Rename PlexSaverView → MontageView**

Rename the file:
```bash
cd ~/claude/repos/plex-screensaver-for-mac
git mv PlexSaver/PlexSaverView.swift PlexSaver/MontageView.swift
```

In `PlexSaver/MontageView.swift`, replace all occurrences:
- `class PlexSaverView` → `class MontageView`
- `PlexSaverView` → `MontageView` (all references)
- Log messages mentioning "PlexSaver" → "Montage"

**Step 2: Rename SaverTest files**

```bash
git mv SaverTest/SaverTestApp.swift SaverTest/MontageTestApp.swift
git mv SaverTest/SaverTestContentView.swift SaverTest/MontageTestContentView.swift
git mv SaverTest/ScreenSaverRepresentable.swift SaverTest/MontageRepresentable.swift
```

In `SaverTest/MontageTestApp.swift`:
- Rename struct `SaverTestApp` → `MontageTestApp`
- Update `SaverTestContentView()` → `MontageTestContentView()`

In `SaverTest/MontageTestContentView.swift`:
- Rename struct `SaverTestContentView` → `MontageTestContentView`
- Update `ScreenSaverRepresentable()` → `MontageRepresentable()`
- Update window title to "Montage Test"

In `SaverTest/MontageRepresentable.swift`:
- Rename struct `ScreenSaverRepresentable` → `MontageRepresentable`
- Update `PlexSaverView` → `MontageView` references

**Step 3: Update InstanceTracker**

In `PlexSaver/Helpers/InstanceTracker.swift`:
- Replace `PlexSaverView` → `MontageView` in all references (WeakRef, registerInstance parameter type)

**Step 4: Update ConfigureSheetController**

In `PlexSaver/Configuration/ConfigureSheetController.swift`:
- Update notification name `.plexSaverConfigChanged` → `.montageConfigChanged`
- Update window title if present

**Step 5: Verify build compiles**

```bash
make clean && make build
```

**Step 6: Commit**

```bash
git add -A
git commit -m "refactor: Rename PlexSaverView to MontageView and update SaverTest references"
```

---

## Task 2: Rename — Bundle IDs, Plists, and Logger

Update bundle identifiers, Info.plist files, logger subsystem, and cache paths.

**Files:**
- Modify: `PlexSaver/Info.plist`
- Modify: `SaverTest/Info.plist` (if bundle ID present)
- Modify: `PlexSaver.xcodeproj/project.pbxproj`
- Modify: `PlexSaver/Helpers/Logger.swift`
- Modify: `PlexSaver/ImagePipeline/DiskCache.swift`
- Modify: `PlexSaver/Helpers/Preferences.swift`

**Step 1: Update Info.plist**

In `PlexSaver/Info.plist`:
- `NSPrincipalClass`: `PlexSaver.PlexSaverView` → `PlexSaver.MontageView` (note: the module name stays "PlexSaver" until we rename the Xcode target itself — do that in project.pbxproj)
- `CFBundleDisplayName`: `PlexSaver v$(MARKETING_VERSION)` → `Montage v$(MARKETING_VERSION)`

**Step 2: Update project.pbxproj bundle identifiers**

In `PlexSaver.xcodeproj/project.pbxproj`, update:
- PlexSaver target: `PRODUCT_BUNDLE_IDENTIFIER = com.plexsaver.PlexSaver` → `com.montage.Montage`
- SaverTest target: `PRODUCT_BUNDLE_IDENTIFIER = com.plexsaver.SaverTest` → `com.montage.MontageTest`
- Product name: `PRODUCT_NAME = PlexSaver` → `PRODUCT_NAME = Montage` (for the screensaver target)
- Product name: `PRODUCT_NAME = SaverTest` → `PRODUCT_NAME = MontageTest` (for the test target)

**Important:** The Xcode target names in the project file reference source file groups. Renaming target display names is safer than renaming the actual target objects — that would break file references. Update `PRODUCT_NAME` and `PRODUCT_BUNDLE_IDENTIFIER` only, leave target object names.

**Step 3: Update Logger subsystem**

In `PlexSaver/Helpers/Logger.swift`, the logger uses `Bundle.main.bundleIdentifier`. Since we're changing the bundle ID, this will automatically update. But update the log prefix:
- `"PS (P:\(ProcessInfo..."` → `"MO (P:\(ProcessInfo..."` (or leave as-is — it's a debug prefix)

**Step 4: Update DiskCache path**

In `PlexSaver/ImagePipeline/DiskCache.swift`, the cache directory is derived from the bundle identifier. Verify it uses `Bundle.main.bundleIdentifier` dynamically (if so, no change needed). If hardcoded, update:
- `com.plexsaver.PlexSaver` → `com.montage.Montage`

**Step 5: Update Preferences module**

In `PlexSaver/Helpers/Preferences.swift`, `ScreenSaverDefaults` uses the bundle identifier as the module name. Verify it uses `Bundle.main.bundleIdentifier` dynamically. If hardcoded, update.

**Step 6: Update Makefile**

In `Makefile`, update:
- All references to `PlexSaver.saver` → `Montage.saver`
- All references to `SaverTest` → `MontageTest`
- Install paths and version extraction references

**Step 7: Verify build and install**

```bash
make clean && make build
make install
```

Verify installed to `~/Library/Screen Savers/Montage.saver`.

**Step 8: Commit**

```bash
git add -A
git commit -m "refactor: Update bundle IDs, cache paths, and build config for Montage rename"
```

---

## Task 3: Rename — Update PlexAuth Product Name and README

**Files:**
- Modify: `PlexSaver/Plex/PlexAuth.swift`
- Modify: `README.md`

**Step 1: Update PlexAuth product name**

In `PlexSaver/Plex/PlexAuth.swift` (line 60):
- `static let productName = "PlexSaver"` → `static let productName = "Montage"`
- This is sent to Plex as the client app name during OAuth

**Step 2: Update notification names**

Search all files for `.plexSaverConfigChanged` and update to `.montageConfigChanged`. This notification is posted by `ConfigureSheetController` and observed by `MontageView`.

In `MontageView.swift`, update the notification observer.
In `ConfigureSheetController.swift`, update the notification poster.

Define the notification name in one place if not already:
```swift
extension Notification.Name {
    static let montageConfigChanged = Notification.Name("montageConfigChanged")
}
```

**Step 3: Update README.md**

- Replace "PlexSaver" → "Montage" throughout
- Update feature description to mention multi-provider support (Plex + Jellyfin)
- Update installation paths
- Keep Plex-specific setup instructions, add placeholder for Jellyfin instructions

**Step 4: Verify build**

```bash
make clean && make build
```

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: Complete Montage rename — auth product name, notifications, README"
```

---

## Task 4: Define MediaProvider Protocol and Shared Types

Create the protocol abstraction layer that both providers will conform to.

**Files:**
- Create: `PlexSaver/Providers/MediaProvider.swift`
- Create: `PlexSaver/Providers/MediaModels.swift`

**Step 1: Create the Providers directory**

```bash
mkdir -p ~/claude/repos/plex-screensaver-for-mac/PlexSaver/Providers
```

**Step 2: Create MediaModels.swift**

```swift
import Foundation

/// Provider-agnostic media library
struct MediaLibrary: Identifiable {
    let id: String
    let name: String
    let type: String  // "movies", "tvshows", "music"
}

/// Provider-agnostic media item with artwork paths
struct MediaItem {
    let id: String
    let title: String
    let year: Int?
    let artPaths: [ImageSourceType: String]

    /// Returns the art path for the given source type, or a random available path for .mixed
    func artPath(for source: ImageSourceType) -> String? {
        switch source {
        case .mixed:
            return artPaths.values.randomElement()
        default:
            return artPaths[source]
        }
    }
}

/// The type of media provider
enum ProviderType: String, Codable, CaseIterable {
    case plex
    case jellyfin

    var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        }
    }
}
```

**Step 3: Create MediaProvider.swift**

```swift
import AppKit

/// Protocol for media server providers (Plex, Jellyfin, etc.)
protocol MediaProvider: Actor {
    /// Human-readable server name for display
    var serverName: String { get }

    /// Fetch available media libraries
    func fetchLibraries() async throws -> [MediaLibrary]

    /// Fetch all media items in a library
    func fetchItems(libraryId: String) async throws -> [MediaItem]

    /// Fetch an image at the given path, scaled to the given dimensions
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage

    /// Test connectivity to the server
    func testConnection() async throws -> Bool
}

/// Protocol for provider-specific authentication flows
protocol MediaAuthenticator {
    /// The provider type this authenticator handles
    var providerType: ProviderType { get }
}
```

**Step 4: Add new files to Xcode project**

The project uses file-system synchronized groups, so new files in the `PlexSaver/` directory tree should be automatically picked up. Verify by building:

```bash
make clean && make build
```

If files aren't picked up, they'll need to be added to the Xcode project manually.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: Define MediaProvider protocol and shared media types"
```

---

## Task 5: Create PlexProvider Conformance

Wrap existing `PlexClient` into a `PlexProvider` actor conforming to `MediaProvider`.

**Files:**
- Create: `PlexSaver/Plex/PlexProvider.swift`
- Modify: `PlexSaver/Plex/PlexModels.swift` (add conversion to MediaItem)

**Step 1: Add MediaItem conversion to PlexMediaItem**

In `PlexSaver/Plex/PlexModels.swift`, add an extension:

```swift
extension PlexMediaItem {
    /// Convert to provider-agnostic MediaItem
    func toMediaItem() -> MediaItem {
        var paths: [ImageSourceType: String] = [:]

        // Fanart: prefer art, fall back to grandparentArt
        if let artPath = art ?? grandparentArt {
            paths[.fanart] = artPath
        }

        // Posters: prefer thumb, fall back to parentThumb, grandparentThumb
        if let posterPath = thumb ?? parentThumb ?? grandparentThumb {
            paths[.posters] = posterPath
        }

        return MediaItem(
            id: ratingKey,
            title: title,
            year: year,
            artPaths: paths
        )
    }
}
```

**Step 2: Add MediaLibrary conversion to PlexLibrary**

In `PlexSaver/Plex/PlexModels.swift`, add:

```swift
extension PlexLibrary {
    /// Convert to provider-agnostic MediaLibrary
    func toMediaLibrary() -> MediaLibrary {
        MediaLibrary(id: key, name: title, type: type)
    }
}
```

**Step 3: Create PlexProvider.swift**

```swift
import AppKit

/// MediaProvider implementation for Plex servers
actor PlexProvider: MediaProvider {
    private let client: PlexClient

    var serverName: String {
        get async { "Plex Server" }
    }

    init(serverURL: String, token: String) {
        self.client = PlexClient(serverURL: serverURL, token: token)
    }

    func fetchLibraries() async throws -> [MediaLibrary] {
        let plexLibraries = try await client.fetchLibraries()
        return plexLibraries.map { $0.toMediaLibrary() }
    }

    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        let plexItems = try await client.fetchAllItems(sectionId: libraryId)
        return plexItems.map { $0.toMediaItem() }
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        return try await client.fetchImage(imagePath: path, width: width, height: height)
    }

    func testConnection() async throws -> Bool {
        return try await client.testConnection()
    }
}
```

**Step 4: Verify build**

```bash
make clean && make build
```

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: Create PlexProvider conforming to MediaProvider protocol"
```

---

## Task 6: Refactor ImagePool to Use MediaProvider

Replace `PlexClient` dependency with `any MediaProvider` in ImagePool.

**Files:**
- Modify: `PlexSaver/ImagePipeline/ImagePool.swift`

**Step 1: Update ImagePool to accept MediaProvider**

In `PlexSaver/ImagePipeline/ImagePool.swift`:

Replace the stored property and init:
- `private let client: PlexClient` → `private let provider: any MediaProvider`
- `init(..., client: PlexClient, ...)` → `init(..., provider: any MediaProvider, ...)`
- Update all `client.` calls to `provider.`

Replace `PlexMediaItem` references with `MediaItem`:
- `private var mediaItems: [PlexMediaItem]` → `private var mediaItems: [MediaItem]`
- In `loadMediaItems`, change the fetch call:
  ```swift
  // Old:
  let items = try await client.fetchAllItems(sectionId: lib.key)
  // New:
  let items = try await provider.fetchItems(libraryId: lib.id)
  ```
- The library fetching also changes:
  ```swift
  // Old:
  let libraries = try await client.fetchLibraries()
  // New:
  let libraries = try await provider.fetchLibraries()
  ```
- Filter logic — update `PlexMediaItem` artPath calls to use `MediaItem.artPath(for:)`
- Image fetching:
  ```swift
  // Old:
  let image = try await client.fetchImage(imagePath: path, width: width, height: height)
  // New:
  let image = try await provider.fetchImage(path: path, width: width, height: height)
  ```

**Step 2: Update loadMediaItems library filtering**

The current code filters by `lib.key` using `selectedLibraryIds`. Update to use `lib.id` (which is the same value mapped through `toMediaLibrary()`).

**Step 3: Update fetchNextImage**

The current code accesses `item.artPath(for: imageSource)` — this now calls `MediaItem.artPath(for:)` which we defined in Task 4. The `item.title` and `item.year` fields map directly.

**Step 4: Verify build**

```bash
make clean && make build
```

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: Update ImagePool to use MediaProvider protocol instead of PlexClient"
```

---

## Task 7: Update MontageView to Use MediaProvider

Update the main view to create the appropriate provider based on preferences.

**Files:**
- Modify: `PlexSaver/MontageView.swift`

**Step 1: Update startNetworkPhase**

The current `startNetworkPhase(serverURL:token:cache:)` creates a `PlexClient` directly. Update to create a provider based on `Preferences.providerType`:

```swift
private func startNetworkPhase(cache: DiskCache) {
    Task {
        do {
            let provider: any MediaProvider

            switch Preferences.providerType {
            case .plex:
                let serverURL = Preferences.plexServerURL
                let token = Preferences.plexToken
                guard !serverURL.isEmpty, !token.isEmpty else {
                    showStatus("Plex not configured")
                    return
                }
                provider = PlexProvider(serverURL: serverURL, token: token)

            case .jellyfin:
                let serverURL = Preferences.jellyfinServerURL
                let token = Preferences.jellyfinAccessToken
                let userId = Preferences.jellyfinUserId
                guard !serverURL.isEmpty, !token.isEmpty, !userId.isEmpty else {
                    showStatus("Jellyfin not configured")
                    return
                }
                provider = JellyfinProvider(serverURL: serverURL, accessToken: token, userId: userId)
            }

            // Rest of the method uses `provider` instead of `client`
            // ...
        }
    }
}
```

**Step 2: Update ImagePool creation**

Where `ImagePool` is created, pass `provider:` instead of `client:`:

```swift
// Old:
let pool = ImagePool(..., client: client, ...)
// New:
let pool = ImagePool(..., provider: provider, ...)
```

**Step 3: Update startImagePipeline**

The method currently extracts `serverURL` and `token` from Preferences and passes them to `startNetworkPhase`. Simplify to just pass the cache:

```swift
// The provider creation logic moves into startNetworkPhase
startNetworkPhase(cache: diskCache)
```

**Step 4: Verify build**

```bash
make clean && make build
```

Note: This will not compile yet because `JellyfinProvider` doesn't exist. Add a temporary stub or use `#if false` around the Jellyfin case. Alternatively, implement Task 8-10 before verifying.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: Update MontageView to create providers based on preference selection"
```

---

## Task 8: Create Jellyfin Models

Define the Decodable types for Jellyfin API responses.

**Files:**
- Create: `PlexSaver/Jellyfin/JellyfinModels.swift`

**Step 1: Create the Jellyfin directory**

```bash
mkdir -p ~/claude/repos/plex-screensaver-for-mac/PlexSaver/Jellyfin
```

**Step 2: Create JellyfinModels.swift**

```swift
import Foundation

// MARK: - Authentication

/// Response from POST /Users/AuthenticateByName
struct JellyfinAuthResponse: Decodable {
    let user: JellyfinUser
    let accessToken: String
    let sessionInfo: JellyfinSessionInfo?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case sessionInfo = "SessionInfo"
    }
}

struct JellyfinUser: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinSessionInfo: Decodable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

// MARK: - Libraries (Views)

/// Response from GET /Users/{userId}/Views
struct JellyfinViewsResponse: Decodable {
    let items: [JellyfinLibrary]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinLibrary: Decodable {
    let id: String
    let name: String
    let collectionType: String?
    let type: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case type = "Type"
    }

    /// Convert to provider-agnostic MediaLibrary
    func toMediaLibrary() -> MediaLibrary {
        MediaLibrary(id: id, name: name, type: collectionType ?? type.lowercased())
    }
}

// MARK: - Items

/// Response from GET /Users/{userId}/Items
struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinItem: Decodable {
    let id: String
    let name: String
    let type: String
    let productionYear: Int?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case productionYear = "ProductionYear"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
    }

    /// Convert to provider-agnostic MediaItem
    /// Image paths are constructed as relative URLs for the Jellyfin image API
    func toMediaItem() -> MediaItem {
        var paths: [ImageSourceType: String] = [:]

        // Primary image → poster
        if imageTags?["Primary"] != nil {
            paths[.posters] = "/Items/\(id)/Images/Primary"
        }

        // Backdrop → fanart
        if let backdropTags = backdropImageTags, !backdropTags.isEmpty {
            paths[.fanart] = "/Items/\(id)/Images/Backdrop"
        }

        return MediaItem(
            id: id,
            title: name,
            year: productionYear,
            artPaths: paths
        )
    }
}
```

**Step 3: Verify build**

```bash
make clean && make build
```

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: Add Jellyfin API response models"
```

---

## Task 9: Create JellyfinClient

Implement the HTTP client actor for Jellyfin API communication.

**Files:**
- Create: `PlexSaver/Jellyfin/JellyfinClient.swift`

**Step 1: Create JellyfinClient.swift**

```swift
import AppKit

/// Actor for Jellyfin API communication
actor JellyfinClient {
    private let serverURL: String
    private let accessToken: String
    private let userId: String
    private let session: URLSession

    init(serverURL: String, accessToken: String, userId: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessToken = accessToken
        self.userId = userId
        self.session = URLSession.shared
    }

    /// Test connectivity by fetching libraries
    func testConnection() async throws -> Bool {
        _ = try await fetchLibraries()
        return true
    }

    /// Fetch available media libraries (views)
    func fetchLibraries() async throws -> [JellyfinLibrary] {
        let data = try await request(path: "/Users/\(userId)/Views")
        let response = try JSONDecoder().decode(JellyfinViewsResponse.self, from: data)
        return response.items
    }

    /// Fetch all media items in a library
    func fetchAllItems(libraryId: String) async throws -> [JellyfinItem] {
        let path = "/Users/\(userId)/Items?ParentId=\(libraryId)&Recursive=true&IncludeItemTypes=Movie,Series,MusicAlbum&Fields=PrimaryImageAspectRatio"
        let data = try await request(path: path)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }

    /// Fetch an image — Jellyfin images are unauthenticated
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        let imageURL = "\(serverURL)\(path)?maxWidth=\(width)&maxHeight=\(height)&format=Jpg&quality=90"

        guard let url = URL(string: imageURL) else {
            throw JellyfinError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JellyfinError.httpError(statusCode)
        }

        guard let image = NSImage(data: data) else {
            throw JellyfinError.invalidImageData
        }

        return image
    }

    // MARK: - Private

    /// Make an authenticated request to the Jellyfin API
    private func request(path: String) async throws -> Data {
        guard let url = URL(string: "\(serverURL)\(path)") else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JellyfinError.httpError(statusCode)
        }

        return data
    }

    /// Build the MediaBrowser authorization header
    private func authorizationHeader() -> String {
        let deviceId = JellyfinAuth.deviceId
        return "MediaBrowser Client=\"Montage\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(accessToken)\""
    }
}

// MARK: - Errors

enum JellyfinError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case invalidImageData
    case authenticationFailed
    case noLibraries
    case noMediaItems

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Jellyfin server URL"
        case .httpError(let code): return "Jellyfin HTTP error: \(code)"
        case .invalidImageData: return "Invalid image data from Jellyfin"
        case .authenticationFailed: return "Jellyfin authentication failed"
        case .noLibraries: return "No libraries found on Jellyfin server"
        case .noMediaItems: return "No media items found"
        }
    }
}
```

**Step 2: Verify build**

```bash
make clean && make build
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: Add JellyfinClient actor for API communication"
```

---

## Task 10: Create JellyfinAuth

Implement username/password authentication for Jellyfin.

**Files:**
- Create: `PlexSaver/Jellyfin/JellyfinAuth.swift`

**Step 1: Create JellyfinAuth.swift**

```swift
import Foundation

/// Handles Jellyfin username/password authentication
actor JellyfinAuth {
    /// Persistent device identifier (stored in UserDefaults)
    static var deviceId: String {
        let key = "JellyfinDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    /// Authenticate with username and password
    /// Returns (accessToken, userId) on success
    func authenticate(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) {
        let baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/Users/AuthenticateByName") else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Initial auth header without token
        let authHeader = "MediaBrowser Client=\"Montage\", Device=\"Mac\", DeviceId=\"\(JellyfinAuth.deviceId)\", Version=\"1.0\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "Username": username,
            "Pw": password
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinError.authenticationFailed
        }

        let authResponse = try JSONDecoder().decode(JellyfinAuthResponse.self, from: data)

        return (accessToken: authResponse.accessToken, userId: authResponse.user.id)
    }
}
```

**Step 2: Verify build**

```bash
make clean && make build
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: Add JellyfinAuth for username/password authentication"
```

---

## Task 11: Create JellyfinProvider

Implement the `MediaProvider` conformance for Jellyfin.

**Files:**
- Create: `PlexSaver/Jellyfin/JellyfinProvider.swift`

**Step 1: Create JellyfinProvider.swift**

```swift
import AppKit

/// MediaProvider implementation for Jellyfin servers
actor JellyfinProvider: MediaProvider {
    private let client: JellyfinClient
    private let jellyfinServerURL: String

    var serverName: String {
        get async { "Jellyfin Server" }
    }

    init(serverURL: String, accessToken: String, userId: String) {
        self.jellyfinServerURL = serverURL
        self.client = JellyfinClient(serverURL: serverURL, accessToken: accessToken, userId: userId)
    }

    func fetchLibraries() async throws -> [MediaLibrary] {
        let jfLibraries = try await client.fetchLibraries()
        return jfLibraries.map { $0.toMediaLibrary() }
    }

    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        let jfItems = try await client.fetchAllItems(libraryId: libraryId)
        return jfItems.map { $0.toMediaItem() }
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        return try await client.fetchImage(path: path, width: width, height: height)
    }

    func testConnection() async throws -> Bool {
        return try await client.testConnection()
    }
}
```

**Step 2: Verify build**

```bash
make clean && make build
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: Add JellyfinProvider conforming to MediaProvider protocol"
```

---

## Task 12: Update Preferences for Multi-Provider

Add Jellyfin-specific preferences and provider selection.

**Files:**
- Modify: `PlexSaver/Helpers/Preferences.swift`

**Step 1: Add new preference fields**

Add to the `Preferences` struct (after the existing Plex fields):

```swift
// Provider selection
@Storage(key: "providerType", defaultValue: .plex)
static var providerType: ProviderType

// Jellyfin settings
@SimpleStorage(key: "jellyfinServerURL", defaultValue: "")
static var jellyfinServerURL: String

@SimpleStorage(key: "jellyfinUsername", defaultValue: "")
static var jellyfinUsername: String

@SimpleStorage(key: "jellyfinAccessToken", defaultValue: "")
static var jellyfinAccessToken: String

@SimpleStorage(key: "jellyfinUserId", defaultValue: "")
static var jellyfinUserId: String
```

**Step 2: Verify build**

```bash
make clean && make build
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: Add Jellyfin and provider-type preferences"
```

---

## Task 13: Update ConfigurationViewModel for Multi-Provider

Add Jellyfin auth flow and provider switching to the view model.

**Files:**
- Modify: `PlexSaver/Configuration/ConfigurationViewModel.swift`

**Step 1: Add published properties for provider and Jellyfin**

Add to the published properties section:

```swift
// Provider selection
@Published var providerType: ProviderType = .plex

// Jellyfin
@Published var jellyfinServerURL: String = ""
@Published var jellyfinUsername: String = ""
@Published var jellyfinPassword: String = ""  // Not persisted
@Published var isJellyfinConnected: Bool = false
@Published var isJellyfinConnecting: Bool = false
@Published var jellyfinStatus: String = ""
```

**Step 2: Add Jellyfin connect method**

```swift
func connectToJellyfin() {
    guard !jellyfinServerURL.isEmpty, !jellyfinUsername.isEmpty, !jellyfinPassword.isEmpty else {
        jellyfinStatus = "Please fill in all fields"
        return
    }

    isJellyfinConnecting = true
    jellyfinStatus = "Connecting..."

    Task {
        do {
            let auth = JellyfinAuth()
            let result = try await auth.authenticate(
                serverURL: jellyfinServerURL,
                username: jellyfinUsername,
                password: jellyfinPassword
            )

            await MainActor.run {
                Preferences.jellyfinServerURL = jellyfinServerURL
                Preferences.jellyfinUsername = jellyfinUsername
                Preferences.jellyfinAccessToken = result.accessToken
                Preferences.jellyfinUserId = result.userId
                isJellyfinConnected = true
                isJellyfinConnecting = false
                jellyfinStatus = "Connected"
                jellyfinPassword = ""  // Clear password from memory

                // Fetch libraries for the library picker
                testJellyfinConnection()
            }
        } catch {
            await MainActor.run {
                isJellyfinConnecting = false
                jellyfinStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

func disconnectJellyfin() {
    Preferences.jellyfinAccessToken = ""
    Preferences.jellyfinUserId = ""
    isJellyfinConnected = false
    jellyfinStatus = ""
    discoveredLibraries = []
}
```

**Step 3: Add Jellyfin connection test**

```swift
func testJellyfinConnection() {
    let serverURL = Preferences.jellyfinServerURL
    let token = Preferences.jellyfinAccessToken
    let userId = Preferences.jellyfinUserId

    guard !serverURL.isEmpty, !token.isEmpty, !userId.isEmpty else { return }

    isTesting = true
    Task {
        do {
            let provider = JellyfinProvider(serverURL: serverURL, accessToken: token, userId: userId)
            let libraries = try await provider.fetchLibraries()

            await MainActor.run {
                discoveredLibraries = libraries
                isTesting = false
                testResult = true
                testMessage = "Connected — \(libraries.count) libraries found"
            }
        } catch {
            await MainActor.run {
                isTesting = false
                testResult = false
                testMessage = error.localizedDescription
            }
        }
    }
}
```

**Step 4: Update loadPreferences**

Add to `loadPreferences()`:

```swift
providerType = Preferences.providerType
jellyfinServerURL = Preferences.jellyfinServerURL
jellyfinUsername = Preferences.jellyfinUsername
isJellyfinConnected = !Preferences.jellyfinAccessToken.isEmpty
```

**Step 5: Update setupBindings**

Add a binding for `providerType` that saves to Preferences:

```swift
$providerType
    .dropFirst()
    .sink { Preferences.providerType = $0 }
    .store(in: &cancellables)
```

**Step 6: Update testConnection to be provider-aware**

Modify the existing `testConnection()` to route based on provider type:

```swift
func testConnection() {
    switch providerType {
    case .plex:
        testPlexConnection()  // Rename existing testConnection logic
    case .jellyfin:
        testJellyfinConnection()
    }
}
```

Extract the existing Plex test logic into `testPlexConnection()`.

**Step 7: Update discoveredLibraries type**

The existing `discoveredLibraries` is likely `[PlexLibrary]`. Change it to `[MediaLibrary]` so both providers can populate it:

```swift
@Published var discoveredLibraries: [MediaLibrary] = []
```

Update the Plex test connection to map `PlexLibrary` → `MediaLibrary` using `.toMediaLibrary()`.

**Step 8: Verify build**

```bash
make clean && make build
```

**Step 9: Commit**

```bash
git add -A
git commit -m "feat: Add Jellyfin auth flow and provider switching to ConfigurationViewModel"
```

---

## Task 14: Update ConfigurationView with Segmented Control

Add the Plex/Jellyfin tab UI with provider-specific auth sections.

**Files:**
- Modify: `PlexSaver/Configuration/ConfigurationView.swift`

**Step 1: Add segmented provider picker**

At the top of the main VStack (before the current Plex Account section), add:

```swift
// Provider selection
Section {
    Picker("Media Server", selection: $viewModel.providerType) {
        ForEach(ProviderType.allCases, id: \.self) { type in
            Text(type.displayName).tag(type)
        }
    }
    .pickerStyle(.segmented)
    .padding(.bottom, 4)
}
```

**Step 2: Wrap existing Plex auth section conditionally**

```swift
if viewModel.providerType == .plex {
    // Existing Plex Account section (unchanged)
    Section("Plex Account") {
        // ... existing signedInView / serverPickerView / signInView
    }
}
```

**Step 3: Add Jellyfin auth section**

```swift
if viewModel.providerType == .jellyfin {
    Section("Jellyfin Server") {
        if viewModel.isJellyfinConnected {
            jellyfinConnectedView
        } else {
            jellyfinLoginView
        }
    }
}
```

**Step 4: Create jellyfinLoginView**

```swift
private var jellyfinLoginView: some View {
    VStack(alignment: .leading, spacing: 8) {
        TextField("Server URL", text: $viewModel.jellyfinServerURL)
            .textFieldStyle(.roundedBorder)
            .help("e.g. http://jellyfin.local:8096")

        TextField("Username", text: $viewModel.jellyfinUsername)
            .textFieldStyle(.roundedBorder)

        SecureField("Password", text: $viewModel.jellyfinPassword)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button("Connect") {
                viewModel.connectToJellyfin()
            }
            .disabled(viewModel.isJellyfinConnecting
                || viewModel.jellyfinServerURL.isEmpty
                || viewModel.jellyfinUsername.isEmpty
                || viewModel.jellyfinPassword.isEmpty)

            if viewModel.isJellyfinConnecting {
                ProgressView()
                    .controlSize(.small)
            }

            if !viewModel.jellyfinStatus.isEmpty {
                Text(viewModel.jellyfinStatus)
                    .font(.caption)
                    .foregroundColor(viewModel.isJellyfinConnected ? .green : .red)
            }
        }
    }
}
```

**Step 5: Create jellyfinConnectedView**

```swift
private var jellyfinConnectedView: some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(viewModel.jellyfinServerURL)
                .font(.caption)
            Text("(\(viewModel.jellyfinUsername))")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Button("Disconnect") {
            viewModel.disconnectJellyfin()
        }
    }
}
```

**Step 6: Make shared sections provider-aware**

The Display and Libraries sections should show when the active provider is connected:

```swift
let isConnected = (viewModel.providerType == .plex && viewModel.isSignedIn)
    || (viewModel.providerType == .jellyfin && viewModel.isJellyfinConnected)

if isConnected {
    // Display settings section
    // Libraries section
    // Connection test section
}
```

**Step 7: Verify build**

```bash
make clean && make build
```

**Step 8: Test manually with SaverTest**

```bash
make test
```

Open the MontageTest app, click Options, verify:
- Segmented control switches between Plex and Jellyfin
- Plex shows existing sign-in flow
- Jellyfin shows URL/username/password fields
- Shared settings appear when either provider is connected

**Step 9: Commit**

```bash
git add -A
git commit -m "feat: Add segmented Plex/Jellyfin provider picker to configuration UI"
```

---

## Task 15: Integration Testing and Polish

End-to-end verification and cleanup.

**Files:**
- Modify: Various (bug fixes from testing)

**Step 1: Test Plex flow end-to-end**

1. Build and install: `make install`
2. Open System Settings → Screen Saver → Montage
3. Click Options, select Plex tab
4. Sign in with Plex, select server
5. Preview screensaver — verify artwork loads and rotates

**Step 2: Test Jellyfin flow end-to-end**

1. Open Options, select Jellyfin tab
2. Enter Jellyfin server URL, username, password
3. Click Connect — verify authentication succeeds
4. Select libraries
5. Preview screensaver — verify Jellyfin artwork loads and rotates

**Step 3: Test provider switching**

1. Configure both providers
2. Switch between them in config
3. Verify screensaver reloads with correct provider's artwork
4. Verify disk cache is separate per config change (existing validateConfig handles this)

**Step 4: Test offline behavior**

1. Configure Jellyfin, let cache populate
2. Disconnect/stop Jellyfin server
3. Verify screensaver falls back to cached images

**Step 5: Fix any issues found during testing**

Address bugs discovered in steps 1-4.

**Step 6: Commit**

```bash
git add -A
git commit -m "fix: Integration testing fixes for multi-provider support"
```

---

## Task 16: Update README and Documentation

Final documentation updates.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md` (if it references PlexSaver-specific details)

**Step 1: Update README**

- Project name: Montage
- Feature list: Add "Jellyfin support" alongside Plex
- Setup instructions: Add Jellyfin configuration section
- Architecture: Update to mention MediaProvider protocol
- Screenshots: Note they need updating (can be done separately)

**Step 2: Update CLAUDE.md if present**

Check for any PlexSaver-specific references and update.

**Step 3: Commit**

```bash
git add -A
git commit -m "docs: Update README and docs for Montage rename and Jellyfin support"
```

---

## Parallelization Notes

These task groups can run in parallel if using worktrees:

- **Track A (Rename):** Tasks 1-3 (sequential)
- **Track B (Protocol + Plex refactor):** Tasks 4-7 (sequential, can start alongside Track A)
- **Track C (Jellyfin implementation):** Tasks 8-11 (sequential, depends on Task 4 for protocol types)
- **Track D (UI + Config):** Tasks 12-14 (sequential, depends on Tasks 5 and 11)
- **Track E (Integration):** Tasks 15-16 (depends on all above)

Recommended execution: Tasks 1-3, then 4-7 and 8-11 in parallel, then 12-14, then 15-16.
