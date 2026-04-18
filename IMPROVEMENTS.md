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
- [x] **In-folder search/filter.** `⌘F` filter that narrows the list as you type. Works in popover and peek windows. (2026-04-17)
- [x] **Keyboard navigation.** Arrows, Return, Escape, ⌘F all wired up end-to-end. (2026-04-17)
- [x] **Quick Look on spacebar.** Space on focused item invokes `QuickLookManager`. (2026-04-17)
- [x] **"New Folder" action.** Right-click → New Folder Inside / New Folder Here. (2026-04-17)
- [x] **Fix drag-into-peeks.** Popover no longer closes mid-drag from external apps. (2026-04-17)
- [x] **Fix crash when trashing a folder.** Index-out-of-bounds in `folderDidChange` fixed. (2026-04-17)
- [x] **Peek open animation.** 200ms fade + slide. (2026-04-17)
- [x] **App icon in popover header.** Raw artwork, transparent background. (2026-04-17)
- [x] **Footer bar.** Item count + total size per level, toggle in Preferences. (2026-04-17)
- [x] **Version bumping.** `bump.sh` — auto-increments build number, optional version arg. (2026-04-17)
- [x] **Replace NotificationCenter coupling.** `.monarchRemoveRoot`, `.monarchPinsChanged` replaced with direct callbacks. (2026-04-17)
- [x] **Publish to GitHub.** https://github.com/codexjdub/Monarch (2026-04-17)
- [x] **GitHub Actions.** `swift build` runs on every push. (2026-04-17)

---

## Feels incomplete

- [ ] **Reorder root folders.** Can add/remove but can't drag to reorder in the popover. Order is stuck as-is.
- [ ] **Open folder in Finder from breadcrumb.** Right-clicking a peek header has no "Open in Finder" or "Open in Terminal". Currently you have to click a file inside to get to the folder.
- [ ] **Rename file.** Context menu has trash, copy path, share — but no rename. Basic file operation that's missing.

---

## Friction points

- [ ] **Peek windows run off-screen.** Popover always anchors to the menu bar icon. With many peek levels, peeks run off the right edge of the screen.
- [ ] **Search doesn't persist across peek open/close.** Close and reopen a peek, the search is gone.

---

## Nice to have

- [ ] **Show folder size on hover.** Hovering a folder row could show its size as a subtitle, like Finder's Get Info.
- [ ] **⌘N shortcut for New Folder.** Currently only accessible via right-click.

---

## Build & distribution

- [ ] **DMG packaging.** Add a `create-dmg` step for a draggable installer. Waiting until ready to distribute widely.

---

## Top picks by ROI

1. **Open in Finder from breadcrumb** — users expect it, minutes of work
2. **Rename file** — obvious gap in a file browser
3. **Reorder root folders** — quality of life for users with many roots
