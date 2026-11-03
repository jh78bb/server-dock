# App icon assets

[Documentation index](README.md)

The app uses the original **A** symbol selected from the three-concept comparison. The selected raster artwork was extracted from that board without redrawing its geometry or generating another variation; the white presentation background was removed. The source symbol is 356 × 393 pixels, so larger app icon sizes resample this artwork rather than claiming to be a new vector master.

| File | Purpose |
|---|---|
| `assets/app-icon-symbol.png` | Transparent color master of the selected original A |
| `assets/menu-bar-symbol.png` | Black alpha mask with the same silhouette |
| `assets/app-icon.svg` | Layout wrapper centering the color master on a white rounded tile within a 1024 × 1024 canvas |
| `assets/app-symbol.svg` | Transparent color mark wrapper for in-app branding |
| `assets/menu-bar-icon.svg` | Layout wrapper for the menu-bar mask |
| `ServerDock/Resources/AppIcon.png` and `AppIcon.icns` | Generated app/Dock icon resources |
| `ServerDock/Resources/Assets.xcassets/AppIcon.appiconset` | Generated macOS app icon sizes |
| `ServerDock/Resources/Assets.xcassets/ServerDockBrandMark.imageset` | Transparent color mark for the welcome and About views |
| `ServerDock/Resources/Assets.xcassets/ServerDockMark.imageset` | Generated 1×, 2× and 3× menu-bar template images |

Paths above are relative to the repository root. Keep the PNG masters alongside the SVG wrappers; the wrappers reference those files.

To regenerate on macOS, install `librsvg` (for `rsvg-convert`) and run from the repository root:

```bash
brew install librsvg
python3 scripts/icons/generate-app-icon.py
```

The generator also uses macOS `iconutil`. Review the 16 px, 32 px and Dock-sized results after any source change. The menu-bar mark uses the system label color while retaining the existing background-task status dot and its animation. App identity/bundle identifiers are unchanged.

Only the Dock/application icon uses the white rounded background. In-app branding uses the transparent color mark; the menu bar uses the separate monochrome template.
