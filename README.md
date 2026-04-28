<p align="center">
  <img src="Design/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Monarch icon">
</p>

# Monarch

A native macOS menu bar app for cascading folder navigation. Click the menu bar icon to see your configured shortcuts (folders or files). Hover any folder to peek inside — another peek opens beside it. Keep hovering to drill deeper. Click a file to open it; click a folder to reveal it in Finder.

Hover a file to preview it inline: images, PDFs, syntax-highlighted source code and text files, archive contents, and more. Use the **↗** button in the preview header to open the file in its default app.

Peek placement adapts near screen edges, so the cascade can flip or clamp intelligently instead of blindly extending to the right.

Root shortcuts can also have a custom display name inside Monarch without renaming the file or folder on disk. When a display name is set, Monarch shows the shortcut's path as the subtitle.

Monarch also keeps a level-0 **Frequent** section for the files and folders you actually open through Monarch. It defaults to 3 items, but you can change that in Preferences. Items must be opened at least twice before they appear, older usage decays over time, and anything already configured as a root shortcut is excluded so the same path never appears twice. You can also hide an individual item from Frequent from its context menu.

If you prefer a more hands-off launcher feel, Monarch can also optionally open when you hover the menu bar icon for a short delay.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

## Build & run

```bash
bash build.sh
```

This compiles a release build, assembles `Monarch.app`, codesigns it ad-hoc, kills any running instance, and relaunches the fresh binary.

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
| Right-click a row | Context menu (pin, rename, set display name for root shortcuts, add to Monarch, open in Terminal, copy path, share, trash…) |

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
