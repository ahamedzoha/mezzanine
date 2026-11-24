#!/usr/bin/env python3
"""Builds the website (site/ → build.noindex/site) for GitHub Pages.

    Scripts/site.py [--out DIR] [--offline]

Fills {{…}} in site/*.html: the released version, its DMG and size (from this repository's latest
GitHub release), the changelog up to that version, the film credits (Scripts/demo/library.json) and
the donation link, which appears only when site/config.json says the Sponsors page is live.
--offline uses the newest dated CHANGELOG section instead of asking GitHub (local previews).
"""
import argparse, html, json, os, re, shutil, subprocess, sys, urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent.parent
site = root / "site"
REPO = os.environ.get("GITHUB_REPOSITORY", "ahamedzoha/mezzanine")
args = argparse.ArgumentParser()
args.add_argument("--out", default=str(root / "build.noindex" / "site"))
args.add_argument("--offline", action="store_true")
args = args.parse_args()
out = Path(args.out)
config = json.loads((site / "config.json").read_text())

changelog = [(m[1], m[2]) for m in re.finditer(r"^## (\d+\.\d+\.\d+) — (\d{4}-\d{2}-\d{2})$", (root / "CHANGELOG.md").read_text(), re.M)]

def release():
    if args.offline:
        v, day = changelog[0]
        return v, f"https://github.com/{REPO}/releases/tag/v{v}", None, day
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases/latest", headers={"Accept": "application/vnd.github+json"})
    if t := os.environ.get("GITHUB_TOKEN"): req.add_header("Authorization", f"Bearer {t}")
    r = json.load(urllib.request.urlopen(req, timeout=30))
    dmg = next(a for a in r["assets"] if a["name"].endswith(".dmg"))
    return r["tag_name"].removeprefix("v"), dmg["browser_download_url"], dmg["size"], r["published_at"][:10]

version, dmg, size, day = release()

def number(v): return tuple(int(x) for x in v.split("."))

def notes(v):
    return subprocess.run([sys.executable, root / "Scripts" / "release-notes.py", v, "--html"], capture_output=True, text=True, check=True).stdout.strip()

def long_day(d):
    y, m, n = d.split("-")
    return f"{int(n)} {'January February March April May June July August September October November December'.split()[int(m) - 1]} {y}"

versions = "\n".join(
    f'<section class="version" id="v{v}"><h2>{v}</h2><p class="caption"><time datetime="{d}">{long_day(d)}</time></p>\n{notes(v)}\n</section>'
    for v, d in changelog if number(v) <= number(version))

LICENCES = {"CC BY 2.5": "https://creativecommons.org/licenses/by/2.5/", "CC BY 3.0": "https://creativecommons.org/licenses/by/3.0/",
            "CC BY 4.0": "https://creativecommons.org/licenses/by/4.0/", "CC BY-SA 3.0": "https://creativecommons.org/licenses/by-sa/3.0/"}
rows = []
for t in json.loads((root / "Scripts" / "demo" / "library.json").read_text())["titles"]:
    if t["type"] == "show": continue
    s = t["source"]
    name = f"Caminandes: {t['title']}" if t["type"] == "episode" else t["title"]
    rows.append(f'<li><cite><a href="{s["page"]}">{html.escape(name)}</a></cite> ({t["year"]}) © {html.escape(s["by"])}, '
                f'<a href="{LICENCES[s["licence"]]}">{s["licence"]}</a></li>')

fill = {
    "version": version, "download": dmg, "released": long_day(day), "released_iso": day,
    "size": f"{size / 1e6:.0f} MB" if size else "DMG", "versions": versions, "credits": "\n".join(rows),
    "base": config["base"], "sponsor": f'<a class="quiet" href="{html.escape(config["sponsorURL"])}">Support</a>' if config["sponsors"] else "",
    "sponsor_block": config["sponsorBlock"].replace("{url}", html.escape(config["sponsorURL"])) if config["sponsors"] else "",
}

if out.exists(): shutil.rmtree(out)
shutil.copytree(site, out, ignore=shutil.ignore_patterns("config.json", ".DS_Store"))
for page in out.rglob("*.html"):
    text = page.read_text()
    text = re.sub(r"\{\{(\w+)\}\}", lambda m: str(fill[m[1]]), text)
    page.write_text(text)
(out / "sitemap.xml").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    + "".join(f"<url><loc>{config['base']}{p}</loc><lastmod>{day}</lastmod></url>" for p in ("", "changelog.html")) + "</urlset>\n")
left = [p for p in out.rglob("*.html") if "{{" in p.read_text()]
if left: sys.exit(f"Unfilled placeholders in {left}")
print(f"Built {out} for {version} ({fill['size']})")
