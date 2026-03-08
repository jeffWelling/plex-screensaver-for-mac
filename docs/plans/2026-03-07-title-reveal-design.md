# Title Reveal Feature — Design

**Date:** 2026-03-07
**Status:** Approved

## Summary

Before a grid cell rotates to a new image, the current image's title and year fade in as small text in the bottom-left corner of that cell (with drop shadow), stay visible for a configurable duration, then the cell crossfades to the next image.

## New Preferences

- **Show title before rotation** — boolean toggle (default: on)
- **Title display duration** — configurable in seconds (default: 2s). Clamped to `rotationInterval - crossfadeDuration` so the title can never display longer than the image itself is on screen.

### Validation

```
titleDuration = min(titleDuration, rotationInterval - crossfadeDuration)
```

Enforced at the preferences level. The UI prevents invalid configuration.

## Data Flow

### New type: `ImageWithMetadata`

```swift
struct ImageWithMetadata {
    let image: NSImage
    let title: String
    let year: Int?
}
```

### Pipeline changes

1. `PlexMediaItem` — add `year: Int?` field (already in Plex API response, not currently decoded)
2. `ImagePool.takeImage()` — returns `ImageWithMetadata?` instead of `NSImage?`
3. `ImagePool.fetchNextImage()` — pairs the fetched image with the media item's title and year instead of discarding metadata
4. `GridManager.rotateCell()` — receives `ImageWithMetadata`, stores current title/year per cell, schedules title reveal before crossfade
5. `GridCell.displayImage()` — accepts metadata alongside the image

## Cell Rotation Sequence

```
|<-- image visible (no title) -->|<- title fade ->|<-- title visible -->|<-- crossfade -->|
|   interval - title - fade - xf |     0.3s       |   titleDuration     |      1.0s       |
```

1. Image displayed without title for `(rotationInterval - titleDuration - 0.3 - crossfadeDuration)` seconds
2. Title + year fades in over current image (0.3s animation)
3. Title stays visible for `titleDuration` seconds
4. Cell crossfades to next image (1.0s) — title disappears with the outgoing image
5. Cycle repeats

## GridCell Layer Structure

```
containerLayer (masksToBounds=true)
  ├── layer1        (image layer A)
  ├── layer2        (image layer B)
  └── titleLayer    (CATextLayer, bottom-left, drop shadow)
```

### Title layer properties

- Position: bottom-left corner of cell, small padding
- Font: system font, small size appropriate for cell dimensions
- Color: white
- Shadow: black drop shadow for readability against any background
- The title layer is a sublayer of `containerLayer`, above both image layers
- On crossfade: title layer opacity animates to 0 alongside the outgoing image layer

## Files Changed

| File | Change |
|------|--------|
| `PlexModels.swift` | Add `year: Int?` to `PlexMediaItem` |
| `ImagePool.swift` | New `ImageWithMetadata` struct, refactor `takeImage()` and `fetchNextImage()` return types |
| `GridManager.swift` | Accept metadata, store per-cell title, schedule reveal timing before crossfade |
| `GridCell.swift` | Add `CATextLayer`, `showTitle()`/`hideTitle()` methods with fade animation |
| `Preferences.swift` | Add `showTitleReveal: Bool` and `titleDisplayDuration: Double` |
| `ConfigurationView.swift` | Add toggle checkbox and duration stepper/slider |
| `DiskCache.swift` | May need to store/retrieve metadata alongside cached images |
