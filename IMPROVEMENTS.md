# Monarch — Improvement Backlog

Living checklist of things to improve. Move items between sections as their status changes. Add `(YYYY-MM-DD)` next to "Done" items so we can see history.

---

## In Progress
_(none)_

---

## Friction points

- [ ] **Peek windows run off-screen.** Popover always anchors to the menu bar icon. With many peek levels, peeks run off the right edge of the screen.

---

## Nice to have

- [ ] **Show folder size on hover.** Hovering a folder row could show its size as a subtitle, like Finder's Get Info.
- [ ] **Font size options.** Some users may prefer smaller or larger text in the row list. Consider a Small / Medium / Large setting in Preferences.

---

## Build & distribution

- [ ] **DMG packaging.** Add a `create-dmg` step for a draggable installer. Waiting until ready to distribute widely.

---

## Top picks by ROI

1. **Peek windows off-screen** — real usability problem for large monitors with many peek levels
2. **Show folder size on hover** — small, useful detail

---

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
- [x] **Rename file.** Right-click → Rename… opens an inline alert with the current name pre-filled. (2026-04-17)
- [x] **Reorder root shortcuts.** Drag-to-reorder list in Preferences window; changes apply immediately. (2026-04-17)
- [x] **Files as level-0 shortcuts.** Level 0 accepts files as well as folders (Add… opens files and directories). (2026-04-17)
- [x] **Resizable Preferences window.** Window is now resizable; shortcuts list expands to fill the extra space. (2026-04-17)
