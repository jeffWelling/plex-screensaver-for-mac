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

- [ ] Work through `docs/IMPROVEMENTS-2026-07-15.md` (uniqueness-goal findings
  from the 2026-07-15 review) — verification-first: item U0 gates the rest.

## Standing backlogs

- `docs/IMPROVEMENTS-2026-07-09.md` — 17-item prioritized review, all still
  open as of 2026-07-15 (HEAD `df749ba` unchanged since that review).
- `TODO-thumbnail-resume.md` (repo root, uncommitted by design) — parked
  v0.4.4 commit plan with censor gate. Execute before other work touches
  README/pbxproj.
