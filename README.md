<p align="center">
  <img src="Design/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Monarch icon">
</p>

# Monarch

A native macOS menu bar app for cascading folder navigation. Click the menu bar icon, see your configured root folders. Hover any folder to peek inside — another peek opens beside it. Keep hovering to drill deeper. Click a file to open it; click a folder to reveal it in Finder.

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
| Esc | Close peek / close Monarch |
| Drag file onto folder row | Move/copy into that folder |
| Hold drag over folder (500ms) | Spring-load: peek opens mid-drag |
| Right-click a row | Context menu (pin, copy path, share, trash…) |
| ⌘-click rows | Multi-select for bulk drag or open |

## Icon regeneration

After changing artwork in `Design/AppIcon.appiconset/`:

```bash
swift scripts/apply_w4.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

See [Design/README.md](Design/README.md) for details.

## License

MIT — see [LICENSE](LICENSE).
