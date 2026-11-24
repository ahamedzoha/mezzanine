#!/usr/bin/env python3
"""Fetches the demo library from Blender (download.blender.org and studio.blender.org, the films' own
makers) into build.noindex/demo: one film that plays, one picture per title. Licences are in
library.json and every picture that shows a title credits it. Files already here are kept.
Then: swift Scripts/demo/art.swift (posters and colours).
"""
import json, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path

HOSTS = {"download.blender.org", "studio.blender.org"}
here = Path(__file__).resolve().parent
out = here.parent.parent / "build.noindex" / "demo"

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, url):
        if urllib.parse.urlsplit(url).hostname not in HOSTS: sys.exit(f"Redirected to {url}")
        return super().redirect_request(req, fp, code, msg, headers, url)
opener = urllib.request.build_opener(NoRedirect)

def save(url, path):
    if urllib.parse.urlsplit(url).hostname not in HOSTS: sys.exit(f"Unexpected host: {url}")
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    with opener.open(urllib.request.Request(url, headers={"User-Agent": "mezzanine-demo-library/1.0"}), timeout=60) as r, open(part, "wb") as f:
        while chunk := r.read(1 << 20): f.write(chunk)
    part.rename(path)
    print(f"{path.relative_to(out)} {path.stat().st_size / 1e6:.1f} MB", flush=True)

titles = json.loads((here / "library.json").read_text())["titles"]
for t in titles:
    if url := t.get("picture"):
        raw = out / "art" / "raw" / (t["id"] + Path(urllib.parse.urlsplit(url).path).suffix)
        if not raw.exists(): save(url, raw); time.sleep(1)
        art = out / "art" / f"{t['id']}-art.jpg"
        if not art.exists():
            subprocess.run(["ffmpeg", "-v", "error", "-i", raw, "-vf", "scale='min(2560,iw)':-2", "-frames:v", "1", "-q:v", "2", art], check=True)
for t in titles:
    if (url := t.get("film")) and not (film := out / "films" / (t["id"] + Path(url).suffix)).exists(): save(url, film)
print("done")
