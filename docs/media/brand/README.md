# Sotto Soft Wave assets

`soft-wave-app-master.png` is the reviewed raster master derived from the supplied Soft Wave reference sheet. `soft-wave-app.svg` is an editable vector reconstruction of the same direction; its curves and gradient are close, but it is not the pixel-identical source of the raster master. Do not present it as one.

`soft-wave-menu.svg` is the cream wave used for the menu bar template. The asset catalog stores 18 pt / 36 px variants, and `SottoMenuBarIdentity` supplies the native glass capsule around it. The OS template treatment adapts the mark to the menu bar appearance. The PNG exports cover 16, 18, and 32 pt at 1× and 2×.

Run `./scripts/generate-brand-assets.sh` to recreate all `AppIcon.appiconset` PNGs, the menu bar exports, and `size-matrix.png` from the masters. This regeneration step needs ImageMagick; normal Xcode builds use the committed PNGs.

`preview-sheet.png` shows the Dock, menu bar, in-app, and marketing roles. The in-app and marketing panels are usage mockups, not additional UI shipped in Sotto.
