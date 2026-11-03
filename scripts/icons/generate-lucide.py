#!/usr/bin/env python3
"""Generate native symbol assets from Lucide 1.62.0 (03f11e2d6adc).

Usage: python generate-lucide.py /path/to/lucide-checkout
Build-time dependencies only: pip install fonttools skia-python
The resulting symbols retain SwiftUI font sizing, tint and image scale.
"""
import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape

import skia
from fontTools.pens.basePen import BasePen
from fontTools.svgLib.path import SVGPath

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(sys.argv[1])
ASSETS = ROOT / 'ServerDock/Resources/Assets.xcassets/Lucide'
MAPPING = json.loads((Path(__file__).with_name('symbol-map.json')).read_text())
missing = [name for name in set(MAPPING.values()) if not (SOURCE / 'icons' / f'{name}.svg').is_file()]
if missing:
    raise SystemExit(f'Missing Lucide SVGs: {sorted(missing)}')


class SkiaPen(BasePen):
    def __init__(self):
        super().__init__(None)
        self.path = skia.Path()

    def _moveTo(self, p): self.path.moveTo(*p)
    def _lineTo(self, p): self.path.lineTo(*p)
    def _curveToOne(self, p1, p2, p3): self.path.cubicTo(*p1, *p2, *p3)
    def _qCurveToOne(self, p1, p2): self.path.quadTo(*p1, *p2)
    def _closePath(self): self.path.close()
    def _endPath(self): pass


def svg_path(path):
    """Outline strokes, including round caps, before asset compilation."""
    parts = []
    iterator = skia.Path.RawIter(path)
    def coords(points):
        return ' '.join(f'{p.x():.5f},{p.y():.5f}' for p in points)
    for verb, points in iterator:
        if verb == skia.Path.kMove_Verb: parts.append('M' + coords(points))
        elif verb == skia.Path.kLine_Verb: parts.append('L' + coords(points[1:]))
        elif verb == skia.Path.kQuad_Verb: parts.append('Q' + coords(points[1:]))
        elif verb == skia.Path.kCubic_Verb: parts.append('C' + coords(points[1:]))
        elif verb == skia.Path.kConic_Verb:
            quads = skia.Path.ConvertConicToQuads(*points, iterator.conicWeight(), 3)
            for i in range(1, len(quads), 2): parts.append('Q' + coords(quads[i:i+2]))
        elif verb == skia.Path.kClose_Verb: parts.append('Z')
    return ' '.join(parts)


ASSETS.mkdir(parents=True, exist_ok=True)
(ASSETS / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
for name in sorted(set(MAPPING.values())):
    pen = SkiaPen()
    SVGPath(str(SOURCE / 'icons' / f'{name}.svg')).draw(pen)
    paint = skia.Paint(Style=skia.Paint.kStroke_Style, StrokeWidth=2,
                       StrokeCap=skia.Paint.kRound_Cap, StrokeJoin=skia.Paint.kRound_Join)
    outline = skia.Path()
    paint.getFillPath(pen.path, outline)
    path = escape(svg_path(outline))
    # Apple custom symbol template, with a 14-unit cap height. Outlined Lucide
    # strokes remain the same weight across states, as in the original icon set.
    svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="3300" height="2200" viewBox="0 0 3300 2200">
  <g id="Notes"><text id="template-version" x="3036" y="1933">Template v.1.0</text></g>
  <g id="Guides">
    <line id="Baseline-S" x1="263" x2="3036" y1="696" y2="696" />
    <line id="Capline-S" x1="263" x2="3036" y1="682" y2="682" />
    <line id="Baseline-M" x1="263" x2="3036" y1="1126" y2="1126" />
    <line id="Capline-M" x1="263" x2="3036" y1="1112" y2="1112" />
    <line id="Baseline-L" x1="263" x2="3036" y1="1556" y2="1556" />
    <line id="Capline-L" x1="263" x2="3036" y1="1542" y2="1542" />
    <rect id="left-margin" x="1394" y="1107" width="1" height="24" />
    <rect id="right-margin" x="1419" y="1107" width="1" height="24" />
  </g>
  <g id="Symbols"><g id="Regular-M" transform="translate(1395 1107)"><path d="{path}" /></g></g>
</svg>
'''
    directory = ASSETS / f'lucide-{name}.symbolset'
    directory.mkdir(exist_ok=True)
    (directory / f'{name}.svg').write_text(svg)
    (directory / 'Contents.json').write_text(json.dumps({
        'info': {'author': 'xcode', 'version': 1},
        'symbols': [{'filename': f'{name}.svg', 'idiom': 'universal'}]
    }, indent=2) + '\n')

# Keep a generated, exhaustive name map in Swift; no runtime parsing or network.
swift = '''import AppKit
import SwiftUI

/// Lucide 1.62.0 vector symbols. Legacy identifiers are aliases only, keeping
/// persisted icon names and feature models compatible with earlier versions.
enum AppIcon {
    static func assetName(for symbol: String) -> String {
        guard let name = symbols[symbol] else {
            assertionFailure("Unmapped UI icon: \\(symbol)")
            return "lucide-circle-question-mark"
        }
        return "lucide-" + name
    }

    static func image(_ symbol: String) -> NSImage? {
        Bundle.app.image(forResource: NSImage.Name(assetName(for: symbol)))
    }

    private static let symbols: [String: String] = [
'''
swift += ''.join(f'        "{key}": "{value}",\n' for key, value in sorted(MAPPING.items()))
swift += '''    ]
}

extension Image {
    init(lucideSymbol symbol: String) {
        self.init(AppIcon.assetName(for: symbol), bundle: .app)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, lucideSymbol symbol: String) {
        self.init { Text(titleKey) } icon: { Image(lucideSymbol: symbol) }
    }

    init<S: StringProtocol>(_ title: S, lucideSymbol symbol: String) {
        self.init { Text(title) } icon: { Image(lucideSymbol: symbol) }
    }
}
'''
(ROOT / 'ServerDock/UI/Components/AppIcon.swift').write_text(swift)
license_dir = ROOT / 'ServerDock/Resources/Licenses'
license_dir.mkdir(exist_ok=True)
(license_dir / 'Lucide.txt').write_text((SOURCE / 'LICENSE').read_text())
print(f'Generated {len(set(MAPPING.values()))} Lucide symbols for {len(MAPPING)} aliases.')
