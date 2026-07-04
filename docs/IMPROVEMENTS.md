# Montage — Project Review & Improvement Plan

_Review date: 2026-07-04. Reviewed at commit `4202a43` (v0.4.0)._

This document is a prioritized, actionable backlog of improvements across every
engineering discipline: security, correctness, networking, persistence,
rendering/performance, UI/UX & accessibility, testing, CI/CD & release,
architecture, and documentation. It is written so that a future session (human
or agent) can pick up any single item and implement it without re-deriving the
context.

## How to use this document

- Items are grouped by discipline and tagged with a **priority** (P0–P3) and a
  rough **effort** (S / M / L).
  - **P0** — Security or correctness issue that can leak credentials, corrupt
    state, or make the app silently wrong. Do first.
  - **P1** — High-value fix: a real bug, a significant UX/perf regression, or
    foundational engineering hygiene (tests, CI).
  - **P2** — Meaningful improvement, not urgent.
  - **P3** — Polish / nice-to-have.
- Every item states **What**, **Why**, **Where** (`file:line`), and **How**.
- File/line references are from commit `4202a43`; line numbers drift as code
  changes — search by symbol if they don't match.

## Suggested execution order (the critical path)

1. **P0 security:** Move all tokens to Keychain; enforce/prefer HTTPS and warn on
   plaintext HTTP (§1.1, §1.2).
2. **P0 correctness:** Fix the `ScreenSaverDefaults` module-name inconsistency —
   the config sheet and the running saver may read *different* preference
   domains today (§4.1).
3. **P1 foundation:** Add a unit-test target with tests for the pure logic, then
   add GitHub Actions CI (§8, §9).
4. **P1 bugs:** Zero-bounds pipeline start, concurrent-cell rotation, timer
   double-registration, title-duration clamp, Jellyfin pagination truncation
   (§3).
5. **P1 refactor:** Extract a shared, injectable `HTTPClient` — this
   simultaneously fixes testability, session-config inconsistency, and
   Plex/Jellyfin duplication (§6.1).
6. Everything else by priority.

---

## 1. Security

### 1.1 Store auth tokens in the Keychain, not plaintext UserDefaults — **P0, M**

**What.** All long-lived secrets are persisted in cleartext via
`ScreenSaverDefaults` (a plist on disk), not the Keychain. A `grep` for
`Keychain|SecItem|kSecClass` across the codebase returns nothing.

**Where.**
- `PlexSaver/Helpers/Preferences.swift:27` — `plexToken` (server access token)
- `PlexSaver/Helpers/Preferences.swift:30` — `plexAuthToken` (**plex.tv
  account-wide token** — the most sensitive; grants access to the entire Plex
  account, not just one server)
- `PlexSaver/Helpers/Preferences.swift:67` — `jellyfinAccessToken`
- `SimpleStorage.wrappedValue.set` writes straight to
  `ScreenSaverDefaults(forModuleWithName:)` (`Preferences.swift:128-133`)

**Why.** These land in a plist under `~/Library/Preferences/…` readable by any
process running as the user, and are captured in unencrypted backups / Time
Machine. A screensaver token compromise exposes the user's whole media library
(and, via `plexAuthToken`, their plex.tv account).

**How.**
- Add a small `KeychainStore` wrapper around `SecItem*` using
  `kSecClassGenericPassword`.
- **Critical screensaver caveat:** a `.saver` plug-in has no stable
  code-signing identity of its own, and the config sheet runs in a *different*
  host process (System Settings) than the animation engine
  (`legacyScreenSaver`). A Keychain item must therefore be stored **without an
  access group** and with accessibility `kSecAttrAccessibleAfterFirstUnlock` so
  both hosts can read it. This needs testing in both contexts before shipping.
- Migrate existing plaintext values on first launch, then delete them from
  defaults.
- If full Keychain support proves impractical across both hosts, at minimum
  relocate the account-wide `plexAuthToken`.

### 1.2 Enforce/prefer HTTPS; warn on plaintext HTTP — **P0, M**

**What.** Nothing validates the URL scheme. Credentials and tokens can traverse
the LAN in cleartext.

**Where.**
- `PlexSaver/Jellyfin/JellyfinAuth.swift:23-44` — POSTs username + password to
  `\(baseURL)/Users/AuthenticateByName`; README instructs users to enter
  `http://192.168.1.50:8096`.
- `PlexSaver/Plex/PlexClient.swift:51,76` — sends `X-Plex-Token` header over
  whatever scheme the server URL uses.
- `PlexSaver/Plex/PlexAuth.swift:29-35,156-168` — `PlexConnection.connectionProtocol`
  is decoded but never consulted; `discoverServers` adds every connection URI
  with no HTTPS preference and no dedup, so an `http` URI can be chosen over an
  available `https` one for the same server.

**How.**
- In Plex `discoverServers`, prefer `https` connections, then local, then
  remote; **dedupe** so one physical server yields one entry (see §3.9).
- For Jellyfin, normalize the URL and show a visible warning when the scheme is
  `http` (credentials in the clear). Consider refusing to store the password
  path over `http` without explicit user confirmation.
- Do not send account credentials over `http` silently.

### 1.3 Don't force all log output to `%{public}@` — **P1, S**

**What.** `OSLog.info` formats every message with `%{public}@`, disabling the
unified log's privacy redaction globally.

**Where.** `PlexSaver/Helpers/Logger.swift:14`. Callers already pass
`error.localizedDescription`, filenames, and item titles (e.g.
`DiskCache.swift:164`, `ImagePool.swift:153`).

**Why.** No token is logged *today*, but any future log line that includes a
request URL (which carries `?X-Plex-Token=…` for some Plex endpoints) or a
header would be world-readable in the system log.

**How.** Default interpolations to `%{private}@`; opt specific known-safe fields
into `%{public}@`. Audit that no URL-with-token is ever logged.

---

## 2. (reserved)

---

## 3. Correctness / bugs

### 3.1 Pipeline can start at zero bounds → images requested at width/height 0 — **P1, M**

**What.** If the pipeline starts before layout, images are fetched sized `0×0`.

**Where.** `SaverTest/MontageRepresentable.swift:15,20-23` creates
`MontageView(frame: NSZeroRect)` then `startAnimation()` via `async`.
`setupGrid` uses `bounds` (`MontageView.swift:299-306`); then
`startNetworkPhase` reads `Int(gridManager?.cellWidth ?? 480)`
(`MontageView.swift:411-412`). Because `gridManager` is non-nil but its
`cellWidth` is `0`, the `?? 480` fallback **never triggers** and the transcoder
is asked for a `0`-wide image.

**How.** Guard the pipeline start on non-zero `bounds`; if zero, defer until
`resize(withOldSuperviewSize:)`/layout provides real dimensions. Also make the
`cellWidth`/`cellHeight` fallback trigger on `<= 0`, not just `nil`.

### 3.2 Same cell can be rotated concurrently, stranding an image — **P1, M**

**What.** No per-cell "in transition" guard. `rotateWeightedRandomCell` can pick
a cell that is mid-`revealThenRotate`; two overlapping `asyncAfter` closures
both call `cell.displayImage`, and the dual-layer crossfade bookkeeping
(`activeLayerIsFirst`) can flip incorrectly, dropping or double-fading an image.

**Where.** `PlexSaver/Grid/GridManager.swift:196` (`revealThenRotate`),
`PlexSaver/Grid/GridCell.swift:84-113`. Made easy to hit by the clamp bug §3.4.

**How.** Track a per-cell `isTransitioning` flag (or an owning token); skip
selecting cells already transitioning, or coalesce so the latest update wins.

### 3.3 Timers are double-registered with the run loop — **P1, S**

**What.** `Timer.scheduledTimer(...)` already schedules on the current run loop
in `.default` mode; the code then *also* calls `RunLoop.main.add(timer, forMode:
.common)` on the same timer.

**Where.** `PlexSaver/Grid/GridManager.swift:78-83`,
`PlexSaver/MontageView.swift:505-510`.

**How.** Construct a non-scheduled `Timer(timeInterval:…, repeats:true)` and add
it **once** in `.common` mode. That expresses the real intent (keep firing
during event-tracking) without double registration.

### 3.4 `titleDisplayDuration` clamp can exceed available time — **P1, S**

**What.** With a short `rotationInterval` (e.g. 1.0s), `rotationInterval -
crossfadeDuration` = 0.0, and `max(0.5, 0.0)` forces **0.5s**, which is larger
than the 0.0s actually available. The reveal + 1.0s crossfade then run longer
than the rotation period, guaranteeing overlapping transitions.

**Where.** `PlexSaver/Grid/GridManager.swift:29`.

**How.** Clamp against the true budget: reveal duration = `max(0, rotationInterval
- crossfadeDuration)`, and if that's below a usable floor, skip the reveal phase
entirely rather than forcing 0.5s. Consider enforcing a minimum
`rotationInterval` in the UI (see §7.4).

### 3.5 Jellyfin silently truncates libraries at 10 000 items — **P1, M**

**What.** `fetchAllItems` hard-codes `&Limit=10000` with no paging.
`totalRecordCount` is decoded but never compared to `items.count`, so larger
libraries are quietly cut off.

**Where.** `PlexSaver/Jellyfin/JellyfinClient.swift:37`,
`PlexSaver/Jellyfin/JellyfinModels.swift:78`.

**How.** Loop with `StartIndex`/`Limit` until `items.count >=
totalRecordCount`. Also URL-encode query params via `URLComponents`/`queryItems`
(`libraryId` is currently interpolated raw — `JellyfinClient.swift:37`).

### 3.6 Plex fetches an entire library in one unpaginated request — **P2, M**

**What.** `/library/sections/{id}/all` uses no `X-Plex-Container-Start`/`-Size`,
so a huge library returns one enormous response held fully in memory.

**Where.** `PlexSaver/Plex/PlexClient.swift:38-42`.

**How.** Paginate with `X-Plex-Container-Start` / `X-Plex-Container-Size`
headers; accumulate until the container's `totalSize` is reached.

### 3.7 Plex transcode URL under-encodes the inner path — **P2, S**

**What.** `buildTranscodeURL` encodes the inner `url=` value with
`.urlQueryAllowed`, which does **not** escape `&`, `=`, `?`, or `+`. A `+` in an
art path becomes a space server-side; a query-bearing path breaks the outer URL.

**Where.** `PlexSaver/Plex/PlexClient.swift:88-91`.

**How.** Build via `URLComponents` with `queryItems`, or percent-encode the
inner value with a stricter allowed character set that escapes sub-delimiters.

### 3.8 `lastUpdateTime` recorded at request time, not display time — **P2, S**

**What.** Staleness weighting uses the time a rotation was *requested*, not when
the image actually appeared; it's also written twice for the initial fill.

**Where.** `PlexSaver/Grid/GridManager.swift:74,152,168`; weighting at `:107`.

**How.** Set `lastUpdateTime` inside the `MainActor.run` block right after
`cell.displayImage` succeeds.

### 3.9 Duplicate Plex server entries from discovery — **P2, S**

**What.** `discoverServers` produces one `PlexServer` per connection URI (all
local, then all remote), so one physical server appears multiple times with no
dedup.

**Where.** `PlexSaver/Plex/PlexAuth.swift:159-167`.

**How.** Group connections by server (machine identifier / `clientIdentifier`),
pick a single best URI (prefer `https` + local), and emit one entry per server.

### 3.10 Version overlay leaks across config reload — **P3, S**

**What.** `handleConfigChanged` tears down grid/pool/fade/status layers but never
removes `versionLayer` (only its 5s self-timer does). A config change mid-fade
leaves a stale version label.

**Where.** `PlexSaver/MontageView.swift:546-567` vs `:255-291`.

**How.** Remove `versionLayer` in `handleConfigChanged`, and re-show it if
desired after `setupGrid`.

### 3.11 Phase-1 cached rotation can show visible duplicates — **P3, S**

**What.** `rotateCachedCell` picks a random cell but advances the image by a
sequential index; with fewer cached images than cells, identical posters land in
adjacent cells.

**Where.** `PlexSaver/MontageView.swift:495,513-518`.

**How.** Track which image is shown per cell and pick a non-duplicate; or shuffle
image assignment like `ImagePool` does.

### 3.12 `isFresh` can report true against an emptied cache — **P3, S**

**What.** `validateConfig` clears entries on a config change but does not reset
`lastRefresh`, so `isFresh` can return `true` while the cache is actually empty,
suppressing the "Connecting…" banner.

**Where.** `PlexSaver/ImagePipeline/DiskCache.swift:83-99` vs `:102-105`.

**How.** Set `manifest.lastRefresh = nil` inside `validateConfig` when the cache
is cleared.

### 3.13 Dead / meaningless error paths — **P3, S**

**What.** `PlexError.noLibraries`/`.noMediaItems` and the Jellyfin equivalents are
declared but never thrown. `testConnection()` returns `Bool` but can only return
`true` or throw — the return value is meaningless.

**Where.** `PlexSaver/Plex/PlexClient.swift:27-30,100-101`;
`PlexSaver/Jellyfin/JellyfinClient.swift:23-26,103-104`.

**How.** Either make `testConnection` return a meaningful result (e.g. throw
`.noLibraries` when zero libraries) or drop the `Bool`. Remove unused cases.

---

## 4. Persistence & preferences

### 4.1 `ScreenSaverDefaults` module name is inconsistent — likely a real data-sharing bug — **P0, S**

**What.** The preferences domain (module name) is derived three different ways:
- `PlexSaver/Helpers/Preferences.swift:79,114` —
  `Bundle.main.bundleIdentifier ?? "com.montage.Montage"`
- `PlexSaver/ImagePipeline/DiskCache.swift:28` — hardcoded `"com.montage.Montage"`
- `PlexSaver/Helpers/Logger.swift:10` — `Bundle.main.bundleIdentifier ?? "Montage"`

**Why.** For a loaded `.saver`, `Bundle.main` is the **host process**, not the
saver bundle. The config sheet runs inside System Settings and the animation
runs inside `legacyScreenSaver`/`ScreenSaverEngine`, so
`Bundle.main.bundleIdentifier` can resolve to different values in the two
contexts — meaning `ScreenSaverDefaults(forModuleWithName:)` opens **different
preference domains**. Settings saved in the config UI may not be visible to the
running saver. The `?? "com.montage.Montage"` fallback masks this because it only
fires when `bundleIdentifier` is `nil`, not when it's the "wrong" host id.

**How.** Use a single hardcoded module constant (`"com.montage.Montage"`)
everywhere, matching `DiskCache`. Define it once (e.g.
`enum AppConstants { static let module = "com.montage.Montage" }`) and reference
it from `Preferences`, `DiskCache`, and `Logger`.

### 4.2 `touchEntry` never persists LRU access times — **P2, S**

**What.** `get()` updates `lastAccess` in memory via `touchEntry` but never calls
`saveManifest()`. Screensavers are frequently killed (not cleanly torn down), so
access times are lost across restarts and eviction/age decisions use stale data.

**Where.** `PlexSaver/ImagePipeline/DiskCache.swift:129,212-216` vs
`removeEntry` (`:225`) which does save.

**How.** Persist periodically (debounced) or on `stopAnimation`. A full
`saveManifest` on every `get` is too costly (§4.4); batch instead.

### 4.3 TTL is access-based, not content-based; pruning only on `load()` — **P2, M**

**What.** `maxAge` (7 days) is applied to `entry.lastAccess`, so frequently shown
art is never re-fetched even if the upstream artwork changed. Age pruning runs
only in `load()`, so a long-running session never re-prunes for age.

**Where.** `PlexSaver/ImagePipeline/DiskCache.swift:55-67,61,101-105`.

**How.** Track a separate `createdAt` per entry for true content freshness; keep
`lastAccess` purely for LRU. Consider periodic re-validation of long-lived
entries.

### 4.4 Manifest is rewritten in full on every mutation — **P2, M**

**What.** `saveManifest()` re-encodes and rewrites the entire manifest JSON on
every `store`/`remove`. During prefill of dozens of images that's dozens of
full-manifest writes.

**Where.** `PlexSaver/ImagePipeline/DiskCache.swift:185,246-251`.

**How.** Debounce/batch manifest writes (e.g. flush at end of prefill and every
N seconds), or move to an append-friendly store. Also add an entry-count cap
(currently only bytes are capped).

### 4.5 Cache is nuked when the same server's URI changes — **P2, S**

**What.** `validateConfig` clears the whole disk cache whenever `serverURL`
changes. Plex URIs rotate (LAN vs `plex.direct` relay), so reconnecting to the
same server via a different URI needlessly discards the cache.

**Where.** `PlexSaver/ImagePipeline/DiskCache.swift:83-99`.

**How.** Key cache validity on a **stable server identifier** (Plex machine
identifier / Jellyfin server id) rather than the URI string.

### 4.6 `store` inflates JPEG → TIFF → JPEG — **P2, S**

**What.** `store` decodes the downloaded image to `tiffRepresentation`, wraps in
`NSBitmapImageRep`, and re-encodes to JPEG at 0.85 — a lossy re-compression of
already-compressed bytes, plus a large uncompressed intermediate.

**Where.** `PlexSaver/ImagePipeline/DiskCache.swift:152-155`.

**How.** Store the original network response bytes directly (thread the raw
`Data` from `fetchImage` into the cache) instead of re-encoding. This also
removes double compression artifacts.

### 4.7 Two preference property wrappers with subtly different semantics — **P3, S**

**What.** `Storage<T: Codable>` (JSON-string) and `SimpleStorage<T>` (raw
`object(forKey:)` with an unconstrained `as? T`) coexist. `SimpleStorage` silently
returns the default on any type mismatch.

**Where.** `PlexSaver/Helpers/Preferences.swift:76-135`.

**How.** Unify on one wrapper (Codable-based), or constrain `SimpleStorage`'s `T`
to the property-list types it actually supports.

---

## 5. Networking

### 5.1 Inconsistent `URLSession` configuration — **P1, S**

**What.** `PlexClient` builds a session with 15s/60s timeouts;
`JellyfinClient` and `JellyfinAuth` use bare `URLSession.shared` with default
timeouts (up to 60s per request). A hung Jellyfin server stalls with no
request-level bound.

**Where.** `PlexSaver/Plex/PlexClient.swift:19-22` vs
`PlexSaver/Jellyfin/JellyfinClient.swift:19`,
`PlexSaver/Jellyfin/JellyfinAuth.swift:44`.

**How.** Centralize session creation in the shared `HTTPClient` (§6.1) with
consistent timeouts. Consider `config.waitsForConnectivity = true`.

### 5.2 No retry / backoff anywhere — **P2, M**

**What.** Any transient blip fails the whole operation. No exponential backoff,
no cache policy.

**Where.** All clients; e.g. `PlexAuth.pollForToken` also aborts the entire 120s
poll if a single 200 response fails to decode
(`PlexSaver/Plex/PlexAuth.swift:106-132`).

**How.** Add bounded retry with backoff to idempotent GETs in `HTTPClient`. Make
the PIN poll tolerant of decode errors (log & continue rather than throw).

### 5.3 Auth failures are indistinguishable from transport errors — **P2, S**

**What.** Both `request()` helpers collapse all non-2xx into a generic
`httpError(code)`; a 401 isn't surfaced as "re-auth needed." Response bodies are
discarded, so no diagnostic is captured.

**Where.** `PlexSaver/Plex/PlexClient.swift:80-83`,
`PlexSaver/Jellyfin/JellyfinClient.swift:80-84`.

**How.** Map 401/403 to a distinct `.unauthorized` error the UI can act on
(prompt re-sign-in); capture a short response snippet for logging.

### 5.4 Missing standard Plex headers / `User-Agent` — **P3, S**

**What.** Data requests send only `Accept` + `X-Plex-Token`; Plex generally
expects `X-Plex-Client-Identifier`/`X-Plex-Product` on all calls, and no request
sets a `User-Agent`.

**Where.** `PlexSaver/Plex/PlexClient.swift:74-76`.

**How.** Add the standard Plex headers (reuse the persisted client identifier
from `PlexAuth`) and a product `User-Agent` in `HTTPClient`.

### 5.5 Thread-unsafe Jellyfin device-ID generation — **P2, S**

**What.** `JellyfinAuth.deviceId` is a computed static that re-reads UserDefaults
on every access; two concurrent first-time reads can each generate and store a
*different* UUID (last writer wins). `PlexAuth.clientIdentifier` uses a
once-initialized lazy static and is fine — the two differ for no reason.

**Where.** `PlexSaver/Jellyfin/JellyfinAuth.swift:11-19` vs
`PlexSaver/Plex/PlexAuth.swift:49-58`.

**How.** Make `deviceId` a `lazy static let` computed once (mirror
`clientIdentifier`), or guard generation with a lock.

---

## 6. Architecture & code quality

### 6.1 Extract a shared, injectable `HTTPClient` — **P1, M**

**What.** `PlexClient` and `JellyfinClient` duplicate: session setup, the private
`request(path:)` helper, the `guard let httpResponse … (200...299)` validation
block, `fetchImage`, and overlapping error enums (`invalidURL`,
`httpError(Int)`, `invalidImageData`, `noLibraries`, `noMediaItems`).
`PlexProvider`/`JellyfinProvider` are structurally identical thin actors.

**Where.** `PlexSaver/Plex/PlexClient.swift:69-112`,
`PlexSaver/Jellyfin/JellyfinClient.swift:69-116`,
`PlexSaver/Plex/PlexProvider.swift`, `PlexSaver/Jellyfin/JellyfinProvider.swift`.

**Why it's high-leverage.** One change fixes three problems at once:
duplication (this item), session-config inconsistency (§5.1), and
testability (§8.1) — because the shared client takes an injectable
`URLSession`/`URLProtocol`.

**How.** Introduce `HTTPClient` that owns the session, does request building,
status validation, and image decoding, and accepts an injectable session
(default `.shared` or a configured one). Have both clients delegate to it. Define
one shared transport-error type.

### 6.2 `serverName` is a hardcoded constant — **P3, S**

**What.** Both providers return a fixed `serverName` ("Plex Server" /
"Jellyfin Server") rather than the discovered server name.

**Where.** `PlexSaver/Plex/PlexProvider.swift:12`,
`PlexSaver/Jellyfin/JellyfinProvider.swift:12`.

**How.** Thread the real server name from discovery/auth into the provider.

### 6.3 `InstanceTracker.isRunningInApp` is an unsynchronized static var — **P2, S**

**What.** A `static var Bool` read/written without synchronization while the rest
of the class correctly uses a serial queue — a data race.

**Where.** `PlexSaver/Helpers/InstanceTracker.swift:10`.

**How.** Guard it with the same queue, or make it write-once at app startup and
document that contract.

### 6.4 `ImageCache`'s `NSLock` is dead weight — **P3, S**

**What.** `ImageCache` is only ever touched from inside the `ImagePool` actor, so
its `NSLock` is redundant (harmless but signals unclear ownership). Its LRU via a
parallel `accessOrder` array is O(n) per access.

**Where.** `PlexSaver/ImagePipeline/ImageCache.swift:12,24,37`; callers
`ImagePool.swift:134,141,147`.

**How.** Either drop the lock and document actor-only access, or keep the lock
and make the class explicitly standalone/testable. Consider an ordered
dictionary for O(1) LRU.

### 6.5 Force-unwraps in latent-crash positions — **P3, S**

**What.** Several `!` that are safe today but crash the saver if assumptions break:
- `URLComponents(string: "https://app.plex.tv/auth")!` — `PlexAuth.swift:93`
- `FileManager…urls(...).first!` — `DiskCache.swift:27`
- `NSHostingController(...)!`, `window!` in `endSheet` —
  `ConfigureSheetController.swift:26,37`

**How.** Replace with graceful `guard`/degradation (no cache, log-and-return)
rather than a crash in a background screensaver process.

### 6.6 Config sheet controller lifecycle / potential leak — **P2, S**

**What.** `ConfigureSheetController` sets `isReleasedWhenClosed = false` and is
often re-created per open. If a fresh controller is created each time the sheet
is requested and never released, each open/close can leak a window + hosting
controller + ViewModel.

**Where.** `PlexSaver/Configuration/ConfigureSheetController.swift:29,35-47`;
`MontageView.configSheetController` is `lazy` (`MontageView.swift:15`) which
helps — verify it's reused, not rebuilt.

**How.** Confirm a single controller instance is reused across opens; if not,
cache it. Audit for retained hosting controllers.

---

## 7. UI / UX & accessibility

### 7.1 No accessibility labels on status indicators — **P2, M**

**What.** Success/failure is conveyed by color + icon only (green check / red x),
invisible to color-blind and VoiceOver users.

**Where.** `PlexSaver/Configuration/ConfigurationView.swift:104,135-157,176,192,
200,303,311,320`.

**How.** Add `.accessibilityLabel` ("Connected"/"Connection failed"), label the
"Local" server badge, label `ProgressView`s ("Connecting…"), and add
`.accessibilityValue` with units on sliders (`:225,239`).

### 7.2 No server-URL validation / normalization in the UI — **P2, S**

**What.** The Jellyfin URL is free text; the Connect button only checks
`.isEmpty`. `jellyfin.local:8096` (no scheme) or a trailing space fails deep in
the auth call with an opaque error shown verbatim.

**Where.** `PlexSaver/Configuration/ConfigurationView.swift:284,298-301`;
`ConfigurationViewModel.swift:311,342`.

**How.** Normalize (trim, add scheme if missing, strip trailing `/`), validate
via `URLComponents`, and warn on `http`. Show a friendly inline error.

### 7.3 Config window doesn't adapt to Dynamic Type — **P3, S**

**What.** Fixed `width: 420, height: 400`; long server URLs are middle-truncated
with no way to see the full value.

**Where.** `PlexSaver/Configuration/ConfigurationView.swift:89,107-108`.

**How.** Allow the window to grow / use a resizable layout; add a tooltip or
selectable text for the full URL.

### 7.4 Enforce a sane minimum rotation interval — **P2, S**

**What.** A very small `rotationInterval` triggers the clamp bug §3.4 and
overlapping transitions.

**Where.** `PlexSaver/Configuration/ConfigurationView.swift` (slider), consumed
in `GridManager.swift:29`.

**How.** Set the slider's lower bound so `rotationInterval >= crossfadeDuration +
a small floor` (e.g. ≥ 1.5s).

### 7.5 ViewModel should be `@MainActor`; avoid startup write-storm — **P2, S**

**What.** `ConfigurationViewModel` isn't `@MainActor`, so it hops manually via
`MainActor.run` in ~10 places (easy to miss one). Also, only `providerType`'s
sink uses `dropFirst()`; the other 8 sinks re-persist their just-loaded values on
launch (a redundant write storm), and rapid slider/stepper changes each do a
synchronous `set` + `synchronize()`.

**Where.** `PlexSaver/Configuration/ConfigurationViewModel.swift:9,48-49,200,
211-247`.

**How.** Annotate the class `@MainActor` and delete the manual hops. Add
`dropFirst()` to all persistence sinks (or gate persistence on a "loaded" flag).
Debounce the slider/stepper writes like the text fields already are.

---

## 8. Testing

### 8.1 Add a unit-test target and cover the pure logic — **P1, L**

**What.** There are **zero** automated tests. `SaverTest/` is a manual visual
harness, and `Makefile:71`'s `test:` target only *builds* it — the name is
misleading.

**Where.** `PlexSaver.xcodeproj/project.pbxproj` defines only the saver bundle
and the SaverTest app — no XCTest target.

**Why.** Substantial pure logic is trivially unit-testable and currently
unguarded, and every future change risks silent regressions.

**How.**
1. Add an XCTest (or Swift Testing) unit-test target to the Xcode project.
2. Start with logic that needs no I/O:
   - Weighted-random staleness selection — `GridManager.swift:97-126`
   - `titleDisplayDuration` clamp (incl. the §3.4 edge case) —
     `GridManager.swift:29`
   - `ImageCache` LRU eviction — `ImageCache.swift`
   - `DiskCache` size eviction, 7-day pruning, `filename(for:)` hashing,
     `validateConfig` — `DiskCache.swift:55-67,83,230,254`
   - `ImagePool` shuffle / reshuffle wraparound — `ImagePool.swift:110-125`
3. Then make networking testable by injecting `URLSession`/`URLProtocol` via the
   shared `HTTPClient` (§6.1) and add `MediaProvider` fakes (the protocol already
   exists — `MediaProvider.swift` — nothing exploits it yet).
4. Abstract time (`Timer`/`asyncAfter`) behind a clock protocol so rotation /
   transition timing can be tested deterministically. Currently
   `GridManager.startRotation(imagePool:)` takes the concrete `ImagePool` actor —
   change it to accept a protocol so a fake pool can be injected.

Fix the `Makefile` `test:` target to actually run `xcodebuild test` once the
target exists.

---

## 9. CI/CD, release & SRE

### 9.1 Add GitHub Actions CI — **P1, M**

**What.** No `.github/` directory exists — no build verification, no lint, no
release automation. Nothing prevents a broken build from landing on `main`.

**How.** Add a `macos`-runner workflow that:
- `xcodebuild build` both schemes (`PlexSaver`, `SaverTest`) on PRs.
- Runs `xcodebuild test` once the test target exists (§8.1).
- Optionally runs SwiftLint/SwiftFormat.
Consider a `SessionStart` hook (see repo skills) so web sessions can build/test.

### 9.2 Signing & notarization for releases — **P1, M**

**What.** Install/release is fully manual via the `Makefile`, with no signing or
notarization. Modern macOS increasingly gates unsigned screensavers.

**Where.** `Makefile:22-33` (`install`), README "From Release" flow.

**How.** Add a release workflow that builds, codesigns with a Developer ID, and
notarizes the `.saver`, then attaches the zipped bundle to a GitHub Release.
Document the signing requirement.

### 9.3 Distribute a versioned, checksummed artifact — **P3, S**

**What.** README points at a `Montage.saver.zip` release asset; there's no
checksum or provenance.

**How.** Publish SHA-256 checksums alongside release assets; keep the versioned
bundle name the `Makefile` already produces (`Montage_v<version>.saver`).

---

## 10. Rendering & performance (fullscreen, always-on)

### 10.1 Request pixel-resolution images (fix Retina blur) — **P1, M**

**What.** Images are requested at **point** resolution but rendered at
`contentsScale = backingScaleFactor` with `.resizeAspectFill`, so the server
returns ~1x art that CoreAnimation upscales 2x → blurry on Retina.

**Where.** `MontageView.swift:411-412` (`cellW/cellH` from point-based
`GridManager.cellWidth`, `GridManager.swift:37-39`), rendered in
`GridCell.swift:40-42`, requested in `PlexClient.swift:44-45`.

**How.** Multiply cell point dimensions by the target screen's
`backingScaleFactor` before requesting images.

### 10.2 Use the correct per-screen backing scale — **P1, S**

**What.** Backing scale is read from `NSScreen.main` in three places, not the
screen the view lives on — wrong on mixed-DPI multi-monitor setups.

**Where.** `GridCell.swift:40`, `MontageView.swift:177,263`. The right hook
already exists: `viewDidMoveToWindow` (`MontageView.swift:579`) knows the screen
but only logs it.

**How.** Read `self.window?.screen?.backingScaleFactor` and propagate it to the
grid/cells and overlays.

### 10.3 Move image decode off the main thread — **P1, M**

**What.** `NSImage` decoding is lazy; `GridCell.displayImage` forces
rasterization on the main thread at transition time (worst for disk-cache images
loaded via `NSImage(contentsOf:)`), causing hitches. Also, a `nil` `cgImage`
result silently blanks the cell.

**Where.** `GridCell.swift:97-98`; disk path `DiskCache.swift:122,140`.

**How.** Decode to a ready `CGImage`/bitmap off-main (in the pool/actor) and hand
the layer finished bitmaps. Add a fallback when decode returns `nil`.

### 10.4 De-duplicate work across displays — **P2, L**

**What.** macOS spawns one `MontageView` per screen; each independently builds
its own `GridManager`, `ImagePool`, and `DiskCache`, so an N-monitor setup does
N× network, N× decode, N× memory with no sharing.

**Where.** `MontageView.swift:328-408,363-369`; `InstanceTracker` counts
instances (`InstanceTracker.swift`) but shares nothing.

**How.** Share a single media-item list, image pool, and disk cache across
instances (e.g. a process-wide coordinator keyed off `InstanceTracker`), giving
each view its own grid but a shared source.

### 10.5 Add power / idle / thermal awareness — **P2, M**

**What.** Nothing pauses network refills, rotation, or crossfades on battery,
during display sleep, or under thermal pressure; `ImagePool` keeps refilling in
the background.

**Where.** `ImagePool.swift:94,158-171`; `MontageView` lifecycle.

**How.** Observe `NSProcessInfo.thermalStateDidChange` and power source; throttle
rotation interval and pause background refills when appropriate. For an
always-on fullscreen saver this materially affects battery/energy.

### 10.6 The empty `animateOneFrame` still costs per-frame wakeups — **P2, S**

**What.** Animation is timer-driven in `GridManager`, but `ScreenSaverView` still
fires its own per-frame timer calling the empty `animateOneFrame()` and
triggering `draw(_:)` fills — wasted wakeups.

**Where.** `MontageView.swift:151-153`; `draw` at `:139-143`.

**How.** Raise `animationTimeInterval` substantially (the grid drives itself), or
consolidate all animation onto the framework timer.

### 10.7 Reduce double image memory during Phase-1 → Phase-2 handoff — **P3, S**

**What.** Phase-1 cached images are held in `MontageView.cachedImages`
(`totalCells * 3`) *in addition to* `ImagePool.pool` (`poolSize = totalCells *
3`) until `stopCachedRotation()` clears the array — roughly double resident image
memory during handoff.

**Where.** `MontageView.swift:381,429,524`; `ImagePool.swift:26,414`.

**How.** Release cached images sooner (as each cell is taken over by the live
pool), or reuse the disk-cache-backed images the pool already loads.

---

## 11. Platform / packaging

### 11.1 Set `LSMinimumSystemVersion` on the saver bundle — **P3, S**

**What.** The code calls macOS 26 (Tahoe) APIs under `#available`
(`MontageView.swift:47`), but `PlexSaver/Info.plist` has no
`LSMinimumSystemVersion`; the deployment floor lives only in the pbxproj. (The
SaverTest plist does set it — `SaverTest/Info.plist:23`.)

**How.** Advertise the minimum OS explicitly on the saver bundle plist.

### 11.2 Document / harden the `isPreview` heuristic — **P2, S**

**What.** `MontageView.init` overrides the OS-supplied `isPreview` with indirect
proxies: a `400×300` frame-size threshold (pre-Tahoe) and screen-lock detection
(Tahoe). The magic numbers are fragile (a large System Settings preview thumbnail
could exceed 400×300 and be mistaken for the real saver), and lock-state ≠
preview-vs-live.

**Where.** `MontageView.swift:44-59`.

**How.** Add a comment block explaining the `legacyScreenSaver` behavior this
works around; investigate a more robust signal (e.g. process/host identity or the
view's window role). At minimum, name the magic numbers as constants.

---

## Appendix: quick-reference index of the highest-priority items

| # | Item | Priority | Area |
|---|------|----------|------|
| 1.1 | Tokens → Keychain | P0 | Security |
| 1.2 | Enforce/prefer HTTPS | P0 | Security |
| 4.1 | `ScreenSaverDefaults` module-name inconsistency | P0 | Persistence |
| 8.1 | Add unit-test target + tests | P1 | Testing |
| 9.1 | GitHub Actions CI | P1 | CI/CD |
| 9.2 | Signing & notarization | P1 | Release |
| 6.1 | Shared injectable `HTTPClient` | P1 | Architecture |
| 3.1 | Zero-bounds pipeline start | P1 | Bugs |
| 3.2 | Concurrent-cell rotation guard | P1 | Bugs |
| 3.3 | Timer double-registration | P1 | Bugs |
| 3.4 | `titleDisplayDuration` clamp | P1 | Bugs |
| 3.5 | Jellyfin pagination truncation | P1 | Bugs |
| 10.1 | Request pixel-resolution images (Retina) | P1 | Rendering |
| 10.2 | Per-screen backing scale | P1 | Rendering |
| 10.3 | Decode images off main thread | P1 | Rendering |
| 1.3 | Don't force `%{public}@` logging | P1 | Security |
| 5.1 | Consistent `URLSession` config | P1 | Networking |
