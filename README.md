<p align="center">
  <img src="Design/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Monarch icon">
</p>

# Monarch

A native macOS menu bar app for cascading folder navigation. Click the menu bar icon to see your configured shortcuts (folders or files). Hover any folder to peek inside — another peek opens beside it. Keep hovering to drill deeper. Click a file to open it; click a folder to reveal it in Finder.

Peek placement adapts near screen edges, so the cascade can flip or clamp intelligently instead of blindly extending to the right.

Root shortcuts can also have a custom display name inside Monarch without renaming the file or folder on disk. When a display name is set, Monarch shows the shortcut's path as the subtitle.

Monarch also keeps a level-0 **Frequent** section for the files and folders you actually open through Monarch. It defaults to 3 items, but you can change that in Preferences. Items must be opened at least twice before they appear, older usage decays over time, and anything already configured as a root shortcut is excluded so the same path never appears twice. You can also hide an individual item from Frequent from its context menu.

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
| Click a file | Open the file |
| Click a folder | Reveal in Finder |
| Arrow keys | Navigate rows |
| Return | Open focused item |
| Space | Quick Look focused file |
| ⌘F | Search / filter the current level |
| Esc | Close peek / close Monarch |
| Drag file/folder onto menu bar icon | Add it to your shortcuts |
| Drag file onto folder row | Move/copy into that folder |
| Hold drag over folder (500ms) | Spring-load: peek opens mid-drag |
| ⌘-click rows | Multi-select for bulk drag or open |
| Right-click a row | Context menu (pin, rename, set display name for root shortcuts, add to Monarch, open in Terminal, copy path, share, trash…) |

## Preferences

Open via the **···** menu → **Preferences…**

- **Shortcuts** — drag to reorder, click **−** to remove
- **Text size** — Small / Medium / Large; scales row height, font, and icon size together
- **Show item count and size footer** — toggle the footer bar at the bottom of each level
- **Show Frequent section** — show or hide the level-0 Frequent group
- **Frequent items shown** — choose how many Frequent items appear at level 0
- **Reset Frequent…** — clear the Frequent ranking and start fresh
- **Launch at login** — start Monarch automatically when you log in
- **Global hotkey** — record any key combo to open Monarch from anywhere (⌘, opens Preferences from the popover)
- **Preferred terminal** — choose which terminal app Monarch uses for **Open in Terminal**

## License

MIT — see [LICENSE](LICENSE).
