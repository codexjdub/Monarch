<p align="center">
  <img src="Design/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Monarch icon">
</p>

# Monarch

A native macOS menu bar app for **cascading folder navigation**. Click a folder to peek inside, hover deeper, click a file to open it — without ever leaving the keyboard or losing your place.

<!-- TODO: drop a screenshot/gif of a 3-level peek cascade here -->

## Highlights

- **Cascading peeks.** Hover any folder to open a peek window beside it. Hover deeper for another. Placement adapts near screen edges so the cascade clamps or flips intelligently instead of running off the screen.
- **Inline file preview.** Hover a file to preview it: images (downsampled for speed), PDFs, syntax-highlighted text & source code, archive contents, fonts, and more. The **↗** button in the preview header opens the file in its default app.
- **Frequent + shortcuts.** Pin folders/files as root shortcuts (drag onto the menu bar icon to add). Monarch also surfaces a **Frequent** section at the top, ranked by your actual usage with a recency decay.
- **Volume awareness.** Small badges show when an item is on iCloud Drive, a network share, or an external drive. When a volume gets ejected, Monarch shows a friendly "Volume not mounted" state instead of a generic error — and refreshes automatically when the drive comes back.
- **Keyboard everything.** Global hotkey to open. Arrow keys, ⌘F to search, Space for Quick Look, Return to open, Esc to back out.
- **Drag & drop.** Drag files between folders for Finder-style copy/move. Hold a drag over a folder for 500ms to spring-load into it.
- **Custom display names.** Give a root shortcut a Monarch-only alias without renaming the file or folder on disk.
- **Hover-open (optional).** If you prefer a launcher feel, Monarch can open when you hover the menu bar icon for a short delay.

## Install

1. Download `Monarch-X.Y.zip` from the [latest release](https://github.com/codexjdub/Monarch/releases).
2. Unzip and move `Monarch.app` to `/Applications`.
3. Right-click → **Open** the first time (the build is ad-hoc signed, so macOS asks you to confirm).
4. The Monarch icon appears in the menu bar — click it to start configuring shortcuts.

## Build from source

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
bash build.sh
```

This compiles a universal release build, assembles `Monarch.app`, ad-hoc codesigns it, kills any running instance, and relaunches the fresh binary.

## Usage

| Action | Result |
|---|---|
| Click menu bar icon | Open Monarch |
| Hover a folder row | Open peek window |
| Hover a file | Open inline preview (image, PDF, text, archive…) |
| Click **↗** in preview header | Open the previewed file |
| Click a file | Open the file |
| Click a folder | Reveal in Finder |
| ↑ / ↓ | Move highlighted row |
| → | Open folder peek or file preview for highlighted row |
| ← | Go back one peek level; at level 0, close Monarch |
| Return | Open highlighted item |
| Space | Quick Look focused file |
| ⌘F | Search / filter the current level |
| Esc | Clear selection first, then exit search / close peek / close Monarch |
| Drag file/folder onto menu bar icon | Add it to your shortcuts |
| Drag file onto folder row | Move/copy into that folder |
| Hold drag over folder (500ms) | Spring-load: peek opens mid-drag |
| ⌘-click rows | Multi-select for bulk drag or open |
| Right-click a row | Context menu (pin, rename, set display name, add to Monarch, open in Terminal, copy path, share, trash…) |

In search mode, `←` keeps its normal text-editing behavior in the search field. Use `Esc` to exit search, then `←` to navigate back or close Monarch. Exception: if a file preview peek is open, `←` closes that preview first even while search is active.

## Preferences

Open via the **···** menu → **Preferences…**

- **Shortcuts** — drag to reorder, click **−** to remove, and drag the handle beneath the list to resize its own scrollable area
- **Text size** — Small / Medium / Large; scales row height, font, and icon size together
- **Appearance** — System / Light / Dark
- **Show item count and size footer** — toggle the footer bar at the bottom of each level
- **Open when hovering over the menu bar icon** — optional delayed hover-open for the status item
- **Show Frequent section** — show or hide the level-0 Frequent group
- **Items to show** — choose how many Frequent items appear at level 0
- **Reset Frequent…** — clear the Frequent ranking and start fresh
- **Launch at login** — start Monarch automatically when you log in
- **Global hotkey** — record any key combo to open Monarch from anywhere (⌘, opens Preferences from the popover)
- **Preferred terminal** — choose which terminal app Monarch uses for **Open in Terminal**

## License

MIT — see [LICENSE](LICENSE).
