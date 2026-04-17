# Design assets

Original source artwork for Monarch's icons. Keep these — the production icons in `Resources/` are derived from them.

## Files

### `AppIcon.appiconset/`
Original AI-generated dark folder + monarch butterfly artwork in Xcode asset-catalog format. Ten PNG sizes (16/32/128/256/512 × 1x and 2x) plus `Contents.json`. Each PNG has a transparent background.

**To regenerate the production app icon:**
```bash
swift scripts/apply_w4.swift          # composites artwork onto off-white tile at 1.25x scale
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

The `apply_w4.swift` script reads from this folder, applies the W4 treatment (off-white gradient tile + 1.25× artwork), and writes scaled PNGs into `Resources/AppIcon.iconset/`. The `iconutil` step compiles those PNGs into the `.icns` file the app actually loads.

### `StatusIcon.png`
Original 144×144 8-bit gray+alpha silhouette of the folder + butterfly wing for the menu bar. Identical to `Resources/StatusIcon.png` (the production copy). Kept here as the immutable source so future tweaks (padding, alternate weights, etc.) can derive from a known-good origin.

## Notes
- Don't edit files in `AppIcon.appiconset/` directly — they're the source of truth. Generate variants via scripts.
- If you change the W4 recipe (tile color, scale factor), update `scripts/apply_w4.swift`.
- The app icon files in `Resources/AppIcon.iconset/` are derived artifacts; they get overwritten every time the script runs.
