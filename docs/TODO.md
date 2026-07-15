# Montage — TODO

## Open

- [ ] **Rename repo and all 'plex-screensaver-…' references to Montage.**
  The product has been "Montage" since v0.3.x; the repo name predates it.
  Scope:
  - GitHub repo rename: `plex-screensaver-for-mac` → `montage` (or
    `montage-screensaver`; GitHub auto-redirects the old URL, but update
    anything that hardcodes it).
  - Local checkout dir: `~/claude/repos/plex-screensaver-for-mac/` → match the
    new repo name; update the git remote URL after the GitHub rename.
  - In-repo references: README.md clone URL and Releases link (README.md:35,
    45), any doc that spells out the old repo name.
  - External references: Claude continuity/journal/memory notes that point at
    the old path (sweep `~/claude/` for `plex-screensaver` after the move).
  - **Open question for review:** does the rename extend to the Xcode project
    (`PlexSaver.xcodeproj`, `PlexSaver` scheme/target, `PlexSaver/` source
    dir)? That is a much bigger, riskier change (pbxproj surgery, Makefile
    SCHEME, CI scheme names, DerivedData paths in docs) — recommend treating
    it as a separate follow-up decision, not bundling it into the repo rename.

- [x] Work through `docs/IMPROVEMENTS-2026-07-15.md` (uniqueness-goal findings
  from the 2026-07-15 review). **Done 2026-07-15** — all U/N/R/A items
  implemented (bump 0.4.4 → 0.5.0), builds green, 18-test suite added. U0 came
  back INCONCLUSIVE (single-display Mac) → built U4 tier 1. See that doc's
  "Status — 2026-07-15 fix pass" appendix for the per-item table and the
  runtime-verification checks still owed (two-monitor U0/U1/U2/U4, Jellyfin
  device N1, Tahoe lingering N5).

## Standing backlogs

- `docs/IMPROVEMENTS-2026-07-09.md` — 17-item prioritized review. Several items
  landed via the 2026-07-15 pass: 1 & 2 (freeze/leak → U3), 5 (tests → A1), 15
  (Phase-1 duplicates → U1), 16 (repo hygiene → R5), 17 (dead API → R1). Still
  open: 3, 4 (Jellyfin plaintext warning + timeouts), 6 (signing/notarization),
  7 (Plex pagination), 8–13 (cache/decode/refactor/config polish), 14 step 1
  (DiskCache singleton).
- `TODO-thumbnail-resume.md` — DONE and removed. Its v0.4.4 commit landed
  2026-07-15 (R5); the censor gate passed (`your-server.plex.direct`).
