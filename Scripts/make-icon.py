#!/usr/bin/env python3
# Generates Mezzanine/AppIcon.icon: three stacked glass slabs and a standing play triangle,
# amber light between the layers. Every shape is computed here as filled SVG paths.
# Run from anywhere: python3 Scripts/make-icon.py
import math, json, os
S = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(S, "..", "Mezzanine", "AppIcon.icon"); A = os.path.join(OUT, "Assets")
os.makedirs(A, exist_ok=True)
CX, BASEY = 512, 694
KX, KY = 0.866, 0.5

def proj(u, v, z): return (CX + (u - v) * KX, BASEY + (u + v) * KY - z)

def rsq(s, r, n=20):
    """rounded square in the ground plane, half-size s, corner radius r"""
    pts = []
    for (cx, cy, a0) in [(s - r, s - r, 0), (-(s - r), s - r, 90), (-(s - r), -(s - r), 180), (s - r, -(s - r), 270)]:
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def hull(P):
    P = sorted(set((round(x, 3), round(y, 3)) for x, y in P))
    def cr(o, a, b): return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lo = []
    for p in P:
        while len(lo) >= 2 and cr(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    up = []
    for p in reversed(P):
        while len(up) >= 2 and cr(up[-2], up[-1], p) <= 0: up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]

def path(P): return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in P) + " Z"

def face(s, r, z): return [proj(u, v, z) for u, v in rsq(s, r)]
def slab_side(s, r, z0, z1): return hull(face(s, r, z0) + face(s, r, z1))

def round_poly(V, r, n=14):
    """round the corners of a convex polygon (screen space)"""
    out = []; N = len(V)
    for i in range(N):
        p0, p1, p2 = V[i - 1], V[i], V[(i + 1) % N]
        def unit(a, b):
            d = math.hypot(b[0]-a[0], b[1]-a[1]); return ((b[0]-a[0])/d, (b[1]-a[1])/d)
        d1, d2 = unit(p1, p0), unit(p1, p2)
        ang = math.acos(max(-1, min(1, d1[0]*d2[0] + d1[1]*d2[1])))
        t = r / math.tan(ang / 2)
        a = (p1[0] + d1[0]*t, p1[1] + d1[1]*t); b = (p1[0] + d2[0]*t, p1[1] + d2[1]*t)
        for k in range(n + 1):  # quadratic bezier through corner
            q = k / n
            x = (1-q)**2*a[0] + 2*(1-q)*q*p1[0] + q*q*b[0]
            y = (1-q)**2*a[1] + 2*(1-q)*q*p1[1] + q*q*b[1]
            out.append((x, y))
    return out

def svg(name, body, defs=""):
    with open(os.path.join(A, name), "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n<defs>\n{defs}</defs>\n{body}\n</svg>\n')

def lin(id, x1, y1, x2, y2, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<linearGradient id="{id}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>\n'
def rad(id, cx, cy, r, stops, sy=1.0):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    gt = f' gradientTransform="translate({cx} {cy}) scale(1 {sy}) translate({-cx} {-cy})"' if sy != 1 else ""
    return f'<radialGradient id="{id}" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{r}"{gt}>{s}</radialGradient>\n'

AMB, AMB2, HOT = "#FFA63D", "#FF8A2A", "#FFE2A8"
IND, IND2, VIO = "#1B1450", "#2B1F7A", "#5B3FD6"

# ---- tiers: (half-size, radius, z0, z1)
T1 = (192, 56, 0, 72)      # bottom, thick, dark
T2 = (176, 52, 104, 142)    # middle
T3 = (164, 48, 172, 190)   # top plate, thin
def cyz(z): return BASEY - z

# ---------- bottom slab
s, r, z0, z1 = T1
defs = lin("side", 180, 0, 844, 0, [(0, "#3A2A9A", 1), (0.42, "#2A1C78", 1), (0.5, "#6A3CC0", 1), (0.56, "#231766", 1), (1, "#140E3E", 1)])
defs += lin("sideV", 0, cyz(z1), 0, cyz(z0) + s, [(0, "#000", 0), (1, "#0A0626", 0.55)])
svg("base-side.svg", f'<path d="{path(slab_side(s, r, z0, z1))}" fill="url(#side)"/><path d="{path(slab_side(s, r, z0, z1))}" fill="url(#sideV)"/>', defs)
defs = rad("top", CX, cyz(z1) + 20, 300, [(0, HOT, 1), (0.34, AMB, 1), (0.6, "#F08A3C", 0.95), (0.82, "#8468E6", 0.95), (1, "#B9AEF2", 0.95)], sy=0.577)
svg("base-top.svg", f'<path d="{path(face(s, r, z1))}" fill="url(#top)"/>', defs)
# soft ground shadow / violet pool (non-glass)
defs = rad("sh", CX, BASEY + 50, 410, [(0, "#1A0F5C", 0.8), (0.6, "#3A2AA0", 0.3), (1, "#3A2AA0", 0)], sy=0.56)
defs += rad("warm", CX, BASEY + 150, 230, [(0, AMB2, 0.42), (1, AMB2, 0)], sy=0.45)
svg("ground.svg", '<rect width="1024" height="1024" fill="url(#sh)"/><rect width="1024" height="1024" fill="url(#warm)"/>', defs)

# ---------- middle slab
s, r, z0, z1 = T2
defs = lin("side", 200, 0, 824, 0, [(0, "#7C63EA", 1), (0.38, "#5A3FCC", 1), (0.5, "#F0923A", 1), (0.6, "#4A30B4", 1), (1, "#2C1F86", 1)])
svg("mid-side.svg", f'<path d="{path(slab_side(s, r, z0, z1))}" fill="url(#side)"/>', defs)
defs = rad("top", CX, cyz(z1) + 10, 280, [(0, HOT, 1), (0.4, AMB, 0.96), (0.72, "#C69BE0", 0.9), (1, "#D9D2F8", 0.92)], sy=0.577)
svg("mid-top.svg", f'<path d="{path(face(s, r, z1))}" fill="url(#top)"/>', defs)
# amber light spilling from the gap below the middle slab (non-glass)
defs = rad("g", CX, cyz(86), 250, [(0, HOT, 0.9), (0.5, AMB, 0.5), (1, AMB2, 0)], sy=0.5)
svg("mid-glow.svg", '<rect width="1024" height="1024" fill="url(#g)"/>', defs)

# ---------- top plate
s, r, z0, z1 = T3
defs = lin("side", 228, 0, 796, 0, [(0, "#CFC4F8", 1), (0.34, "#F5B66A", 1), (0.5, "#FFF1D2", 1), (0.68, AMB, 1), (1, "#8A6EE6", 1)])
svg("plate-side.svg", f'<path d="{path(slab_side(s, r, z0, z1))}" fill="url(#side)"/>', defs)
defs = lin("top", 0, cyz(z1) - s, 0, cyz(z1) + s, [(0, "#FFFFFF", 0.98), (0.6, "#EEE9FC", 0.96), (1, "#FFE4BE", 0.96)])
svg("plate-top.svg", f'<path d="{path(face(s, r, z1))}" fill="url(#top)"/>', defs)
defs = rad("g", CX, cyz(157), 215, [(0, HOT, 0.8), (0.5, AMB, 0.4), (1, AMB2, 0)], sy=0.5)
svg("plate-glow.svg", '<rect width="1024" height="1024" fill="url(#g)"/>', defs)

# ---------- play triangle (stands on the plate; near-frontal, sheared a little)
PY = cyz(T3[3])            # plate top centre y
TX0, TX1 = 392, 800        # left edge x, apex x
TTOP, TBOT = 158, PY + 44
SH = 0.10                  # downward shear per x
def tri(inset=0, rr=38):
    mid = (TTOP + TBOT) / 2
    V = [(TX0, TTOP), (TX1, mid), (TX0, TBOT)]
    if inset:
        # shrink toward centroid-ish for the inner bevel triangle
        c = (TX0 + (TX1 - TX0) * 0.30, mid)
        V = [(c[0] + (x - c[0]) * inset, c[1] + (y - c[1]) * inset) for x, y in V]
    P = round_poly(V, rr)
    return [(x, y + (x - TX0) * SH) for x, y in P]
EX = (-30, 15)             # extrusion (thickness) toward lower-left
front = tri()
side = hull(front + [(x + EX[0], y + EX[1]) for x, y in front])
defs = lin("s", 0, TTOP, 0, TBOT + 40, [(0, "#CFC6F6", 1), (0.5, "#A998EC", 1), (0.8, AMB, 1), (1, AMB2, 1)])
svg("tri-side.svg", f'<path d="{path(side)}" fill="url(#s)"/>', defs)
defs = lin("f", TX0, TTOP, TX0 + 120, TBOT, [(0, "#FFFFFF", 0.94), (0.6, "#F3EFFC", 0.84), (1, "#FFE9C8", 0.9)])
svg("tri-front.svg", f'<path d="{path(front)}" fill="url(#f)"/>', defs)
inner = tri(inset=0.56, rr=22)
defs = lin("i", TX0, TTOP + 80, TX0 + 80, TBOT - 40, [(0, "#FFFFFF", 0.95), (0.55, "#FBF3EA", 0.9), (1, "#FFC578", 0.98)])
svg("tri-inner.svg", f'<path d="{path(inner)}" fill="url(#i)"/>', defs)
defs = rad("h", TX0 + 160, TTOP + 190, 360, [(0, "#4B3BB0", 0.30), (0.55, "#4B3BB0", 0.13), (1, "#4B3BB0", 0)])
svg("tri-haze.svg", '<rect width="1024" height="1024" fill="url(#h)"/>', defs)
# lamp at the foot of the triangle (non-glass)
defs = rad("g", TX0 + 40, TBOT - 6, 150, [(0, "#FFF3D6", 1), (0.35, AMB, 0.75), (1, AMB2, 0)], sy=0.7)
svg("lamp.svg", '<rect width="1024" height="1024" fill="url(#g)"/>', defs)

def L(img, glass=True, **kw):
    d = {"image-name": img, "name": img[:-4]}
    if not glass: d["glass"] = False
    d.update(kw); return d
def G(name, layers, shadow=("neutral", 0.5), transl=None, **kw):
    d = {"name": name, "layers": layers, "shadow": {"kind": shadow[0], "opacity": shadow[1]},
         "translucency": {"enabled": transl is not None, "value": transl or 0}}
    d.update(kw); return d

doc = {
  "fill-specializations": [
    {"value": {"linear-gradient": ["display-p3:0.875,0.870,0.915,1.00000", "display-p3:0.640,0.625,0.760,1.00000"],
               "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}},
    {"appearance": "dark", "value": {"linear-gradient": ["display-p3:0.130,0.118,0.230,1.00000", "display-p3:0.055,0.059,0.067,1.00000"],
               "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}},
  ],
  "groups": [
    G("triangle", [L("tri-inner.svg"), L("tri-front.svg"), L("tri-side.svg"), L("tri-haze.svg", glass=False)], shadow=("layer-color", 0.5), transl=0.35),
    G("plate", [L("lamp.svg", glass=False), L("plate-top.svg"), L("plate-side.svg"), L("plate-glow.svg", glass=False)], shadow=("layer-color", 0.5), transl=0.12),
    G("middle", [L("mid-top.svg"), L("mid-side.svg"), L("mid-glow.svg", glass=False)], shadow=("layer-color", 0.5)),
    G("base", [L("base-top.svg"), L("base-side.svg"), L("ground.svg", glass=False, **{"opacity-specializations": [{"value": 1}, {"appearance": "tinted", "value": 0.25}]})], shadow=("neutral", 0.6)),
  ],
  "supported-platforms": {"squares": "shared"},
}
json.dump(doc, open(os.path.join(OUT, "icon.json"), "w"), indent=2)
