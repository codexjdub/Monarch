<p align="center">
  <img src="Design/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Monarch icon">
</p>

# Monarch

A native macOS menu bar app for cascading folder navigation. Click the menu bar icon to see your configured shortcuts (folders or files). Hover any folder to peek inside — another peek opens beside it. Keep hovering to drill deeper. Click a file to open it; click a folder to reveal it in Finder.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

## Build & run

```bash
bash build.sh && open Monarch.app
```

This compiles a release build, assembles `Monarch.app`, codesigns it ad-hoc, kills any running instance, and the `open` launches the fresh binary.

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
| Drag file onto folder row | Move/copy into that folder |
| Hold drag over folder (500ms) | Spring-load: peek opens mid-drag |
| ⌘-click rows | Multi-select for bulk drag or open |
| Right-click a row | Context menu (pin, rename, copy path, share, trash…) |

## Preferences

Open via the **···** menu → **Preferences…**

- **Shortcuts** — drag to reorder, click **−** to remove
- **Global hotkey** — record any key combo to open Monarch from anywhere
- **Launch at login** — start Monarch automatically when you log in
- **Show item count and size footer** — toggle the footer bar at the bottom of each level

## Icon regeneration

After changing artwork in `Design/AppIcon.appiconset/`:

```bash
swift scripts/apply_w4.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

See [Design/README.md](Design/README.md) for details.

## License

MIT — see [LICENSE](LICENSE).
