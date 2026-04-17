# Monarch — Improvement Backlog

Living checklist of things to improve. Move items between sections as their status changes. Add `(YYYY-MM-DD)` next to "Done" items so we can see history.

---

## In Progress
_(none)_

## Done

- [x] **Add a README.** (2026-04-17)
- [x] **Fix lingering build warning.** `HotkeyManager.swift:68` — `var hkID` → `let`. (2026-04-17)
- [x] **Delete exploration scripts.** Removed 10 scripts + 5 output dirs from `scripts/`. (2026-04-17)
- [x] **Strip stale `.gitignore` entry.** Removed `FolderMenu.app/` line. (2026-04-17)
- [x] **Add a LICENSE file.** MIT. (2026-04-17)

---

## Quick wins (≤1 hr each)

---

## Real product gaps

- [ ] **In-folder search/filter.** With 200+ items, scrolling is the only way to find anything. `⌘F` filter that narrows the list as you type. Highest-impact improvement available — every Folder Peek competitor has it.
- [ ] **Keyboard navigation polish.** Confirm arrow keys + Return for drilling/opening work end-to-end and feel snappy. Table-stakes for power users.
- [ ] **"New Folder" / "New File" actions.** Currently Monarch only consumes the filesystem, never produces. Right-click → New Folder is ~30 lines and meaningfully extends usefulness.
- [ ] **Show file count + total size** in breadcrumb or footer of each level. Tiny addition, hugely informative.
- [ ] **Quick Look on spacebar.** macOS users hit space-to-preview reflexively. Wire `space` (when focus exists) to invoke existing `QuickLookManager`.

---

## Build & distribution

- [ ] **Real code signing + notarization.** Currently ad-hoc (`-`). Users see "Apple cannot verify Monarch" on first launch. Requires Apple Developer account ($99/yr) + notarization step in `build.sh`.
- [ ] **Sparkle auto-updates.** Easier to bake in now than retrofit later.
- [ ] **Version bumping.** `CFBundleVersion = 1`, `CFBundleShortVersionString = 1.0` are placeholders. A `bump.sh` that increments before each `build.sh` keeps history clean.
- [ ] **DMG packaging.** Add a `create-dmg` step at the end of `build.sh` for a draggable installer.

---

## Code quality

- [ ] **Tests.** None exist. Filesystem + drag-and-drop + concurrency code is a regression magnet. Start with `FolderStore`, `PinStore`, `FileDropHelper.uniqueDestination`.
- [ ] **Decompose `CascadeModel`.** It owns state machine, FSEvents lifecycle, folder loading, pin/recent composition, focus tracking, breadcrumbs. Worth splitting as it grows.
- [ ] **Reconsider notification-based coupling.** `.monarchRemoveRoot`, `.monarchPinsChanged` work but are invisible at call sites. Past 4–5 of these, an event bus or direct callbacks read better.

---

## Subtle polish

- [ ] **First-run experience.** Empty state (`"No folders yet"`) is correct but cold. A one-time arrow/hint pointing at the settings button would orient new users.
- [ ] **Animation on level open.** Peek windows appear/disappear instantly. A 100ms scale+fade would feel more refined.
- [ ] **Global drop-zone affordance.** Currently only the hovered folder row highlights during external drag. A subtle accent border around the whole popover when anything is being dragged would signal "you can drop here."

---

## Top 5 by ROI

If only doing five things, in order:

1. **In-folder search** — biggest user-facing impact
2. **README** — least effort, prevents future-you confusion
3. **Quick Look on space** — feels native, minutes of work
4. **Code signing + notarization** — gates whether anyone else will use this
5. **Delete exploration scripts** — keeps the codebase honest
