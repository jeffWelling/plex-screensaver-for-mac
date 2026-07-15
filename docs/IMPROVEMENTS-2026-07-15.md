# Montage — Uniqueness-Goal Review 2026-07-15

_Reviewed at commit `df749ba` (v0.4.3; working tree still carries the
uncommitted v0.4.4 thumbnail work described in `TODO-thumbnail-resume.md`).
Every Swift source file was read end-to-end for this review._

## Framing

The product goal under review: **never display the same fanart at the same
time across any monitor the screensaver is active on.**

The v0.4.2 mechanism (`ReservationRegistry` actor + reserve-at-pool-entry +
release-after-crossfade, per `docs/plans/2026-04-12-unique-fanart-on-screen-design.md`)
is sound for its steady state: Phase-2 rotation, single process. This review
found the places where the guarantee does NOT hold, plus a set of unrelated
findings, removals, and additions. It does not repeat
`docs/IMPROVEMENTS-2026-07-09.md` (all 17 items of which remain open — HEAD
has not moved since that review); where an item here overlaps, it
cross-references and re-prioritizes instead.

Line references are from `df749ba` and will drift — search by symbol.

## Reading order for the implementing session

1. Do **U0 first**. It is pure verification and its outcome decides the
   architecture for U1–U4.
2. U3 (freeze + leak) is the smallest high-value code change and has no
   dependencies.
3. U1/U2 as one unit of work. Then U4. Then the N/R/A items in any order.

## Table of contents

| # | Item | Priority | Effort |
|---|------|----------|--------|
| U0 | Verify the single-process assumption behind ReservationRegistry | P0 | S (verify) |
| U1 | Phase-1 cached rotation bypasses the reservation system | P1 | M |
| U2 | Phase 1→2 handoff: cross-phase duplicate window + full-grid snap | P2 | S |
| U3 | Pool-drain freeze + reservation leak degrade uniqueness over time | P1 | S+M |
| U4 | Over-reservation starves small libraries and second monitors | P1 | M–L |
| U5 | Reservation identity semantics: same movie / same artwork edge cases | Decision | S–M |
| N1 | Jellyfin deviceId & Plex clientIdentifier stored in the wrong prefs domain | P2 | S |
| N2 | No memory budget: ~200–300 MB across two monitors | P2 | S–M |
| N3 | DiskCache validateConfig ignores library-selection changes | P3 | S |
| N4 | Grid layout ignores per-monitor aspect ratio | P3 | M |
| N5 | `exit(0)` willStop hack — verify still needed on Tahoe | P3 | S (verify) |
| R1–R5 | Removals: dead API, dead tracker code, stale screenshots, version overlay, parked commit | P3 | S |
| A1 | Reservation-invariant property test (sharpens 07-09 item 5) | P1 | M |
| A2 | Debug HUD for pool/registry observability | P2 | S |

---

## U0 — Verify the single-process assumption behind ReservationRegistry — **P0, verify-first**

**Problem.** `ReservationRegistry` is an in-process singleton actor
(`PlexSaver/ImagePipeline/ImagePool.swift:20-35`). The entire cross-monitor
guarantee rests on macOS hosting *all* displays' `MontageView` instances in
**one** `legacyScreenSaver` process. Apple has churned the wallpaper/screensaver
hosting model across Sonoma/Sequoia/Tahoe. If each display gets its own host
process, the registry provides zero cross-monitor protection — the goal is
silently broken while all in-process logic (and any unit test) passes.

**How to verify it exists (i.e., which world we're in).**
1. Every log line embeds the emitting PID: `MO (P:%d)` (`Helpers/Logger.swift:17`
   — the `%d` is a scalar, public by default, so it survives `%{private}`
   redaction).
2. With ≥2 monitors attached, start the real screensaver (hot corner /
   idle — not SaverTest, not the System Settings preview) and run:
   `log stream --predicate 'subsystem == "com.montage.Montage"' --level default`
3. Look at the `init`/`startAnimation` lines for both instances
   (`MontageView.swift:73, 120` log instance number and frame size — two
   instances with different frames should appear).
   - **Same PID on both** → single process; registry design is valid; proceed
     with U1–U4 as written.
   - **Different PIDs** → multi-process; the in-memory registry is a no-op
     across monitors and U1–U4's fixes must build on a cross-process registry.
4. Corroborate with `pgrep -fl legacyScreenSaver` while the saver is running.

**How to verify it's fixed (multi-process case only).** After implementing a
cross-process registry, repeat the log check and confirm via the debug HUD
(A2) or reservation logging that a path reserved by PID A is refused to PID B.

**Fix sketch (only if multi-process).** File-based claims in the existing
Application Support dir (`~/Library/Application Support/com.montage.Montage/`):
a `reserved/` directory where reserve = create `sha256(artPath)` with
`O_CREAT|O_EXCL` (atomic on APFS), release = unlink, and startup sweeps stale
claims older than a few minutes (a crashed process must not poison the pool —
claim files should embed PID + timestamp so survivors can reap them).
Alternative: keep the actor as a fast path and add the file layer only when
`InstanceTracker` detects it's not alone — but simplest is one code path.

**Context.** This is 15 minutes of verification that decides the shape of
several days of work. Do it before anything else. Note the System Settings
*preview* always runs in a different process (System Settings) than the real
saver — that pair never displays simultaneously with the lock-screen saver, so
it is out of scope; only monitor-vs-monitor matters.

---

## U1 — Phase-1 cached rotation bypasses the reservation system — **P1, M**

**Problem.** The cached-image phase never touches `ReservationRegistry`:
- `fillGridWithCachedImages` assigns `cachedImages[i % cachedImages.count]`
  (`MontageView.swift:509-517`) — modulo wrap guarantees duplicate tiles on a
  single screen whenever cached count < cell count.
- `rotateCachedCell` walks a sequential index into a random cell
  (`MontageView.swift:530-536`) with no awareness of what's displayed.
- Every monitor's `MontageView` independently loads the same disk cache in the
  same order — `DiskCache.allCachedImages(limit:)` sorts by `lastAccess`
  descending (`ImagePipeline/DiskCache.swift:153-165`) — so a two-monitor
  setup shows **near-identical grids on both screens** for the whole cached
  phase.

Phase 1 is not just a startup flash: offline mode (a headline README feature)
runs Phase 1 **indefinitely**. The 2026-07-09 review has the single-screen
half of this as item 15 at P3 "polish"; against the stated product goal the
cross-monitor half makes it P1.

**How to verify it exists.**
- Code-level (fastest): `grep -n "ReservationRegistry" PlexSaver/MontageView.swift`
  → no matches. The Phase-1 path provably cannot coordinate.
- Runtime: populate the disk cache normally, then disconnect the Mac from the
  network (Wi-Fi off) so Phase 2 never takes over. Start the saver on two
  monitors. Observe: both screens show substantially the same images; with a
  small cache (delete most of `~/Library/Application Support/com.montage.Montage/images/`
  and the matching manifest entries, or just a fresh cache with few items),
  duplicates appear within one screen too.

**How to verify it's fixed.** Same offline two-monitor setup: no artwork
appears twice across both screens at any moment (when the cache has enough
unique images), and a too-small cache degrades to black cells or fewer
distinct images — never duplicate tiles. Unit-testable once A1's harness
exists: Phase-1 selection should route through the same reservation API.

**Fix sketch.**
1. Change `DiskCache.allCachedImages(limit:)` to return `[(key: String,
   image: NSImage)]` — the key (artPath) is right there in the manifest entry.
2. In `MontageView`, keep `cachedImages` as keyed pairs. On fill and on each
   `rotateCachedCell`, pick via `ReservationRegistry.shared.reserve(key)` —
   skip keys already reserved; release the outgoing cell's key after its
   crossfade (mirror `GridManager.scheduleRelease`, `Grid/GridManager.swift:235-241`).
3. Shuffle the cached list instead of using LRU order, so two monitors that
   race the same cache don't even *try* the same sequence (less registry
   contention, more variety).
4. On handoff (`stopCachedRotation`, `MontageView.swift:538-543`), release all
   Phase-1 reservations held by this view.

**Context.** The registry works offline — it's just process memory (subject to
U0). Keep the release bookkeeping in `MontageView` symmetrical with
`ImagePool.reservedArtPaths` (`ImagePool.swift:52-56`): track what this view
reserved so teardown can release exactly that set. Note `hasDisplayedFirstImage`
in `GridCell` means the initial fill shows through a fade overlay — behavior
should be preserved.

---

## U2 — Phase 1→2 handoff: cross-phase duplicate window + full-grid snap — **P2, S**

**Problem.** Two halves:
1. *Correctness:* monitors hand off from cached to live rotation
   independently. While monitor A is still on Phase 1 (unreserved images) and
   monitor B is on Phase 2 (reserved pool), B cannot see what A displays →
   the same art can sit on both screens until A's handoff completes. **Fixing
   U1 fixes this automatically** (Phase-1 images become reserved like
   everything else). Listed separately so the window is explicitly re-tested.
2. *Visual:* at handoff, `GridManager.startRotation` fills every cell at once
   via `rotateCellImmediate` with `transitionDuration: 0`
   (`Grid/GridManager.swift:92-95, 171-184`). On a cold start this hides
   behind the fade overlay, but in the cached-start path the overlay is
   already gone (`fadeInGrid` ran in Phase 1, `MontageView.swift:398-401`) —
   the entire grid hard-cuts in one frame.

**How to verify it exists.**
- Correctness half: hard to catch by eye; verify by code inspection until U1
  lands (Phase-1 images unreserved by construction), then re-run the U1
  two-monitor test with the network *connected*, watching the first ~30 s.
- Visual half: with a warm cache and working network, start the saver and
  watch the moment "Phase 2 — switching to live pool" logs — the whole mosaic
  snaps simultaneously.

**How to verify it's fixed.** The handoff is imperceptible: cells crossfade to
pool images individually over a few seconds, and no duplicate appears across
screens during the transition.

**Fix sketch.** In `startRotation`, stagger initial fills: schedule each
cell's first rotation over `min(rotationInterval, ~3s)` with the normal
crossfade duration instead of 0, or reuse the existing weighted rotation loop
and simply let it take over from the (now-reserved) cached images cell by
cell. If a cached image and its pool replacement are the same artwork, skip
the crossfade for that cell (compare artPath — possible once U1 gives Phase-1
cells keys).

---

## U3 — Pool-drain freeze + reservation leak degrade uniqueness over time — **P1, S+M**

**Status: these are items 1 and 2 of `docs/IMPROVEMENTS-2026-07-09.md`,
re-verified present at `df749ba`.** Full write-ups live there; this entry adds
the uniqueness-goal framing and verification detail, and does not repeat the
full analysis.

**Problem (summary).**
- *Freeze:* `ImagePool.takeImage()`'s empty-pool guard sits before the refill
  trigger (`ImagePool.swift:116-125`) and `refillPool()` breaks on the first
  failed fetch (`ImagePool.swift:227-240`). A network blip — or a moment where
  every unreserved path is taken (small library, see U4) — drains the pool
  into a state that never refills. Result: rotation silently freezes; the
  uniqueness machinery stops being exercised at all.
- *Leak:* overlapping rotations of the same cell (no per-cell transition
  guard; `rotateWeightedRandomCell` can repick a mid-transition cell,
  `Grid/GridManager.swift:118-147`) capture the same `outgoing` metadata in
  `revealThenRotate` (`GridManager.swift:210-231`) → the interloping item's
  artPath is overwritten in `cellMetadata` without ever being released. Each
  occurrence **permanently shrinks the pickable library** (registry entry
  stranded until restart), ratcheting toward the freeze.

**How to verify they exist.**
- Freeze: with the saver running normally, block the media server for ~5
  minutes (stop the Plex/Jellyfin container, or `networksetup -setairportpower
  en0 off` on the Mac), then restore. Watch: rotation never resumes; log shows
  no further "Pre-filling"/fetch activity. Code-level: read the guard order in
  `takeImage()`.
- Leak: set `RotationInterval` to its minimum and grid to 1×1 (worst case:
  the only cell is repicked every tick) with title reveal on. Without a HUD
  (A2) the strand is invisible at runtime — until A2 exists, verify by code
  inspection or by unit test (A1's harness can drive `rotateCell` twice
  concurrently and assert the registry count returns to on-screen count).

**How to verify they're fixed.**
- Freeze: repeat the server-blip test; rotation must resume within one retry
  interval (~30 s) of the server returning. Add a regression unit test:
  drain pool to empty with a failing provider, restore provider, assert
  `takeImage()` eventually succeeds again.
- Leak: 1×1-grid stress test for 10+ minutes; registry size (via A2 HUD or a
  debug log) never exceeds cells-on-screen + pool size.

**Fix sketch.** Exactly as 07-09 items 1–2 prescribe: unconditional refill
check in `takeImage()` + bounded retry-with-delay in `refillPool()`; per-cell
`transitioningCells: Set<Int>` guard excluded from the weighted pick + re-read
`cellMetadata[index]` inside the delayed closure.

---

## U4 — Over-reservation starves small libraries and second monitors — **P1, M–L**

**Problem.** Reservation happens at *pool entry*, not at display time
(`ImagePool.nextMediaItem`, `ImagePool.swift:162-185`). Each monitor holds
`poolSize = cells × 3` pooled reservations (`MontageView.swift:431-432`) plus
up to `cells` on-screen — ≈ **4× cells per monitor**. Two monitors at the
default 3×4 grid lock ~96 art paths. Consequences when the selected libraries
have fewer unique art paths than that:
- Monitor 2's `prefill()` returns 0 (everything reserved by monitor 1) and the
  user sees *"Could not fetch images from Plex — check server connection"*
  (`MontageView.swift:476-487`) — a false diagnosis of a healthy setup.
- Even one monitor with a small library sits close to the reservation ceiling,
  making the U3 freeze path easy to enter.

**How to verify it exists.** Select a single small library (or temporarily a
collection with, say, 30 items) in preferences. Two monitors, warm network.
Observe monitor 2 showing the "Could not fetch images" error while monitor 1
works. Single-monitor variant: library with < `cells × 3` items → prefill
logs show a short pool, and rotation starves quickly.

**How to verify it's fixed.** Same small-library setup: both monitors fill
and rotate (possibly with reduced variety — that's acceptable degradation);
no false error message; no freeze after extended runtime.

**Fix sketch — two tiers, pick one:**
1. *Cheap (per-pool):* move reservation to **take time**. Pool holds
   unreserved candidates; `takeImage()` attempts `reserve()` on the head,
   skipping entries that got reserved elsewhere in the meantime; release stays
   as-is. Reservation pressure drops to exactly what's on screen
   (`cells × monitors`). **Trade-off:** today, pool-entry reservation
   accidentally dedupes network fetches across monitors (two pools can never
   hold the same path). Moving reservation later reintroduces duplicate
   fetches — add in-flight request coalescing keyed by artPath in `DiskCache`
   or the fetch path.
2. *Right (architectural):* **one shared `ImagePool` across all displays**
   (07-09 item 14 step 2), sized `totalCellsAcrossScreens × 3`, with each
   `GridManager` drawing from it. This also collapses N× library fetches, N×
   image downloads/decodes, and the manifest-clobbering race between N
   `DiskCache` actors rewriting one `manifest.json`
   (`DiskCache.swift:274-279`). `InstanceTracker`
   (`Helpers/InstanceTracker.swift`) — currently vestigial, see R2 — is the
   natural owner; gate pool teardown on the last instance stopping.

**Context.** If U0 reveals a multi-process world, tier 2 is off the table
as-written (no shared process to own the pool) and tier 1 + file-based
registry becomes the path. Decide after U0. Jeff's homelab library is large,
so this mostly bites the error-message UX and edge configs — but the false
"check server connection" is the kind of thing that wastes a debugging evening.

---

## U5 — Reservation identity semantics: what exactly must be unique? — **Decision needed, S–M**

**Problem.** Reservations key on `artPath`. Three edge cases where "the same
thing" appears twice despite (or because of) that key:
1. **`.mixed` mode, same movie twice:** `MediaItem.artPath(for: .mixed)`
   returns a random path per call (`Providers/MediaModels.swift:23-30`), so
   the same movie can display simultaneously as poster on one monitor and
   fanart on another — different artPaths, same title. If the goal is "never
   the same *artwork*," current behavior is correct; if "never the same
   *title*," it's a bug.
2. **Same movie in two libraries** (e.g., Movies + 4K Movies): different
   ratingKeys → different artPaths → **visually identical fanart** can show
   on two monitors at once. No artPath-keyed registry can catch this.
3. **Jellyfin backdrop index:** fanart always uses `/Items/{id}/Images/Backdrop`
   (index 0) (`Jellyfin/JellyfinModels.swift:113-115`). Adding random backdrop
   indexes for variety (a nice add) would create more per-item paths and make
   case 1's semantics matter for Jellyfin too.

**How to verify.** Case 1: set Image Source to Mixed, run two monitors,
watch for the same title in both orientations (grep the title-reveal pills).
Case 2: `grep`-level — query Plex for duplicate (title, year) across selected
sections; if any exist, the collision is possible by construction.

**How to verify it's fixed.** After the decision: unit test in A1's harness —
attempting to take two paths belonging to the same item id fails when
item-level uniqueness is chosen; `loadMediaItems` dedupes (title, year) pairs
across libraries.

**Fix sketch (if item-level uniqueness is chosen).** Reserve a composite:
registry tracks both `artPath` and `itemKey` (provider id, or `title|year`
for cross-library dedupe). `nextMediaItem` skips items whose itemKey is
reserved. Cheapest useful subset: dedupe `mediaItems` by `(title, year)` at
load time in `ImagePool.loadMediaItems` (`ImagePool.swift:70-96`) — kills
case 2 outright with ~5 lines and no registry change.

**Context.** This needs Jeff's call on intent before implementation: strict
artwork-uniqueness (current), or title-uniqueness (stronger, slightly less
variety). Recommendation: title-uniqueness — two monitors showing the same
movie's poster and fanart *reads* as a duplicate to a human.

---

## N1 — Jellyfin deviceId & Plex clientIdentifier live in the wrong prefs domain — **P2, S**

**Problem.** `JellyfinAuth.deviceId` (`Jellyfin/JellyfinAuth.swift:14-22`) and
`PlexAuth.clientIdentifier` (`Plex/PlexAuth.swift:49-58`) persist via
`UserDefaults.standard` — the **host process's** domain. This is the exact bug
class documented in `Helpers/AppConstants.swift:13-19`: the config sheet runs
in System Settings, the saver in `legacyScreenSaver`, so each mints and
persists a *different* ID. The Jellyfin token is issued against the config
host's DeviceId but runtime requests present the saver host's DeviceId in the
auth header (`Jellyfin/JellyfinClient.swift:117-120`). Works today, but
produces duplicate device registrations server-side and can break "revoke
device" semantics. (Plex's clientIdentifier is only used during config-time
flows — PIN + discovery — so it's consistent within a session; fix it for
hygiene while in there.)

**How to verify it exists.** Sign in to Jellyfin via the config sheet, then
let the real saver run. Jellyfin Dashboard → Devices: two "Montage"/"Mac"
device entries with different DeviceIds appear.

**How to verify it's fixed.** Delete both stale device entries server-side,
clear the two `UserDefaults.standard` keys (`JellyfinDeviceId`,
`PlexClientIdentifier`) in *both* host domains, re-auth, run the saver:
exactly one device entry, stable across config + runtime.

**Fix sketch.** Store both IDs via
`ScreenSaverDefaults(forModuleWithName: AppConstants.module)` (same pattern as
`Preferences`). Migration: read `UserDefaults.standard` first, copy into the
shared domain, prefer the shared domain thereafter — otherwise existing users'
runtime ID changes once more (acceptable, but note it).

---

## N2 — No memory budget — **P2, S–M**

**Problem.** Per monitor: pool of `cells × 3` decoded `NSImage`s + `NSCache`
capped by **count** at `poolSize × 2` (`ImagePool.swift:64`,
`ImagePipeline/ImageCache.swift:15-16`). At default 3×4 grid on Retina
(~960×540 px cell images), that's ~48 pool + up to 96 cached images ≈ 2 MB
each decoded → roughly 200–300 MB across two monitors, with transient doubling
during `DiskCache.store`'s TIFF re-encode (`DiskCache.swift:170-175`, already
07-09 item 8). Count-based NSCache limits don't distinguish a 4K fanart from a
small poster.

**How to verify it exists.** Run the saver 10+ minutes on two monitors;
check `footprint $(pgrep legacyScreenSaver)` or Activity Monitor's memory for
the host process.

**How to verify it's fixed.** Same measurement after fixes lands under an
agreed budget (suggest: <100 MB per monitor steady-state).

**Fix sketch.** (a) `NSCache.totalCostLimit` in bytes with per-image cost =
pixel bytes; (b) shared pool from U4 tier 2 halves everything; (c) 07-09
item 8 (store raw network bytes) removes the TIFF spike; (d) consider
`CGImageSourceCreateThumbnailAtIndex` downsampling to exact cell size (also
07-09 item 10's pre-decode).

---

## N3 — DiskCache validateConfig ignores library-selection changes — **P3, S**

**Problem.** Cache validity is keyed on `(serverURL, imageSource)` only
(`DiskCache.swift:87-108`). Deselecting a library keeps its images in the
disk cache, and Phase 1 happily shows art from libraries the user just
excluded (Phase 2 self-corrects since `loadMediaItems` refetches).

**How to verify it exists.** Cache warm with library X selected; deselect X;
relaunch the saver offline (or watch the first seconds online): X's art still
appears in the cached phase.

**How to verify it's fixed.** Same steps → no art from deselected libraries
in Phase 1.

**Fix sketch.** Don't nuke the cache for this (opposite direction of 07-09
item 9 — URI churn should *preserve* cache). Instead, record each entry's
originating library id in the manifest (`CacheEntry` gains an optional field;
older manifests decode fine), and have Phase-1 selection filter to
currently-selected libraries. Requires threading library id through
`ImagePool.loadImage` → `DiskCache.store`.

---

## N4 — Grid layout ignores per-monitor aspect ratio — **P3, M**

**Problem.** `gridRows`/`gridColumns` are global preferences applied to every
display (`MontageView.swift:304-316`). A portrait or ultrawide secondary
monitor gets the same 3×4 grid, and `resizeAspectFill`
(`Grid/GridCell.swift:40-44`) crops fanart heavily when cell aspect strays
from ~16:9. (Even the default case crops: 3×4 on 16:9 gives 4:3 cells.)

**How to verify it exists.** Rotate a monitor to portrait (or use SaverTest
resized tall); observe severe crops / heads cut off.

**How to verify it's fixed.** Same setups show sensibly-proportioned cells;
per-display cell aspect stays within a tolerance band of the source aspect
(16:9 fanart / 2:3 posters).

**Fix sketch.** Add an "Auto" grid mode: given the display bounds and the
source type's target aspect, keep the user's row count and compute columns
per display as `round(width / (height/rows × targetAspect))` (or compute both
from a target cell diagonal). Keep manual rows×columns as an override.

---

## N5 — `exit(0)` willStop hack: verify still needed on Tahoe — **P3, verify**

**Problem.** `handleWillStop` schedules `exit(0)` 2 s after the
`com.apple.screensaver.willstop` distributed notification
(`MontageView.swift:590-596`). This is the known community workaround for
legacyScreenSaver lingering after dismissal (stale saver kept running behind
the lock screen). It kills the *entire host process* mid-teardown — acceptable
as a hack, but the project already has Tahoe-specific handling
(`MontageView.swift:56-62`), and if Tahoe fixed the lingering, the hack is
pure risk.

**How to verify it's still needed.** Comment out the `exit(0)` (or gate on a
debug default), install, dismiss the saver, then check `pgrep -fl
legacyScreenSaver` after ~30 s and re-trigger the saver: does the old instance
linger / does re-entry show stale state or duplicate `MontageView` instances
(log instance numbers climbing without deinit lines)?

**How to verify a change is safe.** Locking/unlocking + saver start/stop ×10
across both monitors: no lingering processes, no duplicate instances, disk
manifest not corrupted (writes are atomic — `DiskCache.swift:278` — so the
risk is low).

**Fix sketch.** If still needed: keep, but add a comment block citing the
lingering bug and gate it strictly (it already only registers for non-app,
non-preview instances, `MontageView.swift:88-96`). If not needed on Tahoe:
`if #available(macOS 26.0, *)` skip the observer.

---

## R1–R5 — Removals — **P3, S each**

- **R1. Dead `testConnection()` + dead error cases.** 07-09 item 17, still
  present: `MediaProvider.testConnection` (`Providers/MediaProvider.swift:23`),
  both client/provider impls, and never-thrown `PlexError.noLibraries/
  .noMediaItems` (`Plex/PlexClient.swift:106-107`) + Jellyfin equivalents
  (`Jellyfin/JellyfinClient.swift:130-131`). Verify: `grep -rn testConnection`
  shows the view model calls `fetchLibraries` directly
  (`ConfigurationViewModel.swift:287, 370`). Delete; compiler verifies.
- **R2. `InstanceTracker.totalInstances` is dead.** Zero call sites
  (verified: only the definition matches). Either delete the instances
  dictionary (keep `isRunningInApp` + the counter for log numbering) or
  repurpose the class as the shared-pool owner per U4 tier 2. Decide alongside
  U4.
- **R3. Stale March-era screenshots.** `docs/screenshots/screensaver.png` and
  `preferences.png` are tracked but unreferenced by README. Delete.
- **R4. Version overlay shows on every activation.** 5 s of "v0.4.x (build)"
  on all monitors on every start (`MontageView.swift:264-300`). Make it
  app/preview-only or a hidden pref (`ShowVersionOverlay`, default false).
- **R5. Land the parked v0.4.4 commit.** 07-09 item 16 /
  `TODO-thumbnail-resume.md`: staged commit plan exists, **censor gate**
  (verify `preferences-plex.png` shows `your-server.plex.direct`, not the real
  IP-based hostname) must run at staging time. Do this before any work that
  touches README/pbxproj to avoid entangling diffs. Do not commit the TODO
  file itself.

---

## A1 — Reservation-invariant property test — **P1, M**

**What.** Sharpens 07-09 item 5 (zero automated tests) with the single test
that matters most for the product goal: a harness with a mock `MediaProvider`
(N items, deterministic art paths, controllable failures) driving 2+
`ImagePool`s and simulated cells through random interleavings of
take/display/release/refill/stop, asserting after every step:
1. no artPath is reserved by two holders;
2. the union of pooled + on-screen paths contains no duplicates (the invariant
   from `docs/plans/2026-04-12-unique-fanart-on-screen-design.md`);
3. registry size returns to zero after all pools stop (leak detector — catches
   U3's leak class).

**Prerequisite.** Make the registry injectable (`ImagePool` takes a
`ReservationRegistry` in init, default `.shared` — `ImagePool.swift:178, 197`
are the two hardcoded uses) so tests don't share global state.

**Verify.** `make test` runs it; CI runs it; U3's fixes each get a regression
case in the same harness.

## A2 — Debug HUD — **P2, S**

**What.** A hidden preference (`ShowDebugHUD`) rendering a small overlay:
pool depth, this-view reserved count, global registry size, last-refill
result/time, per-cell artPath tail (last 8 chars). Every uniqueness bug in
this review survived because the invariant is invisible at runtime — two
monitors can only be eyeballed. The HUD turns U1/U3/U4 verification from
"stare at two screens" into "read two numbers."

**Fix sketch.** `ReservationRegistry` gains a `count` accessor; `ImagePool`
gains a `stats()` snapshot; `MontageView` renders a `CATextLayer` updated on a
1 s timer when the pref is set. Strictly read-only.

---

## Explicitly re-prioritized from 2026-07-09

| 07-09 item | Old | New | Reason |
|---|---|---|---|
| 15 (Phase-1 duplicates) | P3 | P1 (as U1, expanded) | Directly violates the stated cross-monitor goal; offline mode makes it unbounded |
| 14 step 2 (shared pool) | P2/L | P1-adjacent (as U4 tier 2) | Subsumes starvation, N× fetch waste, and the manifest race in one design |

All other 07-09 priorities stand as written.

---

## Status — 2026-07-15 fix pass

Every item below was implemented and the code builds (`xcodebuild -scheme
PlexSaver` and `-scheme SaverTest`, Debug, both **BUILD SUCCEEDED**) with the new
unit suite green (`make test` → 18 tests, 0 failures). Version bumped 0.4.4 →
0.5.0. Nothing pushed. Items marked **needs-runtime-verification** are correct by
construction and unit-tested where possible but have a runtime aspect only Jeff
can confirm (a second monitor, a Jellyfin dashboard, or a lock/unlock cycle).

**U0 verdict: INCONCLUSIVE.** This Mac has a single built-in display, so the 14
days of `com.montage.Montage` logs are all single-monitor sessions — one PID and
one MontageView instance each, never overlapping — which can neither confirm nor
refute the multi-monitor single-process assumption, and log payloads are
`<private>` so instance numbers aren't readable. The interactive two-monitor test
isn't runnable here. Per the decision rule, built **U4 tier 1** (correct
regardless of process model), not the tier-2 shared pool or a file-based
cross-process registry. Remaining risk: if a future multi-monitor Tahoe setup
turns out to host each display in its own process, the in-memory registry gives
no cross-monitor guarantee and a file-based registry would be needed — flagged
here and in the report.

| # | Item | Outcome | Notes |
|---|------|---------|-------|
| U0 | Verify single-process assumption | needs-runtime-verification | INCONCLUSIVE (single-display Mac; logs private). Drove the U4 tier-1 choice. Two-monitor log check still owed. |
| U1 | Phase-1 bypasses reservation | fixed | `allCachedImages` returns keyed pairs; Phase 1 reserves via registry, shuffles, releases on handoff/teardown. Two-monitor offline no-dup check owed. |
| U2 | Phase 1→2 handoff dup + snap | fixed | Staggered crossfade takeover (`startRotation(staggered:)`); cross-phase window closed by U1. Two-monitor visual check owed. |
| U3 | Pool-drain freeze + reservation leak | fixed | Unconditional refill trigger + bounded retry-with-delay; `transitioningCells` guard + re-read outgoing. Two regression tests added. |
| U4 | Over-reservation starves libs/monitors | fixed (tier 1) | Reserve-at-take + in-flight coalescer + injectable registry. No shared pool (U0 inconclusive). Two-monitor small-library check owed. |
| U5 | Reservation identity semantics | fixed | Title-level uniqueness: registry reserves artPath + `title|year`; `loadMediaItems` dedupes by (title, year). `.mixed` preserved. Test added. |
| N1 | deviceId/clientIdentifier prefs domain | fixed | Both persist via `ScreenSaverDefaults(module)` with migration from `.standard`. Jellyfin dashboard single-device check owed. |
| N2 | No memory budget | fixed | `NSCache.totalCostLimit` in bytes (cost = decoded pixel bytes). 07-09 items 8/10 left out of scope. |
| N3 | validateConfig ignores library selection | fixed | Optional `libraryId` per cache entry (older manifests decode); Phase 1 filters to selected libraries. |
| N4 | Grid ignores per-monitor aspect | fixed | Opt-in "Auto-fit columns" (`GridManager.autoColumns`, per display, keeps rows); manual default unchanged; wired into config UI. Portrait/ultrawide visual check owed. |
| N5 | `exit(0)` willStop hack | needs-runtime-verification | Log history inconclusive (all sessions ran with exit(0) active); kept behavior, added explanatory comment. Tahoe lingering check owed. |
| R1 | Dead testConnection + error cases | fixed | Removed from protocol, both providers, both clients; deleted never-thrown `.noLibraries`/`.noMediaItems`. Compiler-verified. |
| R2 | `InstanceTracker.totalInstances` dead | fixed | Deleted the counter dictionary + WeakRef (tier 1 chosen, so not repurposed); kept instance numbering. |
| R3 | Stale screenshots | fixed | Deleted `screensaver.png`, `preferences.png` (docs commit). |
| R4 | Version overlay every activation | fixed | Gated behind hidden `ShowVersionOverlay` (off); still shown in SaverTest. |
| R5 | Parked v0.4.4 commit | fixed | Committed thumbnail + screenshots + pbxproj + README; censor gate passed (`your-server.plex.direct`). TODO file removed. |
| A1 | Reservation-invariant property test | fixed | SwiftPM test package (`MontageCore`); 18 tests incl. 400-step 2-pool invariant + leak detector, U3 regressions, pure-logic. `make test` + CI wired. |
| A2 | Debug HUD | fixed | Hidden `ShowDebugHUD` overlay: phase, pool depth/capacity, reserved count, registry total, last refill. Read-only. |

### Owed to Jeff (runtime verification)

- **U0 / U1 / U2 / U4** — attach a second monitor: (U0) with a private-data
  logging profile, confirm both displays' `init` lines share one PID; (U1/U2)
  offline (Wi-Fi off, warm cache) confirm no artwork repeats across screens and
  the Phase 1→2 handoff crossfades rather than snaps; (U4) select a single small
  library and confirm monitor 2 fills instead of showing "Could not fetch
  images", with no freeze over time. The `ShowDebugHUD` default makes these
  readable at a glance.
- **N1** — Jellyfin Dashboard → Devices: after clearing stale entries and
  re-authing, confirm exactly one Montage device, stable across config + runtime.
- **N4** — rotate a monitor to portrait (or use an ultrawide) with Auto-fit on
  and confirm cell proportions track the source aspect.
- **N5** — on Tahoe, temporarily gate out `exit(0)`, dismiss the saver, and check
  `pgrep -fl legacyScreenSaver` for a lingering instance / duplicate MontageView
  instances on re-entry. If it no longer lingers, the hack can be dropped.
