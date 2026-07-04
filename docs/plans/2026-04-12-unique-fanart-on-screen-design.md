# Unique Fanart On-Screen — Design

**Date:** 2026-04-12
**Status:** Proposed

## Summary

Guarantee that no two grid cells ever display the same media item at the same time. The current `ImagePool` shuffles media indices per cycle, but when a cycle ends it reshuffles from scratch with no awareness of what is currently on screen — the first items of the new cycle frequently collide with items still displayed in cells.

## Invariant

At any moment, the union of ids in `{ImagePool.pool} ∪ {ids currently displayed in any GridCell}` contains no duplicates.

If the invariant cannot be satisfied (library too small), `takeImage()` returns nil and the caller skips the update — cells keep their previous image, or stay black on initial fill. No explicit "empty state" UI is needed; `GridCell`'s black backing layer already handles this.

## Mechanism

`ImagePool` gains a single set of reserved media item ids. An id is inserted when an item enters the pool (via `fetchNextImage`) and removed only when `GridManager` explicitly releases it. Because an item is "reserved" for its entire lifetime from pool-entry through on-screen display, the union invariant holds automatically.

### New / Modified Types

```swift
struct ImageWithMetadata {
    let id: String        // NEW — MediaItem.id
    let image: NSImage
    let title: String
    let year: Int?
}
```

### ImagePool changes

- Add `private var reservedIds: Set<String> = []`.
- `fetchNextImage()` — after obtaining a `MediaItem`, check `!reservedIds.contains(item.id)`; if colliding, advance and try the next index. Insert into `reservedIds` before returning the `ImageWithMetadata`.
- `nextMediaItem()` — loop until it finds an item whose id is not reserved, bounded by one full pass through `shuffledIndices` (with a reshuffle allowed). If a full pass yields no candidate, return nil.
- New `func release(id: String)` — removes from `reservedIds`. No-op if not present.
- `stop()` — also clears `reservedIds`.

### GridManager changes

- `cellMetadata` becomes `[Int: (id: String, title: String, year: Int?)]` (add id).
- `rotateCell(at:)` and `rotateCellImmediate(at:)` — after a successful `takeImage()` result is committed to the cell (end of crossfade path), call `await pool.release(id: oldId)` for the previous occupant (if any). The release must happen *after* the new item has been reserved (which `takeImage()` already guarantees), so there is never a window where the cell's outgoing id is unreserved before its replacement is reserved.
- `revealThenRotate` — capture `oldId` from `cellMetadata[index]` before overwriting, release it inside the `asyncAfter` block after `cellMetadata[index]` is updated to the new item.

### Release timing

Release happens after the new item is live in the cell, not before. This keeps the outgoing id reserved during the reveal-and-crossfade window (~3s), preventing any concurrent cell rotation during that window from picking the same item.

## Why this works for cycle-wrap collision

The reported bug: end-of-cycle reshuffle places a currently-on-screen item at the front of the new cycle. Under the new scheme, that item's id is in `reservedIds` (it's on screen), so `nextMediaItem()` skips it and advances until it finds an unreserved one. The collision is impossible by construction.

## Files Changed

| File | Change |
|------|--------|
| `ImagePipeline/ImagePool.swift` | Add `id` to `ImageWithMetadata`; add `reservedIds` set; filter in `nextMediaItem()`; bounded retry; new `release(id:)`; clear set in `stop()` |
| `Grid/GridManager.swift` | Track `id` in `cellMetadata`; call `pool.release(id:)` after each rotation commits |

No provider/model changes — `MediaItem.id` already exists.

## Out of Scope

- **Small-library fallback UI.** If the library has fewer unique items than grid cells, affected cells stay black. No warning banner, no shrink-the-grid logic.
- **Duplicate detection across multiple Plex/Jellyfin servers.** Ids are assumed unique within the active provider's namespace.
- **Persistence of reservation across screensaver restart.** The set is in-memory only; a fresh screensaver launch starts with an empty set, which is correct.

## Verification

1. **Unit test (ImagePool):** Construct a pool with a mock provider returning N items, pre-fill to `N`, take all, assert all ids unique. Release one id, call `fetchNextImage`, assert returned id equals the released one (it is now the only available item).
2. **Unit test (cycle-wrap):** With N=4 items and grid of 3 cells, rotate 10 times. Track the set of ids "currently displayed" across rotations. Assert the set never contains duplicates at any point.
3. **Manual:** Run screensaver against a library with ~20 items on a 16-cell grid; observe for several minutes across multiple cycle wraps. No visible duplicates.
