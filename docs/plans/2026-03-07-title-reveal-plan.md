# Title Reveal Feature — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show media title + year in the bottom-left corner of each grid cell before it rotates, with configurable toggle and duration.

**Architecture:** Extend `ImagePool` to return metadata alongside images via a new `ImageWithMetadata` struct. `GridManager` schedules a two-phase rotation: title reveal, then crossfade. `GridCell` gains a `CATextLayer` for the title overlay. Two new preferences control the feature.

**Tech Stack:** Swift, Core Animation (CATextLayer), SwiftUI (config UI), ScreenSaverDefaults

**Design doc:** `docs/plans/2026-03-07-title-reveal-design.md`

---

### Task 1: Add `year` to PlexMediaItem

**Files:**
- Modify: `PlexSaver/Plex/PlexModels.swift:36-44`

**Step 1: Add the field**

Add `year: Int?` to `PlexMediaItem`. The Plex API already returns this field — the `Decodable` conformance will pick it up automatically.

```swift
struct PlexMediaItem: Decodable {
    let ratingKey: String
    let title: String
    let type: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
```

**Step 2: Build to verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add PlexSaver/Plex/PlexModels.swift
git commit -m "feat: add year field to PlexMediaItem"
```

---

### Task 2: Create ImageWithMetadata and refactor ImagePool

**Files:**
- Modify: `PlexSaver/ImagePipeline/ImagePool.swift`

**Step 1: Add ImageWithMetadata struct at the top of the file (after imports)**

```swift
struct ImageWithMetadata {
    let image: NSImage
    let title: String
    let year: Int?
}
```

**Step 2: Refactor the pool storage and takeImage()**

Change `pool` from `[NSImage]` to `[ImageWithMetadata]` (line 20).

```swift
private var pool: [ImageWithMetadata] = []
```

Change `takeImage()` return type (lines 83-93):

```swift
func takeImage() -> ImageWithMetadata? {
    guard !pool.isEmpty else { return nil }
    let item = pool.removeFirst()

    if pool.count < poolSize / 2 && !isRefilling {
        Task { await refillPool() }
    }

    return item
}
```

**Step 3: Refactor fetchNextImage() to return ImageWithMetadata**

Change return type and pair the image with metadata (lines 121-150):

```swift
private func fetchNextImage() async -> ImageWithMetadata? {
    guard let item = nextMediaItem(),
          let artPath = item.artPath(for: imageSource) else {
        return nil
    }

    // 1. Check in-memory cache
    if let cached = cache.get(artPath) {
        return ImageWithMetadata(image: cached, title: item.title, year: item.year)
    }

    // 2. Check disk cache
    if let disk = diskCache, let cached = await disk.get(artPath) {
        cache.set(artPath, image: cached)
        return ImageWithMetadata(image: cached, title: item.title, year: item.year)
    }

    // 3. Fetch from network, write-through to both caches
    do {
        let image = try await client.fetchImage(imagePath: artPath, width: cellWidth, height: cellHeight)
        cache.set(artPath, image: image)
        if let disk = diskCache {
            await disk.store(artPath, image: image)
        }
        return ImageWithMetadata(image: image, title: item.title, year: item.year)
    } catch {
        OSLog.info("ImagePool: Failed to fetch image for \(item.title): \(error.localizedDescription)")
        return nil
    }
}
```

**Step 4: Update prefill() and refillPool()**

These append to `pool` which is now `[ImageWithMetadata]`. The `fetchNextImage()` return type change handles this — no further changes needed since `pool.append(image)` becomes `pool.append(item)` where `item` is `ImageWithMetadata`. Rename the local variable for clarity:

In `prefill()` (lines 71-76):
```swift
if let item = await fetchNextImage() {
    pool.append(item)
}
```

In `refillPool()` (lines 157-163):
```swift
if let item = await fetchNextImage() {
    pool.append(item)
}
```

**Step 5: Build to verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -20`
Expected: Build errors in GridManager.swift and PlexSaverView.swift (they still expect `NSImage?` from `takeImage()`). This is expected — we fix them in the next tasks.

**Step 6: Commit**

```bash
git add PlexSaver/ImagePipeline/ImagePool.swift
git commit -m "feat: ImagePool returns ImageWithMetadata with title and year"
```

---

### Task 3: Add title CATextLayer to GridCell

**Files:**
- Modify: `PlexSaver/Grid/GridCell.swift`

**Step 1: Add titleLayer property and setup**

Add after line 16 (`private var hasDisplayedFirstImage = false`):

```swift
private let titleLayer = CATextLayer()
private var currentTitle: String?
```

In `init(frame:row:column:)`, after `containerLayer.addSublayer(layer2)` (line 43), add titleLayer setup:

```swift
let scale = NSScreen.main?.backingScaleFactor ?? 2.0

titleLayer.contentsScale = scale
titleLayer.fontSize = max(11, min(frame.height / 12, 16))
titleLayer.foregroundColor = CGColor.white
titleLayer.alignmentMode = .left
titleLayer.isWrapped = false
titleLayer.truncationMode = .end
titleLayer.opacity = 0

// Drop shadow
titleLayer.shadowColor = CGColor.black
titleLayer.shadowOffset = CGSize(width: 1, height: -1)
titleLayer.shadowRadius = 3
titleLayer.shadowOpacity = 1.0

let padding: CGFloat = 8
titleLayer.frame = CGRect(
    x: padding,
    y: padding,
    width: frame.width - padding * 2,
    height: titleLayer.fontSize + 6
)
containerLayer.addSublayer(titleLayer)
```

**Step 2: Add showTitle() and hideTitle() methods**

After the `displayImage()` method:

```swift
/// Show the title with a fade-in animation.
func showTitle(_ title: String, fadeDuration: CFTimeInterval = 0.3) {
    currentTitle = title

    CATransaction.begin()
    CATransaction.setAnimationDuration(0)
    titleLayer.string = title
    CATransaction.commit()

    CATransaction.begin()
    CATransaction.setAnimationDuration(fadeDuration)
    titleLayer.opacity = 1
    CATransaction.commit()
}

/// Hide the title with a fade-out animation.
func hideTitle(fadeDuration: CFTimeInterval = 0.3) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(fadeDuration)
    titleLayer.opacity = 0
    CATransaction.commit()
    currentTitle = nil
}
```

**Step 3: Hide title during crossfade**

In `displayImage()`, after setting `inactiveLayer.contents` and before the crossfade animation block, hide the title instantly so it disappears with the outgoing image:

```swift
// Hide title (it belongs to the outgoing image)
titleLayer.opacity = 0
currentTitle = nil
```

**Step 4: Update updateFrame() to reposition titleLayer**

In `updateFrame()`, after updating layer1 and layer2 frames:

```swift
titleLayer.fontSize = max(11, min(frame.height / 12, 16))
let padding: CGFloat = 8
titleLayer.frame = CGRect(
    x: padding,
    y: padding,
    width: frame.width - padding * 2,
    height: titleLayer.fontSize + 6
)
```

**Step 5: Update displayImage() signature to accept metadata**

Change the signature to accept optional metadata. When metadata is provided, store it for later reveal (GridManager will call showTitle separately):

```swift
func displayImage(_ image: NSImage, title: String? = nil, year: Int? = nil, transitionDuration: CFTimeInterval = 1.0) {
```

No change to the body needed — the title/year are stored for GridManager to use via `showTitle()`.

**Step 6: Build to verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -20`
Expected: Still build errors in GridManager (expected, fixed in Task 4).

**Step 7: Commit**

```bash
git add PlexSaver/Grid/GridCell.swift
git commit -m "feat: add CATextLayer title overlay to GridCell"
```

---

### Task 4: Wire metadata through GridManager with title reveal timing

**Files:**
- Modify: `PlexSaver/Grid/GridManager.swift`

**Step 1: Add title reveal properties**

After `private var lastUpdateTime: [Int: Date] = [:]` (line 18), add:

```swift
private var showTitleReveal: Bool
private var titleDisplayDuration: TimeInterval
private let crossfadeDuration: TimeInterval = 1.0
```

Update `init` to accept these:

```swift
init(frame: CGRect, rows: Int, columns: Int, rotationInterval: TimeInterval, showTitleReveal: Bool = true, titleDisplayDuration: TimeInterval = 2.0) {
    self.rows = max(1, rows)
    self.columns = max(1, columns)
    self.rotationInterval = rotationInterval
    self.showTitleReveal = showTitleReveal
    self.titleDisplayDuration = min(titleDisplayDuration, rotationInterval - crossfadeDuration)
    // ... rest unchanged
```

**Step 2: Refactor rotateCell() for two-phase rotation**

Replace `rotateCell(at:)` (lines 142-154):

```swift
private func rotateCell(at index: Int) {
    guard let pool = imagePool, index < cells.count else { return }
    let cell = cells[index]
    lastUpdateTime[index] = Date()

    Task {
        if let item = await pool.takeImage() {
            await MainActor.run {
                if self.showTitleReveal, let currentTitle = cell.currentTitle {
                    // Title is already showing (shouldn't happen in normal flow)
                    cell.displayImage(item.image, transitionDuration: self.crossfadeDuration)
                } else if self.showTitleReveal {
                    // Phase 1: Show title of CURRENT image, then swap after delay
                    self.revealThenRotate(cell: cell, newItem: item)
                } else {
                    // No title reveal — immediate crossfade
                    cell.displayImage(item.image, transitionDuration: self.crossfadeDuration)
                }
            }
        }
    }
}
```

**Step 3: Add revealThenRotate method and per-cell metadata tracking**

Add a property to track current metadata per cell (after `lastUpdateTime`):

```swift
private var cellMetadata: [Int: (title: String, year: Int?)] = [:]
```

Update the initial fill loop in `startRotation()` to store metadata. Replace lines 64-69:

```swift
let now = Date()
for i in 0..<cells.count {
    rotateCellImmediate(at: i)
    lastUpdateTime[i] = now
}
```

Add the immediate rotation method (no title reveal on initial fill):

```swift
private func rotateCellImmediate(at index: Int) {
    guard let pool = imagePool, index < cells.count else { return }
    let cell = cells[index]

    Task {
        if let item = await pool.takeImage() {
            await MainActor.run {
                cell.displayImage(item.image, transitionDuration: 0)
                self.cellMetadata[index] = (title: item.title, year: item.year)
            }
        }
    }
}
```

Add the reveal-then-rotate method:

```swift
private func revealThenRotate(cell: GridCell, newItem: ImageWithMetadata) {
    // Find the cell index
    guard let index = cells.firstIndex(where: { $0 === cell }) else {
        cell.displayImage(newItem.image, transitionDuration: crossfadeDuration)
        return
    }

    // Build title string from current cell's metadata
    if let meta = cellMetadata[index] {
        let titleText: String
        if let year = meta.year {
            titleText = "\(meta.title) (\(year))"
        } else {
            titleText = meta.title
        }
        cell.showTitle(titleText)
    }

    // After titleDisplayDuration, crossfade to new image
    DispatchQueue.main.asyncAfter(deadline: .now() + titleDisplayDuration) { [weak self] in
        guard let self = self else { return }
        cell.displayImage(newItem.image, transitionDuration: self.crossfadeDuration)
        self.cellMetadata[index] = (title: newItem.title, year: newItem.year)
    }
}
```

**Step 4: Adjust timer interval to account for title reveal time**

The timer fires every `rotationInterval` seconds. The title reveal adds `titleDisplayDuration` to the visible time per cell. Adjust the timer so that the total visible time (including reveal) matches the user's configured interval.

In `startRotation()`, change the timer interval (line 72):

```swift
let effectiveInterval = showTitleReveal ? rotationInterval : rotationInterval
```

Actually, keep the timer interval as `rotationInterval`. The title reveal happens _within_ the rotation interval — the timer fires, then the reveal plays, then the crossfade starts. The next timer fire is still `rotationInterval` seconds later. The `rotateWeightedRandomCell` method handles the scheduling, and the title reveal + crossfade happen within that window. No timer adjustment needed.

**Step 5: Build to verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -20`
Expected: Build errors in PlexSaverView.swift where it calls `pool.takeImage()` expecting `NSImage?` and `cell.displayImage()`. Fix in Task 5.

**Step 6: Commit**

```bash
git add PlexSaver/Grid/GridManager.swift
git commit -m "feat: GridManager two-phase rotation with title reveal"
```

---

### Task 5: Update PlexSaverView for new API

**Files:**
- Modify: `PlexSaver/PlexSaverView.swift`

**Step 1: Update setupGrid() to pass title reveal preferences**

Change line 251:

```swift
let manager = GridManager(
    frame: bounds,
    rows: rows,
    columns: columns,
    rotationInterval: Preferences.rotationInterval,
    showTitleReveal: Preferences.showTitleReveal,
    titleDisplayDuration: Preferences.titleDisplayDuration
)
```

**Step 2: Build to verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -20`
Expected: Build errors for `Preferences.showTitleReveal` and `Preferences.titleDisplayDuration` not existing yet. This is expected — fixed in Task 6.

**Step 3: Commit**

```bash
git add PlexSaver/PlexSaverView.swift
git commit -m "feat: PlexSaverView passes title reveal prefs to GridManager"
```

---

### Task 6: Add preferences for title reveal

**Files:**
- Modify: `PlexSaver/Helpers/Preferences.swift:23-47`

**Step 1: Add two new preferences**

After `selectedLibraryIds` (line 46), add:

```swift
@SimpleStorage(key: "ShowTitleReveal", defaultValue: true)
static var showTitleReveal: Bool

@SimpleStorage(key: "TitleDisplayDuration", defaultValue: 2.0)
static var titleDisplayDuration: Double
```

**Step 2: Build to verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (all compile errors resolved)

**Step 3: Commit**

```bash
git add PlexSaver/Helpers/Preferences.swift
git commit -m "feat: add showTitleReveal and titleDisplayDuration preferences"
```

---

### Task 7: Add config UI for title reveal

**Files:**
- Modify: `PlexSaver/Configuration/ConfigurationView.swift`

**Step 1: Check ConfigurationViewModel for @Published properties**

Read `PlexSaver/Configuration/ConfigurationViewModel.swift` to see how other preferences are exposed. Add matching `@Published` properties and save-on-change for the two new prefs. The exact implementation depends on the ViewModel pattern — match the existing style.

**Step 2: Add title reveal controls to ConfigurationView**

After `timingView` (line 36 in the body), add a new view reference:

```swift
titleRevealView
```

Add the view property after `imageSourceView`:

```swift
private var titleRevealView: some View {
    VStack(alignment: .leading, spacing: 4) {
        Toggle("Show title before rotation", isOn: $viewModel.showTitleReveal)

        if viewModel.showTitleReveal {
            HStack {
                Text("Title duration:")
                Slider(
                    value: $viewModel.titleDisplayDuration,
                    in: 1...max(1, viewModel.rotationInterval - 1),
                    step: 0.5
                )
                Text("\(String(format: "%.1f", viewModel.titleDisplayDuration))s")
                    .monospacedDigit()
                    .frame(width: 35, alignment: .trailing)
            }
        }
    }
}
```

Note: The slider's max is `rotationInterval - 1` (1s for crossfade). This enforces the validation rule from the design — the title can never display longer than the image is on screen.

**Step 3: Add @Published properties to ConfigurationViewModel**

Add to ConfigurationViewModel (match existing pattern for other prefs):

```swift
@Published var showTitleReveal: Bool = Preferences.showTitleReveal {
    didSet {
        Preferences.showTitleReveal = showTitleReveal
        notifyConfigChanged()
    }
}

@Published var titleDisplayDuration: Double = Preferences.titleDisplayDuration {
    didSet {
        Preferences.titleDisplayDuration = titleDisplayDuration
        notifyConfigChanged()
    }
}
```

**Step 4: Build and verify**

Run: `xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add PlexSaver/Configuration/ConfigurationView.swift PlexSaver/Configuration/ConfigurationViewModel.swift
git commit -m "feat: add title reveal toggle and duration slider to config UI"
```

---

### Task 8: Handle DiskCache cached image rotation with metadata

**Files:**
- Modify: `PlexSaver/PlexSaverView.swift`

**Step 1: Assess cached image rotation**

The Phase 1 cached rotation in `PlexSaverView` (`rotateCachedCell`, `fillGridWithCachedImages`) uses bare `NSImage` from `DiskCache.allCachedImages()`. The disk cache doesn't store metadata — it only stores JPEG files.

For the cached image path (offline/startup), title reveal should gracefully degrade: no title is shown because no metadata is available. The `GridManager.cellMetadata` dict will be empty for these cells, so `revealThenRotate` will skip the title and just crossfade. No code changes needed for this — verify by reading the logic.

**Step 2: Verify no-op behavior**

Confirm that `revealThenRotate` handles missing metadata gracefully. In Task 4, the method checks `if let meta = cellMetadata[index]` — if no metadata exists, it skips the title and proceeds directly to crossfade. This is correct.

However, the cached rotation in `PlexSaverView` uses `cell.displayImage()` directly, bypassing `GridManager` entirely. This path doesn't involve title reveal at all, which is fine — cached images have no metadata.

**Step 3: Commit (no-op, just verification)**

No code changes needed. Move to next task.

---

### Task 9: Manual test

**Step 1: Build and run SaverTest**

```bash
cd ~/claude/repos/plex-screensaver-for-mac
xcodebuild -project PlexSaver.xcodeproj -scheme SaverTest -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/PlexSaver-*/Build/Products/Debug/SaverTest.app
```

**Step 2: Verify in SaverTest**

- [ ] Grid displays images as before
- [ ] After `rotationInterval - titleDisplayDuration` seconds, title + year fades in on a cell
- [ ] Title shows in bottom-left corner with drop shadow
- [ ] After `titleDisplayDuration` seconds, cell crossfades to new image and title disappears
- [ ] Open preferences: toggle exists, slider exists
- [ ] Toggle off: no titles shown, cells rotate normally
- [ ] Toggle on: titles appear before rotation
- [ ] Duration slider adjusts title display time
- [ ] Duration slider max is clamped to rotation interval - 1s

**Step 3: View logs**

```bash
log stream --predicate 'subsystem CONTAINS "PlexSaver" OR subsystem CONTAINS "SaverTest"' --level debug
```

**Step 4: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address issues found during manual testing"
```

---

### Task 10: Install and verify as screensaver

**Step 1: Build release and install**

```bash
xcodebuild -project PlexSaver.xcodeproj -scheme PlexSaver -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/PlexSaver-*/Build/Products/Release/PlexSaver.saver ~/Library/Screen\ Savers/
```

**Step 2: Verify**

- Open System Settings → Screen Saver → PlexSaver
- Click Options, verify title reveal controls appear
- Let screensaver run, verify titles appear before rotation

**Step 3: Commit any final fixes**

If all good, no commit needed. Feature complete.
