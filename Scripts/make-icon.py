#!/usr/bin/env python3
"""Mezzanine's app icon, "The balcony": a lit screen seen over the mezzanine's rails, the sun going down
behind the first one. Writes Mezzanine/AppIcon.icon (an Icon Composer document, every shape a filled
SVG path) and design/icon/mezzanine-icon.svg (the same drawing with named layers, for Affinity).

    python3 Scripts/make-icon.py
"""
import json, shutil
from pathlib import Path

root = Path(__file__).resolve().parent.parent
icon, master = root / "Mezzanine" / "AppIcon.icon", root / "design" / "icon" / "mezzanine-icon.svg"

def stops(st): return "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in st)
def lin(x1, y1, x2, y2, st): return f'<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stops(st)}</linearGradient>'
def rad(cx, cy, r, st, sy=1): return (f'<radialGradient id="%s" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{r}" '
                                      f'gradientTransform="translate({cx} {cy}) scale(1 {sy}) translate({-cx} {-cy})">{stops(st)}</radialGradient>')

# The rails are parabolas: y at the sides, sagging by `sag` in the middle.
def rail_y(x, y, sag, x0, x1):
    t = (x - x0) / (x1 - x0)
    return y + 4 * t * (1 - t) * sag
def band(y, h, sag, x0, x1): return f"M{x0} {y} Q512 {y + sag * 2} {x1} {y} L{x1} {y + h} Q512 {y + h + sag * 2} {x0} {y + h} Z"
def edge(y, sag, x0, x1, thick):  # the light along an edge: thick in the middle, gone at the sides
    return f"M{x0} {y} Q512 {y + sag * 2} {x1} {y} Q512 {y + sag * 2 + thick * 2} {x0} {y} Z"

RAIL = dict(y=562, sag=62, x0=-60, x1=1084); RAIL_H = 96
LEDGE = dict(y=752, sag=76, x0=-80, x1=1104)
X, Y, W, H, R = 124, 178, 776, 478, 78  # the screen
k = R * .4477
foot, mid = rail_y(X, **RAIL) + 46, rail_y(512, **RAIL) + 46
screen = (f"M{X} {foot:.1f} L{X} {Y + R} C{X} {Y + k:.1f} {X + k:.1f} {Y} {X + R} {Y} L{X + W - R} {Y} C{X + W - k:.1f} {Y} {X + W} {Y + k:.1f} {X + W} {Y + R} "
          f"L{X + W} {foot:.1f} Q512 {2 * mid - foot:.1f} {X} {foot:.1f} Z")
rail, ledge = band(h=RAIL_H, **RAIL), band(h=460, **LEDGE)
full = "M0 0 H1024 V1024 H0 Z"
EDGE = lin(0, 0, 1024, 0, [(0, "#6A52C8", .2), (.24, "#9F86F5", 1), (.48, "#EE8CA0", 1), (.66, "#FFCF9C", 1), (.8, "#FFB27A", 1), (1, "#C9683F", .2)])
def warm(y, a, r=380): return rad(690, y, r, [(0, "#FBA76C", a), (1, "#F49C63", 0)], .3)
def cool(y, a): return rad(300, y, 320, [(0, "#8468FA", a), (1, "#8B74F5", 0)], .3)

# Back to front: name, [(path, gradient)].
LAYERS = [
    ("spill", [(full, rad(720, 400, 480, [(0, "#F6915A", .8), (.45, "#B05238", .46), (.8, "#5E2A24", .12), (1, "#5E2A24", 0)], .9)),
               (full, rad(280, 360, 430, [(0, "#8468FA", .7), (.5, "#553AA8", .3), (1, "#553AA8", 0)], .95))]),
    ("screen", [(screen, lin(X, Y + 20, X + W, Y + H * .8, [(0, "#8468FA", 1), (.28, "#B35CB4", 1), (.56, "#EE6B52", 1), (.82, "#FF9A5A", 1), (1, "#FFC27A", 1)])),
                (screen, rad(668, 612, 320, [(0, "#FFF0CF", 1), (.22, "#FFE0A8", .85), (.55, "#FFB877", .38), (1, "#FFB877", 0)], .86))]),
    ("rail", [(rail, lin(0, RAIL["y"], 0, RAIL["y"] + RAIL_H + RAIL["sag"], [(0, "#46414A", 1), (1, "#17181B", 1)]))]),
    ("rail-light", [(rail, warm(RAIL["y"] + 50, .8)), (rail, cool(RAIL["y"] + 46, .65))]),
    ("rail-edge", [(edge(thick=17, **RAIL), EDGE)]),
    ("ledge", [(ledge, lin(0, LEDGE["y"], 0, 1010, [(0, "#36333A", 1), (1, "#0C0D0F", 1)]))]),
    ("ledge-light", [(ledge, warm(LEDGE["y"] + 62, .42, 370)), (ledge, cool(LEDGE["y"] + 62, .42))]),
    ("ledge-edge", [(edge(thick=13, **LEDGE), EDGE)]),
]

def drawing(name, parts, prefix=""):
    ids = [f"{prefix}{name}-{n}" for n in range(len(parts))]
    return ("".join(g % i for (_, g), i in zip(parts, ids)), "".join(f'<path d="{p}" fill="url(#{i})"/>' for (p, _), i in zip(parts, ids)))
def svg(defs, body): return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>{defs}</defs>{body}</svg>\n'

shutil.rmtree(icon, ignore_errors=True)
(icon / "Assets").mkdir(parents=True)
for name, parts in LAYERS: (icon / "Assets" / f"{name}.svg").write_text(svg(*drawing(name, parts)))

def L(name, glass=True, **extra): return {"image-name": f"{name}.svg", "name": name, **({} if glass else {"glass": False}), **extra}
def G(name, layers, shadow, translucency=None, **extra):
    return {"name": name, "layers": layers, "shadow": {"kind": shadow[0], "opacity": shadow[1]},
            "translucency": {"enabled": translucency is not None, "value": translucency or 0}, **extra}
# One flat white screen in the tinted and clear styles, where its colours would go muddy.
TINTED = {"fill-specializations": [{"appearance": "tinted", "value": {
    "linear-gradient": ["extended-gray:0.62000,1.00000", "extended-gray:1.00000,1.00000"],
    "orientation": {"start": {"x": 0, "y": 0}, "stop": {"x": 1, "y": 1}}}}]}
# Four groups, front to back (Icon Composer's maximum). The rail is frosted glass that bends the screen's
# light; the light layers themselves are plain.
(icon / "icon.json").write_text(json.dumps({
    "features": ["refractivity"],
    "fill": {"linear-gradient": ["display-p3:0.12500,0.13000,0.14800,1.00000", "display-p3:0.04700,0.05100,0.05800,1.00000"]},
    "groups": [
        G("ledge", [L("ledge-edge", False, opacity=.85), L("ledge-light", False), L("ledge")], ("neutral", .9), .08),
        G("rail", [L("rail-edge", False), L("rail-light", False), L("rail")], ("neutral", .9), .45,
          **{"blur-material": .5, "refractivity": {"depth": .4, "enabled": True, "strength": .5}}),
        G("screen", [L("screen", **TINTED)], ("neutral", .35)),
        G("light", [L("spill", False)], ("none", 0)),
    ],
    "supported-platforms": {"squares": "shared"},
}, indent=2) + "\n")

master.parent.mkdir(parents=True, exist_ok=True)
all_defs, body = "", '<rect id="graphite" width="1024" height="1024" fill="#16181B"/>'
for name, parts in LAYERS:
    d, b = drawing(name, parts)
    all_defs += d; body += f'<g id="{name}">{b}</g>'
master.write_text(svg(all_defs, body))
