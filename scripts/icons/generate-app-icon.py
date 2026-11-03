#!/usr/bin/env python3
"""Render the selected A artwork into app icons and menu-bar template assets."""
import json
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / 'assets/app-icon.svg'
resources = root / 'ServerDock/Resources'
catalog = resources / 'Assets.xcassets/AppIcon.appiconset'
images = json.loads((catalog / 'Contents.json').read_text())['images']
with tempfile.TemporaryDirectory() as temp:
    iconset = Path(temp) / 'AppIcon.iconset'
    iconset.mkdir()
    for image in images:
        side = int(image['size'].split('x')[0]) * int(image['scale'][0])
        output = catalog / image['filename']
        subprocess.run(['rsvg-convert', '-w', str(side), '-h', str(side), '-o', str(output), str(source)], check=True)
        (iconset / image['filename']).write_bytes(output.read_bytes())
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
(resources / 'AppIcon.png').write_bytes((catalog / 'icon_512x512@2x.png').read_bytes())

mark_catalog = resources / 'Assets.xcassets/ServerDockMark.imageset'
mark_catalog.mkdir(exist_ok=True)
mark_images = []
for scale in (1, 2, 3):
    filename = 'mark.png' if scale == 1 else f'mark@{scale}x.png'
    subprocess.run([
        'rsvg-convert', '-w', str(18 * scale), '-h', str(18 * scale),
        '-o', str(mark_catalog / filename), str(root / 'assets/menu-bar-icon.svg'),
    ], check=True)
    mark_images.append({'idiom': 'universal', 'filename': filename, 'scale': f'{scale}x'})
(mark_catalog / 'Contents.json').write_text(json.dumps({
    'images': mark_images,
    'info': {'author': 'xcode', 'version': 1},
    'properties': {'template-rendering-intent': 'template'},
}, indent=2) + '\n')

brand_catalog = resources / 'Assets.xcassets/ServerDockBrandMark.imageset'
brand_catalog.mkdir(exist_ok=True)
brand_images = []
for scale in (1, 2, 3):
    filename = 'brand.png' if scale == 1 else f'brand@{scale}x.png'
    subprocess.run([
        'rsvg-convert', '-w', str(128 * scale), '-h', str(128 * scale),
        '-o', str(brand_catalog / filename), str(root / 'assets/app-symbol.svg'),
    ], check=True)
    brand_images.append({'idiom': 'universal', 'filename': filename, 'scale': f'{scale}x'})
(brand_catalog / 'Contents.json').write_text(json.dumps({
    'images': brand_images,
    'info': {'author': 'xcode', 'version': 1},
    'properties': {'template-rendering-intent': 'original'},
}, indent=2) + '\n')
print('Updated app icons, transparent in-app brand assets, and menu-bar template assets.')
