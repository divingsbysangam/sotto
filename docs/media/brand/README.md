# Sotto Soft Wave assets

`soft-wave-app-master.png` is the reviewed raster master derived from the supplied Soft Wave reference sheet. `soft-wave-app.svg` is an editable vector reconstruction of the same direction; its curves and gradient are close, but it is not the pixel-identical source of the raster master. Do not present it as one.

`soft-wave-menu.svg` is the cream wave master; `soft-wave-menu-light.svg` is its dark-mark counterpart. The editable wave exports cover 16, 18, and 32 pt at 1× and 2×. The app's `MenuBarGlassIcon` image set combines the wave and translucent bubble at 32 × 24 pt, with 1×/2× and light/dark variants. The bubble is part of the image because SwiftUI's `MenuBarExtra` label did not display the separate glass background in the installed menu bar item.

Run `./scripts/generate-brand-assets.sh` to recreate all `AppIcon.appiconset` PNGs, the menu bar exports, glass bubble images, and `size-matrix.png` from the masters. This regeneration step needs ImageMagick; normal Xcode builds use the committed PNGs.

`preview-sheet.png` shows the Dock, menu bar, in-app, and marketing roles. The in-app and marketing panels are usage mockups, not additional UI shipped in Sotto. The actual app icon uses the reviewed raster master; the menu bar bubble uses the committed `MenuBarGlassIcon` variants.

`menu-popover-light.png` and `menu-popover-dark.png` are captures of the real `MenuBarView` rendered in an isolated test window with synthetic transcript data and the opaque accessibility fallback. They verify layout and contrast; live menu bar placement requires a desktop check.
