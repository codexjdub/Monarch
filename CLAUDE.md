# Monarch — Project Context for Claude

This file captures the durable knowledge needed to work on Monarch effectively. Read it first whenever a new session starts here. Update it when significant architectural or design decisions change.

---

## What Monarch is

A native macOS menu bar app for **cascading folder navigation** — a lean Folder Peek clone. Click the menu bar icon, see your configured root folders. Hover a folder row → a "peek" window opens beside it showing that folder's contents. Hover deeper → another peek. Click any file to open it; click a folder to reveal it in Finder.

Originally named **FolderMenu**, renamed to **Monarch** mid-development. Some directory paths (e.g. the repo root `FolderMenu/`) may still carry the old name; the package, target, bundle, and all UI strings use Monarch.

**Tech stack**: Swift 6.3 via Xcode CLT (no Xcode IDE), Swift Package Manager, AppKit + SwiftUI hybrid, macOS 13+. Zero external dependencies.

---

## Architecture overview

```
main.swift
  └─ AppDelegate
       ├─ FolderStore                  // persisted list of root folder URLs
       └─ StatusItemController         // owns NSStatusItem, popover, hotkey
            ├─ CascadeModel            // state machine: levels, focus, watchers, pins, recents
            ├─ CascadeRootView         // SwiftUI root for the popover
            └─ HotkeyManager           // Carbon-based global hotkey
```

The popover hosts a `CascadeRootView`, which renders the level-0 folder list. Hovering a folder row triggers `CascadeModel.openFolderPeek(...)`, which opens a peek `NSWindow` containing a `LevelListView` for that folder. Multiple peek levels stack rightward.

Cross-component coupling uses `NotificationCenter` with namespaced names: `.monarchRemoveRoot`, `.monarchPinsChanged`. Acceptable today; revisit if it grows past 4–5 notifications.

---

## File map

### Sources/Monarch/
| File | Role |
|---|---|
| `main.swift` | NSApplication boot, sets `.accessory` activation policy |
| `AppDelegate.swift` | Constructs `FolderStore` + `StatusItemController` |
| `StatusItemController.swift` | NSStatusItem, popover lifecycle, hotkey wiring, status icon loading |
| `Cascade.swift` | `CascadeModel` — level state, FSEvents lifecycle, pin/recent composition, focus tracking, breadcrumb navigation, spring-load |
| `CascadeViews.swift` | SwiftUI views: `LevelListView`, `BreadcrumbView`, `CascadeRootView`, `LevelListBody`, `ResizeGripSwiftUI` |
| `DraggableFileRow.swift` | NSView-backed row: drag-source, drop-target, context menu, spring-load timer, thumbnail rendering |
| `FileItem.swift` | Item model + `PreviewKind` enum + per-extension preview routing |
| `FolderStore.swift` | Persisted root folder URLs (UserDefaults / security-scoped bookmarks) |
| `FolderWatcher.swift` | FSEvents wrapper, 150ms debounce, main-queue callbacks |
| `ThumbnailCache.swift` | `QLThumbnailGenerator` LRU (400 entries), keyed by URL+mtime |
| `FileDrop.swift` | Copy/move helper with Finder-style "copy", "copy 2" collision naming + same-volume vs cross-volume operation heuristic |
| `PinStore.swift` | Per-folder pinned files persisted as JSON in UserDefaults |
| `HotkeyManager.swift` | Carbon `RegisterEventHotKey` |
| `PreferencesWindow.swift` | Settings UI (folders, hotkey, launch-at-login) |
| `PreviewViews.swift` | Text (NSTextView), image, PDF, video/audio, Quick Look routing |
| `QuickLookManager.swift` | Fullscreen `QLPreviewPanel` integration |
| `Settings.swift` | UserDefaults convenience accessors |

### Top-level
| Path | Role |
|---|---|
| `Package.swift` | SPM manifest, name + target = `Monarch`, Sources path = `Sources/Monarch` |
| `Resources/Info.plist` | Bundle metadata, `LSUIElement = true` (hides from Dock) |
| `Resources/AppIcon.icns` | Compiled production app icon |
| `Resources/AppIcon.iconset/` | Derived PNGs (overwritten by `scripts/apply_w4.swift`) |
| `Resources/StatusIcon.png` | Production menu-bar template image (144×144 gray+alpha) |
| `Design/AppIcon.appiconset/` | **Source of truth** for app icon artwork (10 PNGs, transparent bg) |
| `Design/StatusIcon.png` | **Source of truth** copy of menu bar icon |
| `Design/README.md` | Explains how to regenerate the production icon |
| `scripts/apply_w4.swift` | Active production tool: composites Design artwork onto off-white tile at 1.25× scale, writes to `Resources/AppIcon.iconset` |
| `build.sh` | `swift build -c release`, assembles `Monarch.app`, copies icons + Info.plist, ad-hoc codesigns, `pkill -x Monarch` |
| `IMPROVEMENTS.md` | Living backlog of improvements |
| `CLAUDE.md` | This file |

---

## Build & run

```bash
bash build.sh && open Monarch.app
```

`build.sh` does: release build → copies binary into `Monarch.app/Contents/MacOS/` → copies `Info.plist` and icons into `Resources/` → ad-hoc codesigns → pkills any running instance. The `pkill` lets the next `open` actually launch the freshly-built binary.

**Iterative development**: edit code → `bash build.sh && open Monarch.app`. No watch mode.

To regenerate the app icon after changing Design source artwork or the W4 recipe:
```bash
swift scripts/apply_w4.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

---

## Conventions

### Naming
- App is **Monarch**. The repo directory may still be `FolderMenu` (legacy).
- Notification names: `.monarchRemoveRoot`, `.monarchPinsChanged`. Pattern: `.monarch<Verb>`.
- UserDefaults keys: prefer simple lowercase strings (`pinnedFiles_v1`). Don't rename — these contain user data.
- Bundle identifier: `com.monarch.app`.

### Threading
- All UI/AppKit code is `@MainActor`.
- FSEvents callbacks bounce to the main queue inside `FolderWatcher`.
- `PinStore`, `ThumbnailCache` are `@MainActor` singletons.

### State management
- `CascadeModel` is the single source of truth for cascade state. SwiftUI views observe it via `@ObservedObject`.
- Focus is tracked by URL within `reloadLevelPreservingFocus(_:)` so refreshes (FSEvents, pin changes, sort changes) don't lose the user's place.
- Pin/Recent appear as **sections** in the regular folder listing, not separate views. Sections use range descriptors (`Section.range: Range<Int>`) over the flat `items` array so existing keyboard/mouse code stays unchanged.

### Drag & drop
- File rows are both drag sources (`NSItemProvider` of file URL) and drop targets (folders only).
- Drop heuristic in `FileDropHelper.preferredOperation`: same-volume = move (Option overrides to copy); cross-volume = copy (Command overrides to move). Mirrors Finder.
- Self-drops and subtree drops are rejected.

---

## Key design decisions (and why)

1. **Click folder = open in Finder, not drill down.** Drilling down happens via hover (peek) or spring-load. Click-to-open feels more decisive and avoids accidental peek dismissal. (User-requested; pre-existing UX never disputed.)

2. **Spring-loaded folders during drag.** Holding a dragged file over a folder row for 500ms opens its peek, allowing drilling into subfolders mid-drag. Implemented via `DispatchWorkItem` timer scheduled in `draggingEntered`, canceled in `draggingExited`/`draggingEnded`.

3. **Pinned/Recent as sections, not separate views.** Keeps a single keyboard navigation model. Recent appears only when folder has ≥10 items and ≥3 non-pinned non-directory candidates (avoids cluttering small folders).

4. **FSEvents debounce 150ms.** Burst writes (e.g. saving in an editor) collapse to one reload. Empirically responsive without thrashing.

5. **Per-folder pin state, not global.** Pins are scoped to the parent folder where they appear; same file pinned in folder A doesn't auto-pin in folder B. Persisted as `[folderPath: [pinnedURLPaths]]` in UserDefaults under key `pinnedFiles_v1`.

6. **Focus preservation by URL.** When a folder reloads (FSEvents fires, pins change, sort changes), the model snapshots the current focused item's URL, then re-finds it by URL after reload. Prevents focus jumping when item indices shift.

7. **Preview content via `Level.Content` enum.** A level can be `.folder(items, sections, rowFrames)` or `.preview(kind, url)`. This unification means peek windows can show either a folder listing or a file preview depending on what the user hovered.

8. **No Xcode project.** Pure SPM. Trade-off: simpler tooling, no Interface Builder, harder to integrate Sparkle/asset catalogs. Worked great so far.

---

## Things we tried and rejected

- **Procedurally drawn app icon** (Core Graphics gradient + SF Symbol folder + 🦋 emoji). Several iterations (variant A/B/C/D/E for app icon, S0/S1/S2 for status icon, F/G/H for pixel art). Rejected in favor of AI-generated artwork because emoji + SF Symbol composition always looked like "two stuck-together pieces" rather than a designed icon. The procedural variants are still in `scripts/*_variants.swift` and `scripts/pixel_variants.swift` for reference (slated for deletion per IMPROVEMENTS.md).
- **Wing-only status icon.** Considered but rejected — losing the folder shape weakened the "this is a file/folder app" signal at first glance. Folder + wing won.
- **Black-silhouette emoji butterfly** in status icon. Tried rasterizing the emoji and masking to black via `.sourceIn`; it works in theory but Apple's color-emoji glyph path doesn't compose cleanly with template images. Replaced with a hand-drawn silhouette PNG.

---

## Current branding state

- **App icon**: Off-white gradient rounded tile + dark folder + orange monarch butterfly emerging from folder. AI-generated artwork composited via `scripts/apply_w4.swift` (W4 recipe = 1.25× artwork on off-white gradient tile). Source in `Design/AppIcon.appiconset/`, compiled output `Resources/AppIcon.icns`.
- **Status icon**: Single 144×144 8-bit gray+alpha PNG silhouette of a folder with a butterfly wing cutout on the right side. Marked `isTemplate = true` so macOS auto-inverts for dark menu bars and applies hover/selection tinting. Source: `Design/StatusIcon.png`, production: `Resources/StatusIcon.png`.

---

## Open questions / known issues

- `HotkeyManager.swift:68` has a `var hkID` that should be `let` — pollutes every build with a warning.
- No tests anywhere. Filesystem + drag/drop + concurrency code is a regression magnet.
- App is ad-hoc codesigned (`-`). Users see "Apple cannot verify Monarch" on first launch. Real signing + notarization needed before distribution.
- `CFBundleVersion` and `CFBundleShortVersionString` are placeholders.
- `scripts/` contains ~10 one-shot exploration scripts plus their preview output dirs. Only `apply_w4.swift` is load-bearing. Cleanup pending in IMPROVEMENTS.md.
- See `IMPROVEMENTS.md` for the full backlog with ROI rankings.

---

## When in doubt

- Read `IMPROVEMENTS.md` to know what's prioritized.
- Read `Design/README.md` before touching any icon-related code.
- Default to `bash build.sh && open Monarch.app` for verification — it kills the running instance for you.
- The user prefers numbered options when given choices (their explicit request earlier in the project).
