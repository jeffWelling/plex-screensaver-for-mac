# Montage — Improvement Review 2026-07-09

_Reviewed at commit `df749ba` (v0.4.3 committed; working tree has uncommitted v0.4.4
pbxproj/README/thumbnail changes). `xcodebuild -scheme PlexSaver -configuration Debug`
verified: **BUILD SUCCEEDED** on this tree._

## Overview / repo health

The project is in good shape. The 2026-07-04 review (`docs/IMPROVEMENTS.md`) drove a
substantial hardening pass that has **landed and merged** (`8d1f9ee`, merged in
`e82db61`): tokens now live in the Keychain with legacy migration
(`PlexSaver/Helpers/KeychainStore.swift`, `Preferences.swift`), the preference-domain
bug is fixed via `AppConstants.module`, Plex discovery prefers HTTPS and dedupes,
logging is `%{private}`, Jellyfin pagination works, timers are single-registered, the
title-reveal clamp is correct, Retina/per-screen backing scale is handled, and a
GitHub Actions build workflow exists. A `ReservationRegistry` actor (added in
`c97a5b0`) dedupes on-screen art across cells and monitors.

What remains: **zero automated tests**, a handful of still-open items from the prior
review (verified below against current code — several of that report's line numbers
have drifted), and a few **new findings**, the most important being a rotation-freeze
failure mode introduced by the interaction of the pool-drain logic with the new
reservation registry (item 1).

This report is self-contained: each item re-states the problem with current file/line
references, so you do not need `docs/IMPROVEMENTS.md` to act on it. Items from that
report that are **not** repeated here were either verified fixed or judged not worth
carrying forward.

## Table of contents

| # | Item | Priority | Effort |
|---|------|----------|--------|
| 1 | Rotation can permanently freeze once the image pool drains | P1 | S |
| 2 | Overlapping same-cell rotations can strand a reservation forever | P1 | M |
| 3 | Jellyfin credentials sent over plaintext HTTP with no warning | P1 | S |
| 4 | Jellyfin networking uses `URLSession.shared` with no configured timeouts | P1 | S |
| 5 | Zero automated tests; `make test` doesn't run tests | P1 | L |
| 6 | No code signing / notarization in the release path | P1 | M |
| 7 | Plex fetches entire libraries in one unpaginated request | P2 | M |
| 8 | DiskCache re-encodes every image JPEG→TIFF→JPEG | P2 | M |
| 9 | Disk cache is nuked when the same server's URI changes | P2 | M |
| 10 | Image decode happens on the main thread at transition time | P2 | M |
| 11 | Duplicated HTTP plumbing between Plex and Jellyfin clients | P2 | M |
| 12 | ConfigurationViewModel: startup write-storm, manual actor hops, unconditional reload on sheet close | P2 | S |
| 13 | README log-viewing instructions are defeated by `%{private}` logging | P2 | S |
| 14 | Multi-display setups do N× network fetches, N× decode, N× cache | P2 | L |
| 15 | Phase-1 cached rotation can show the same image in adjacent cells | P3 | S |
| 16 | Repo hygiene: uncommitted v0.4.4 work, stale screenshots | P3 | S |
| 17 | Dead error cases and meaningless `testConnection` return value | P3 | S |

---

## P1 — valuable, do first

### 1. Rotation can permanently freeze once the image pool drains — **P1, S**

**Problem.** `ImagePool.takeImage()` (`PlexSaver/ImagePipeline/ImagePool.swift:116-126`)
begins with `guard !pool.isEmpty else { return nil }`. The background-refill trigger
(`pool.count < poolSize / 2 && !isRefilling`, lines 120-123) sits *after* that guard,
so **an empty pool never schedules a refill**. Meanwhile `refillPool()`
(lines 227-240) breaks out of its loop on the *first* `fetchNextImage()` failure —
which happens both on a transient network error and, since `ReservationRegistry` was
added, whenever every unreserved art path is momentarily taken
(`nextMediaItem()` returns nil, lines 162-185).

Two realistic sequences end in a permanently static grid:

- *Network blip:* Wi-Fi drops for a few minutes → each refill attempt breaks on its
  first failed fetch → rotations drain the pool to empty → every subsequent
  `takeImage()` returns nil via the guard and never re-triggers a refill. The
  screensaver freezes **even after the network comes back**, until the saver restarts.
- *Small library:* with `poolSize = cells × 3` and a library whose unique-art count is
  close to the number of grid cells, on-screen reservations plus pooled reservations
  can cover the whole library; `refillPool()` breaks, the pool drains, same terminal
  state. (Item 2's leak makes this strictly worse over time.)

`GridManager.rotateCell` (`PlexSaver/Grid/GridManager.swift:187-207`) silently does
nothing when `takeImage()` returns nil, so there is no visible error — just a frozen
mosaic.

**Proposed change.** In `ImagePool.swift`:
1. Move the refill trigger out of the non-empty path so it also fires when the pool is
   empty: compute `let item = pool.isEmpty ? nil : pool.removeFirst()`, then run the
   `pool.count < poolSize/2 && !isRefilling` check unconditionally before returning.
2. Make `refillPool()` resilient: instead of `break` on first failure, track
   consecutive failures and stop after N (e.g. 3), and/or schedule a delayed retry
   (`Task.sleep` ~30 s, re-check `isStopped`) when the pool is still below target.
   Keep the loop bounded so a dead server doesn't spin.

**Rationale.** This is the difference between "screensaver recovers when the network
returns" and "screensaver silently freezes until the Mac is unlocked and re-locked."
For an always-on ambient display, self-recovery is the core reliability property.

**Effort/risk.** S. Contained to one actor. Risk: a retry loop that is too eager could
hammer an unreachable server — bound attempts and use a delay.

### 2. Overlapping same-cell rotations can strand a reservation forever — **P1, M**

**Problem.** (Carried from prior review §3.2 — verified still open, and now with a
worse consequence.) There is no per-cell "in transition" guard.
`rotateWeightedRandomCell` (`PlexSaver/Grid/GridManager.swift:118-147`) uses a base
weight of 1.0 for every cell, so a cell that was just picked can be picked again on
the very next tick. A full transition (`titleDisplayDuration + crossfadeDuration`,
clamped to ≤ `rotationInterval` at `GridManager.swift:44-51`) plus the async actor hop
in `rotateCell` (`GridManager.swift:191-206`) can still be in flight when the second
rotation for the same cell starts.

When two `revealThenRotate` calls (`GridManager.swift:210-231`) overlap on one cell:
- both capture the *same* `outgoing` metadata at entry, so the same outgoing
  `artPath` is released twice, while the first closure's `newItem` — displayed for a
  moment, then overwritten in `cellMetadata` by the second closure — is **never
  released**. Its path stays reserved in `ReservationRegistry` (and in the pool's
  `reservedArtPaths`) until the saver restarts. Each occurrence permanently shrinks
  the usable library and feeds item 1's starvation path.
- the dual-layer crossfade bookkeeping in `GridCell.displayImage`
  (`PlexSaver/Grid/GridCell.swift:100-132`, `activeLayerIsFirst` flip at line 130) can
  flip out of sync, dropping a fade or blanking a layer.

**Proposed change.** In `GridManager`:
1. Add `private var transitioningCells: Set<Int> = []`. Insert the index when a
   rotation is chosen; remove it in a completion scheduled after
   `titleDisplayDuration + crossfadeDuration` (the same `asyncAfter` spine that
   already exists).
2. In `rotateWeightedRandomCell`, exclude transitioning cells from the weighted pick
   (skip the tick if all cells are transitioning).
3. Belt-and-braces in `revealThenRotate`: read `cellMetadata[index]` again *inside*
   the delayed closure rather than capturing `outgoing` at entry, so a lost race
   releases the actual current occupant.

**Rationale.** Fixes a visible glitch (double-fade/blank cell) and a slow resource
leak that degrades into item 1's freeze. All the code involved runs on the main
thread, so a plain `Set<Int>` is safe.

**Effort/risk.** M. Timing code; test with `rotationInterval` at the 2 s minimum and a
1×1 grid (worst case: single cell picked every tick).

### 3. Jellyfin credentials sent over plaintext HTTP with no warning — **P1, S**

**Problem.** (Prior review §1.2, the unfinished half.) Plex-side HTTPS preference is
done (`PlexAuth.discoverServers`, `PlexSaver/Plex/PlexAuth.swift:154-173`), but the
Jellyfin path still POSTs the username and **password** to
`\(baseURL)/Users/AuthenticateByName` over whatever scheme the user typed
(`PlexSaver/Jellyfin/JellyfinAuth.swift:26-51`). Nothing validates or normalizes the
URL; the UI's own placeholder actively suggests plaintext —
`.help("e.g. http://jellyfin.local:8096")` at
`PlexSaver/Configuration/ConfigurationView.swift:286` — and README.md:85 does the
same. A URL with no scheme at all (`jellyfin.local:8096`) fails deep in `URLSession`
with an opaque error surfaced verbatim (`ConfigurationViewModel.swift:339-344`).

**Proposed change.**
1. Add a small normalizer (e.g. in `ConfigurationViewModel.connectToJellyfin`,
   `PlexSaver/Configuration/ConfigurationViewModel.swift:310-346`): trim whitespace,
   prepend `https://` when no scheme is present, strip trailing `/`, validate with
   `URLComponents`.
2. If the resulting scheme is `http`, show an inline warning in `jellyfinLoginView`
   (`ConfigurationView.swift:282-315`) — e.g. a `Label` with
   `exclamationmark.triangle` and text "Password will be sent unencrypted" — and
   require a second click / explicit toggle before connecting.
3. Update the `.help` text and README.md:85 to lead with an `https://` example.

**Rationale.** The password is the user's real Jellyfin account credential. LAN-only
deployments make this common in practice, so a hard block is wrong — but silent
plaintext is worse. Informed consent is cheap to build.

**Effort/risk.** S. UI-only plus one string function; no protocol changes. Keep the
normalizer pure so it is unit-testable under item 5.

### 4. Jellyfin networking uses `URLSession.shared` with no configured timeouts — **P1, S**

**Problem.** (Prior review §5.1 — verified still open.) `PlexClient` builds a session
with 15 s request / 60 s resource timeouts (`PlexSaver/Plex/PlexClient.swift:19-22`),
but `JellyfinClient` uses `URLSession.shared` (`PlexSaver/Jellyfin/JellyfinClient.swift:19`)
and `JellyfinAuth.authenticate` calls `URLSession.shared.data(for:)` directly
(`PlexSaver/Jellyfin/JellyfinAuth.swift:47`). Default request timeout is 60 s per
request. A hung Jellyfin server stalls the config sheet's Connect button for a minute
(`isJellyfinConnecting` spinner, `ConfigurationViewModel.swift:316-345`) and slows the
saver's two-phase startup.

**Proposed change.** Mirror the Plex setup: in `JellyfinClient.init` create a
`URLSessionConfiguration.default` with `timeoutIntervalForRequest = 15`,
`timeoutIntervalForResource = 60`, store it in the existing `session` property (it is
already used consistently within the client). Give `JellyfinAuth` a `session`
property built the same way and use it in `authenticate`. If item 11 (shared
HTTPClient) is done first, this falls out of it for free — do whichever lands first.

**Rationale.** Consistency and a bounded worst-case for the interactive Connect flow.
Two-line-per-file fix.

**Effort/risk.** S. None beyond changing effective timeouts.

### 5. Zero automated tests; `make test` doesn't run tests — **P1, L**

**Problem.** (Prior review §8.1 — unchanged.) The project has no XCTest/Swift Testing
target (`grep -c 'XCTest\|\.xctest' PlexSaver.xcodeproj/project.pbxproj` → 0). The
`Makefile` `test:` target (Makefile:71-75) merely builds the SaverTest app.
CI (`.github/workflows/ci.yml`) builds both schemes but tests nothing. Every bug class
fixed in the last two review rounds (clamp math, pagination, LRU eviction, config
validation, URL encoding) was pure logic that a unit test would have locked in.

**Proposed change.**
1. Add a unit-test target (Swift Testing or XCTest) to `PlexSaver.xcodeproj` linked
   against the saver sources (or a new framework target both products share).
2. First tests, all pure logic needing no I/O or mocking:
   - `GridManager` init clamp: reveal disabled when
     `rotationInterval - crossfadeDuration <= 0.3` (`GridManager.swift:44-51`).
   - Weighted staleness selection distribution (`GridManager.swift:118-147`) — inject
     a seeded RNG or extract the pick into a `static func pick(weights:roll:)`.
   - `DiskCache.filename(for:)` determinism (`DiskCache.swift:282-286`),
     `normalizeServerURL` (`DiskCache.swift:112-118`), eviction/pruning math
     (`DiskCache.swift:59-71, 258-272`) — `DiskCache` already takes `maxSize` in init;
     add an injectable cache-directory URL for tests.
   - `ImagePool.nextMediaItem` reservation semantics with a stubbed
     `ReservationRegistry` (make the registry injectable instead of
     `ReservationRegistry.shared` at `ImagePool.swift:178, 197`).
   - `PlexMediaItem.artPath(for:)` / `toMediaItem()` (`PlexModels.swift:48-85`) and
     the Jellyfin equivalents (`JellyfinModels.swift:104-124`) with fixture JSON.
   - Regression tests for items 1 and 2 above once fixed.
3. Point `make test` at `xcodebuild test -scheme <TestScheme>` and add an
   `xcodebuild test` step to `ci.yml`.

**Rationale.** This codebase now has real invariants (reservation lifecycle, cache
manifests, clamp math) maintained across multiple agent sessions — exactly the
situation where silent regressions happen. It is the highest-leverage single item in
this report.

**Effort/risk.** L (mostly project-file plumbing). No runtime risk; keep the
`ReservationRegistry` injection default-argumented so production code paths don't
change.

### 6. No code signing / notarization in the release path — **P1, M**

**Problem.** (Prior review §9.2 — unchanged.) `make install` (Makefile:22-33) copies
an unsigned bundle locally; CI builds with `CODE_SIGNING_ALLOWED=NO`
(`.github/workflows/ci.yml:39`); the README "From Release" flow (README.md:33-38)
tells users to download and double-click an unsigned `.saver`. Gatekeeper on current
macOS quarantines unsigned downloaded bundles — users get "cannot be opened because
the developer cannot be verified" and must know the right-click-Open / xattr dance.

**Proposed change.**
1. Add a `release` GitHub Actions workflow (tag-triggered): build Release, `codesign
   --deep --options runtime` with a Developer ID Application identity (certificate +
   password in repo secrets), zip, `xcrun notarytool submit --wait`, staple, attach
   `Montage_v<version>.saver.zip` + a SHA-256 checksum file to the GitHub Release.
2. Until a paid Developer ID exists, the cheap interim fix is documentation: add the
   `xattr -dr com.apple.quarantine` / right-click-Open instructions to README's
   Installation section so release users aren't dead-ended.

**Rationale.** Distribution is the stated goal of the Releases flow; unsigned
screensavers are increasingly hostile UX on modern macOS.

**Effort/risk.** M (mostly Apple-account/secrets logistics; the workflow itself is
boilerplate). No code risk. Requires a paid Apple Developer membership — if that's a
blocker, do step 2 now and defer step 1.

---

## P2 — meaningful improvements

### 7. Plex fetches entire libraries in one unpaginated request — **P2, M**

**Problem.** (Prior review §3.6 — verified still open.) `PlexClient.fetchAllItems`
(`PlexSaver/Plex/PlexClient.swift:38-42`) requests
`/library/sections/{id}/all` with no `X-Plex-Container-Start`/`-Size`, so a
several-thousand-item library returns one enormous JSON body decoded fully in memory.
The Jellyfin side already pages properly (`JellyfinClient.fetchAllItems`,
`JellyfinClient.swift:38-68`) — the providers are now asymmetric.

**Proposed change.** Loop with `X-Plex-Container-Start` / `X-Plex-Container-Size`
request headers (page size ~500, matching Jellyfin's). Decode `totalSize` from the
`MediaContainer` (add the field to `PlexMediaContainer` in
`PlexSaver/Plex/PlexModels.swift:32-34`) and accumulate until reached, with the same
empty-page break the Jellyfin loop uses. Mirror the Jellyfin loop's shape so the two
read identically.

**Rationale.** Memory spike and long stall on large libraries during startup; also a
prerequisite for ever streaming/limiting the item list.

**Effort/risk.** M. Straightforward; verify against a real server that the container
headers are honored on `/all` (they are per Plex API docs).

### 8. DiskCache re-encodes every image JPEG→TIFF→JPEG — **P2, M**

**Problem.** (Prior review §4.6 — verified still open.) `DiskCache.store`
(`PlexSaver/ImagePipeline/DiskCache.swift:170-175`) takes the already-decoded
`NSImage`, inflates it to `tiffRepresentation` (a large uncompressed intermediate),
wraps it in `NSBitmapImageRep`, and re-encodes to JPEG at 0.85 — double lossy
compression of bytes the server already sent as JPEG, plus CPU and a transient
memory spike per stored image during prefill (up to `cells × 3` images).

**Proposed change.** Thread the raw network bytes through to the cache:
1. Change `MediaProvider.fetchImage` (`PlexSaver/Providers/MediaProvider.swift:20`) to
   return `(image: NSImage, data: Data)` — or add a parallel
   `fetchImageData(path:width:height:) -> Data` and construct the `NSImage` in the
   pool. Both clients already hold the raw `data` right before `NSImage(data:)`
   (`PlexClient.swift:53-64`, `JellyfinClient.swift:78-91`).
2. `ImagePool.loadImage` step 3 (`ImagePool.swift:213-224`) passes the raw `Data` to
   `DiskCache.store`, which writes it verbatim (keep `filename(for:)` and manifest
   bookkeeping unchanged; the extension may be a lie for PNG responses — harmless,
   `NSImage(contentsOf:)` sniffs content, but consider naming files `.img`).

**Rationale.** Removes generation-loss artifacts (the cache is the *primary* display
source on every warm start), cuts prefill CPU, and eliminates the TIFF memory spikes.

**Effort/risk.** M — touches the provider protocol (both conformers + `ImagePool`).
Existing cache entries stay readable; no migration needed.

### 9. Disk cache is nuked when the same server's URI changes — **P2, M**

**Problem.** (Prior review §4.5 — verified still open; normalization was added but
doesn't address this.) `DiskCache.validateConfig`
(`PlexSaver/ImagePipeline/DiskCache.swift:87-108`) clears the entire cache whenever
the stored `serverURL` string differs. Plex URIs rotate between LAN IPs and
`*.plex.direct` hostnames; using "Change Server" to reselect the *same* server via a
different connection URI discards every cached image and forces a cold refetch —
defeating the offline mode the README advertises.

**Proposed change.** Key validity on a stable server identity instead of the URI:
1. Decode `clientIdentifier` from the plex.tv resources API — add it to
   `PlexResource` (`PlexSaver/Plex/PlexAuth.swift:20-25`; the API returns it) and to
   `PlexServer` (`PlexAuth.swift:39-46`), persist it as a new
   `Preferences.plexServerId` when a server is selected
   (`ConfigurationViewModel.selectServer`, `ConfigurationViewModel.swift:116-125`).
   Jellyfin: the auth response's `SessionInfo`/system info carries a server `Id` —
   or, simpler, keep using the normalized URL for Jellyfin (its URLs are stable).
2. `validateConfig` compares `(serverId, imageSource)`; fall back to the normalized
   URL when no id is stored (legacy configs migrate on first successful auth).

**Rationale.** Cache preservation across URI churn is what makes the instant-start /
offline experience robust for the Plex case, which is the primary provider.

**Effort/risk.** M. Schema change to the manifest (add optional `serverId` — older
manifests decode fine with an optional field) and a new preference key.

### 10. Image decode happens on the main thread at transition time — **P2, M**

**Problem.** (Prior review §10.3 — verified still open.) `GridCell.displayImage`
calls `image.cgImage(forProposedRect:context:hints:)` on the main thread
(`PlexSaver/Grid/GridCell.swift:115`) inside the crossfade path. `NSImage` decoding is
lazy, so for disk-cache images created via `NSImage(contentsOf:)`
(`DiskCache.swift:141, 159`) the *full JPEG decode* happens here, per rotation, on
main — a visible hitch risk with large fanart on big grids. A nil `cgImage` result
also silently blanks the cell.

**Proposed change.**
1. Pre-decode off-main: in `ImagePool.loadImage` (actor context,
   `ImagePool.swift:201-225`) and in `DiskCache.get`/`allCachedImages`, force
   rasterization once (e.g. build the `CGImage` via
   `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceShouldCacheImmediately`,
   or call `cgImage(forProposedRect:...)` there and cache it).
2. Change `ImageWithMetadata` (`ImagePool.swift:9-14`) to carry the ready `CGImage`
   (or an `NSImage` documented as pre-decoded), and have `displayImage` just assign
   `layer.contents`.
3. Add a fallback when decode fails: keep the current layer contents and log, rather
   than assigning nil.

**Rationale.** Smoothness is the product. This moves the only remaining heavyweight
main-thread work off the render path.

**Effort/risk.** M. Touches the pool→grid handoff type. Verify color-space handling
(`CGImageSource` path) on wide-gamut displays.

### 11. Duplicated HTTP plumbing between Plex and Jellyfin clients — **P2, M**

**Problem.** (Prior review §6.1 — verified still open.) `PlexClient.request` +
`fetchImage` (`PlexClient.swift:44-86`) and `JellyfinClient.request` + `fetchImage`
(`JellyfinClient.swift:71-114`) duplicate: URL building from a base string, the
`guard let httpResponse … (200...299)` validation, image decode + `invalidImageData`
throw, and parallel error enums (`PlexError` at `PlexClient.swift:102-118`,
`JellyfinError` at `JellyfinClient.swift:125-143`). `PlexProvider` /
`JellyfinProvider` are structurally identical shims. Every cross-cutting fix (items
4, 8, retry logic) currently must be written twice.

**Proposed change.** Introduce a small `HTTPClient` struct owning a configured
`URLSession` (injectable for tests — synergy with item 5), with
`func get(_ url: URL, headers: [String: String]) async throws -> Data` and
`func getImage(...) async throws -> (NSImage, Data)`, plus one shared transport error
type mapping 401/403 to a distinct `.unauthorized` case (currently indistinguishable
from any other failure — prior review §5.3). Both clients keep their API-shape logic
(paths, headers, models) and delegate transport to it.

**Rationale.** Halves the surface for items 4/8 and future retry work, and is the
natural seam for network-level unit tests.

**Effort/risk.** M. Pure refactor; do it before or together with item 8 to avoid
touching the same lines twice.

### 12. ConfigurationViewModel: startup write-storm, manual actor hops, unconditional reload on sheet close — **P2, S**

**Problem.** Three related paper cuts, all verified in current code:
- `setupBindings` (`PlexSaver/Configuration/ConfigurationViewModel.swift:198-248`):
  only the `$providerType` sink has `.dropFirst()`. A Combine `@Published` publisher
  replays the current value on subscription, so the other eight sinks re-persist
  their just-loaded values at init — eight redundant `ScreenSaverDefaults` writes
  each with `synchronize()`, plus (via the `$plexToken` sink at lines 216-219 after
  its 500 ms debounce) a redundant **Keychain write** every time the sheet opens.
  Slider/stepper sinks (`$gridRows`, `$rotationInterval`, …) also write synchronously
  on every tick while dragging.
- The class is not `@MainActor`; it compensates with ~10 manual `MainActor.run` hops
  (lines 77, 87, 94, 108, 146, 157, 288, 299, 328, 340, 372, 383) — easy to miss one
  in future edits, and `@Published` mutation off-main is a runtime warning.
- `ConfigureSheetController.windowWillClose`
  (`PlexSaver/Configuration/ConfigureSheetController.swift:44-49`) posts
  `.montageConfigChanged` unconditionally, so merely opening and closing the sheet
  tears down the whole pipeline and refetches from the network
  (`MontageView.handleConfigChanged`, `PlexSaver/MontageView.swift:563-586`).

**Proposed change.**
1. Add `.dropFirst()` to all persistence sinks; add
   `.debounce(for: .milliseconds(300), scheduler: RunLoop.main)` to the
   slider/stepper sinks.
2. Annotate the class `@MainActor` and delete the manual hops (the `Task {}` bodies
   then inherit main-actor isolation; keep `await` on the actor calls).
3. Track a dirty flag: set `true` in any persistence sink that actually fires;
   `windowWillClose` posts the notification only when dirty. (Simplest wiring: the
   view model exposes `hasChanges`, the controller reads it via the hosting
   controller's `rootView` — or post the notification from the view model itself.)

**Rationale.** Eliminates spurious Keychain traffic, removes a whole class of future
threading bugs, and stops the visible "screensaver restarts for no reason" behavior
in SaverTest / preview whenever preferences are merely inspected.

**Effort/risk.** S/M. `@MainActor` annotation may surface a few call-site `await`s;
the compiler finds them all.

### 13. README log-viewing instructions are defeated by `%{private}` logging — **P2, S**

**Problem.** The prior review's §1.3 fix made every log payload private:
`os_log("MO (P:%d): %{private}@", ...)` (`PlexSaver/Helpers/Logger.swift:17`). Correct
for security — but README.md:66-70 still tells developers to debug with
`log stream --predicate 'subsystem CONTAINS "montage" …' --level debug`, which now
prints `MO (P:1234): <private>` for every line. The documented debugging workflow is
silently useless, and on modern macOS enabling private data requires installing a
logging configuration profile (the old `log config --mode private_data:on` is gone).

**Proposed change.** Two options; (a) is recommended:
- (a) Split the API: keep `OSLog.info` private by default and add
  `OSLog.notice(_ message: StaticString-ish)` or an
  `info(_ message: String, public: Bool = false)` overload that logs
  `%{public}@` for known-safe, developer-authored strings (lifecycle events, counts,
  state transitions). Migrate the obviously-safe call sites (e.g. the
  `startAnimation`/`Phase 1/Phase 2` messages in `MontageView.swift`) to public;
  leave anything interpolating URLs, titles, or `error.localizedDescription` private.
- (b) Documentation-only: replace README's log section with instructions for the
  private-data logging profile and note the `<private>` behavior.

**Rationale.** The log stream is the only diagnostic surface a screensaver has; the
README currently sends people down a dead end. Option (a) restores usefulness without
reopening the token-leak concern that motivated the change.

**Effort/risk.** S. Audit each call site moved to public — never log a URL or header.

### 14. Multi-display setups do N× network fetches, N× decode, N× cache — **P2, L**

**Problem.** (Prior review §10.4 — partially addressed since: the new
`ReservationRegistry` (`PlexSaver/ImagePipeline/ImagePool.swift:20-35`) prevents the
same *artwork* appearing on two screens, but sharing stops there.) macOS creates one
`MontageView` per screen; each builds its own `GridManager`, `ImagePool`, and
`DiskCache` (`MontageView.swift:372-379, 434-441`). An N-monitor setup performs N
full library fetches, N× image downloads and decodes, and N actors mutating the
*same* manifest.json file on disk (`DiskCache.saveManifest`,
`DiskCache.swift:274-279` — atomic per write, but last-writer-wins across actors, so
one instance's entries/LRU touches can be lost by another's save).

**Proposed change.**
1. Minimum viable fix: make `DiskCache` a process-wide singleton (a `static let
   shared` or an `InstanceTracker`-owned instance) so all views share one manifest
   actor — this removes the manifest-clobbering correctness issue at trivial cost.
2. Fuller fix: share one `ImagePool` (and one `loadMediaItems` result) across views —
   pool size becomes `totalCellsAcrossScreens × 3`; each `GridManager` keeps its own
   grid but draws from the shared pool. `InstanceTracker`
   (`PlexSaver/Helpers/InstanceTracker.swift`) already knows the instance count and
   is the natural owner.

**Rationale.** Step 1 fixes a real (if low-stakes) data race between actors writing
one file. Step 2 is a straight N× bandwidth/CPU/memory saving for multi-monitor
users.

**Effort/risk.** Step 1: S, low risk. Step 2: L — lifecycle is tricky (screens
stopping at different times; config reloads); gate pool teardown on
`InstanceTracker.totalInstances`.

---

## P3 — polish

### 15. Phase-1 cached rotation can show the same image in adjacent cells — **P3, S**

**Problem.** (Prior review §3.11 — verified still open, and now inconsistent with the
v0.4.2 "unique fanart on screen" feature, which only covers Phase-2 pool rotation.)
`fillGridWithCachedImages` assigns `cachedImages[i % cachedImages.count]`
(`PlexSaver/MontageView.swift:509-517`) and `rotateCachedCell` advances a sequential
index into a random cell (`MontageView.swift:530-536`), so with fewer cached images
than cells, identical artwork tiles the grid during the (normally brief, but offline
indefinitely long) cached phase.

**Proposed change.** Track which cache index each cell currently shows
(`[Int: Int]`); in `rotateCachedCell` pick the next image not currently displayed
(fall back to any if `cachedImages.count < cells.count`). Shuffle `cachedImages` once
on load in `startImagePipeline` so the initial fill isn't manifest-ordered.

**Rationale.** Offline mode is a headline README feature; duplicate tiles are its most
visible defect. Small, contained, and unit-testable.

**Effort/risk.** S. None.

### 16. Repo hygiene: uncommitted v0.4.4 work, stale screenshots — **P3, S**

**Problem.** The working tree carries a finished-but-uncommitted release increment
(see `TODO-thumbnail-resume.md`, which itself is marked "do not commit"):
modified `PlexSaver.xcodeproj/project.pbxproj` (0.4.4 bump + Resources group +
`COMBINE_HIDPI_IMAGES=NO`), modified `README.md`, untracked `PlexSaver/Resources/`
(thumbnail.png / thumbnail@2x.png) and `docs/screenshots/` (3 files). Two stale
March-era screenshots (`docs/screenshots/screensaver.png`, `preferences.png`) are
tracked but no longer referenced by README. Local `main` is also multiple commits
ahead of origin.

**Proposed change.** Execute the plan already written in `TODO-thumbnail-resume.md`:
one commit staging `docs/screenshots/`, `PlexSaver/Resources/`, the pbxproj, and
README — after re-verifying `preferences-plex.png` shows the censored
`your-server.plex.direct` URL, per the TODO's censor gate. Delete the two stale
screenshots in the same or a follow-up commit. Do **not** stage the TODO file. Push
timing is the user's call.

**Rationale.** Unfinished working-tree state is fragile across sessions (this review
had to build around it), and the censor gate is a real information-leak check that
should happen once, deliberately.

**Effort/risk.** S. Follow the censor gate; nothing else is risky.

### 17. Dead error cases and meaningless `testConnection` return value — **P3, S**

**Problem.** (Prior review §3.13 — verified still open.) `PlexError.noLibraries` /
`.noMediaItems` (`PlexClient.swift:106-107`) and `JellyfinError.noLibraries` /
`.noMediaItems` (`JellyfinClient.swift:130-131`) are declared but never thrown
anywhere (`grep -rn "noLibraries" --include=*.swift` shows only declarations).
`testConnection()` on both clients and on the `MediaProvider` protocol
(`MediaProvider.swift:23`) returns `Bool` but can only ever return `true` or throw —
and nothing calls it anymore (the view model calls `fetchLibraries` directly,
`ConfigurationViewModel.swift:287, 370`).

**Proposed change.** Either delete `testConnection` from the protocol and both
clients/providers plus the unused error cases, or make it meaningful (`-> Int`
library count, throwing `.noLibraries` on zero) and use it from
`testPlexConnection`/`testJellyfinConnection`. Deletion is the honest option given
current call sites.

**Rationale.** Dead API on a protocol invites future misuse; three files shrink.

**Effort/risk.** S. Compiler-verified; no behavior change.

---

## Verified-fixed since the 2026-07-04 review (no action needed)

For the next session's orientation, these prior-review items were checked against
current code and confirmed done: §1.1 Keychain (`KeychainStore.swift`,
`Preferences.swift:88-119`), §1.2-Plex HTTPS preference + dedup
(`PlexAuth.swift:154-173`), §1.3 log privacy (`Logger.swift:17` — but see item 13),
§3.3 timer registration (`GridManager.swift:100-104`, `MontageView.swift:523-527`),
§3.4 clamp (`GridManager.swift:44-51`), §3.5 Jellyfin pagination + encoding
(`JellyfinClient.swift:38-68`), §3.8 display-time `lastUpdateTime`
(`GridManager.swift:180, 195`), §3.10 version-overlay teardown
(`MontageView.swift:578-579`), §3.12 `isFresh` reset (`DiskCache.swift:100-106`),
§4.1 module constant (`AppConstants.swift`), §4.2 batched LRU persistence
(`DiskCache.swift:231-244`), §5.5 Jellyfin deviceId (`JellyfinAuth.swift:14-22`),
§6.3 (write-once at app init — `MontageTestApp.swift:11` — acceptable as-is),
§9.1 CI (`.github/workflows/ci.yml`), §10.1/§10.2 Retina + per-screen scale
(`MontageView.swift:42-46, 423-430`, `GridCell.swift:47-49`).
