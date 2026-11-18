#!/usr/bin/env python3
# Generates the app icon SVG. Usage: generate-icon.py rounded|square|dark|tinted > out.svg
# See scripts/make-icons.sh for rendering into the asset catalog.
#
# An ember-red wax seal, pressed with a signet that leaves a flame, on warm parchment.
# Light: parchment background. Dark: near-black background, same wax. Tinted: greyscale, which iOS recolours.
import math, sys

mode = sys.argv[1]
rounded = mode == "rounded"

P = {
    "bg0": "#FBF5EC", "bg1": "#EEDFC8",
    "wax_hi": "#FF8A55", "wax0": "#E2472C", "wax1": "#A8161D", "wax2": "#5E0A12",
    "pit0": "#86121A", "pit1": "#C9382A",
    "rim_hi": "#FFC09A", "rim_hi_op": "0.55", "rim_lo": "#4A0810", "rim_lo_op": "0.55",
    "glyph": "#7A0E16", "glyph_hi": "#FFB38C", "glyph_hi_op": "0.7",
    "shadow": "#5A2A10", "shadow_op": "0.28", "gloss_op": "0.35",
}
if mode == "dark":
    P.update(bg0="#221B17", bg1="#0E0B0A", shadow="#000000", shadow_op="0.6")
elif mode == "tinted":
    P.update(bg0="#000000", bg1="#000000",
             wax_hi="#FFFFFF", wax0="#E6E6E6", wax1="#BDBDBD", wax2="#8A8A8A",
             pit0="#7A7A7A", pit1="#B0B0B0", rim_hi="#FFFFFF", rim_lo="#3A3A3A",
             glyph="#4A4A4A", glyph_hi="#FFFFFF", shadow_op="0", gloss_op="0.3")


def blob(cx, cy, r, n=900):
    """Organic wax outline: a circle with a few soft, uneven lobes where the wax spread."""
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        wobble = (0.035 * math.sin(3 * a + 0.6) + 0.025 * math.sin(5 * a + 2.1)
                  + 0.018 * math.sin(8 * a + 4.0) + 0.012 * math.sin(13 * a + 1.3))
        rr = r * (1 + wobble)
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + " Z"


def path(points_cmds, cx, cy, k):
    """Scales a path written in unit coordinates (centre 0,0; y down) to the icon."""
    out = []
    for cmd, pts in points_cmds:
        out.append(cmd + " ".join(f"{cx + x * k:.1f},{cy + y * k:.1f}" for x, y in pts))
    return " ".join(out) + " Z"


FLAME = [
    ("M", [(0, -1)]),
    ("C", [(0.16, -0.62), (0.64, -0.38), (0.64, 0.18)]),
    ("C", [(0.64, 0.58), (0.35, 0.86), (0, 0.86)]),
    ("C", [(-0.35, 0.86), (-0.64, 0.58), (-0.64, 0.2)]),
    ("C", [(-0.64, -0.12), (-0.44, -0.3), (-0.32, -0.52)]),
    ("C", [(-0.26, -0.3), (-0.16, -0.2), (-0.06, -0.18)]),
    ("C", [(-0.13, -0.5), (-0.06, -0.8), (0, -1)]),
]
CORE = [
    ("M", [(0.03, -0.12)]),
    ("C", [(0.12, 0.08), (0.32, 0.2), (0.32, 0.44)]),
    ("C", [(0.32, 0.64), (0.17, 0.74), (0, 0.74)]),
    ("C", [(-0.17, 0.74), (-0.32, 0.64), (-0.32, 0.46)]),
    ("C", [(-0.32, 0.26), (-0.12, 0.12), (0.03, -0.12)]),
]


clip = '<clipPath id="shape"><rect width="1024" height="1024" rx="230"/></clipPath>' if rounded else ""
group_open = '<g clip-path="url(#shape)">' if rounded else "<g>"
cx, cy, R = 512, 520, 330      # wax
pit = 228                       # pressed disc

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    {clip}
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{P['bg0']}"/>
      <stop offset="1" stop-color="{P['bg1']}"/>
    </linearGradient>
    <radialGradient id="wax" cx="0.36" cy="0.3" r="0.8">
      <stop offset="0" stop-color="{P['wax_hi']}"/>
      <stop offset="0.3" stop-color="{P['wax0']}"/>
      <stop offset="0.75" stop-color="{P['wax1']}"/>
      <stop offset="1" stop-color="{P['wax2']}"/>
    </radialGradient>
    <linearGradient id="pit" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{P['pit0']}"/>
      <stop offset="1" stop-color="{P['pit1']}"/>
    </linearGradient>
    <linearGradient id="rimHi" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0.45" stop-color="{P['rim_hi']}" stop-opacity="0"/>
      <stop offset="1" stop-color="{P['rim_hi']}" stop-opacity="{P['rim_hi_op']}"/>
    </linearGradient>
    <linearGradient id="rimLo" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{P['rim_lo']}" stop-opacity="{P['rim_lo_op']}"/>
      <stop offset="0.55" stop-color="{P['rim_lo']}" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="gloss" cx="0.35" cy="0.18" r="0.45">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="{P['gloss_op']}"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="24" stdDeviation="30" flood-color="{P['shadow']}" flood-opacity="{P['shadow_op']}"/>
    </filter>
    <filter id="soft" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur stdDeviation="3"/>
    </filter>
  </defs>
  {group_open}
    <rect width="1024" height="1024" fill="url(#bg)"/>

    <!-- Wax -->
    <path d="{blob(cx, cy, R)}" fill="url(#wax)" filter="url(#shadow)"/>
    <path d="{blob(cx, cy, R)}" fill="url(#gloss)"/>

    <!-- Pressed disc: dark at the top, lit at the bottom, so it reads as sunk into the wax -->
    <circle cx="{cx}" cy="{cy}" r="{pit + 16}" fill="none" stroke="url(#rimHi)" stroke-width="18" filter="url(#soft)"/>
    <circle cx="{cx}" cy="{cy}" r="{pit}" fill="url(#pit)"/>
    <circle cx="{cx}" cy="{cy}" r="{pit - 4}" fill="none" stroke="url(#rimLo)" stroke-width="14" filter="url(#soft)"/>
    <circle cx="{cx}" cy="{cy}" r="{pit - 34}" fill="none" stroke="{P['glyph']}" stroke-opacity="0.45" stroke-width="5"/>

    <!-- Flame impression: lit lower edge, the recess, then the raised core left by the engraving -->
    <path d="{path(FLAME, cx, cy - 6, 150)}" fill="{P['glyph_hi']}" fill-opacity="{P['glyph_hi_op']}" filter="url(#soft)" transform="translate(0,7)"/>
    <path d="{path(FLAME, cx, cy - 6, 150)}" fill="{P['glyph']}"/>
    <path d="{path(CORE, cx, cy - 6, 150)}" fill="url(#pit)"/>
  </g>
</svg>
'''
print(svg)
