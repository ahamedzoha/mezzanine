#!/usr/bin/env python3
"""A stand-in Plex server for pictures of the app: open films on 127.0.0.1, invented progress.

    Scripts/demo/server.py [port]        (32499; media from build.noindex/demo, see fetch.py)
    Mezzanine (Debug) … -DemoServer http://127.0.0.1:32499

It answers what PlexServerClient and PlexDiscover read. Writes are answered and dropped.
"""
import json, re, subprocess, sys, time
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

here = Path(__file__).resolve().parent
media = here.parent.parent / "build.noindex" / "demo"
library = json.loads((here / "library.json").read_text())
state = library["state"]
titles = {t["id"]: t for t in library["titles"]}
colours = json.loads((media / "art" / "colours.json").read_text()) if (media / "art" / "colours.json").exists() else {}
MACHINE = "d3m0" * 10
NOW = int(time.time())
DAY = 86400
key = {id: 101 + n for n, id in enumerate(titles)}
SEASON = 190
by_key = {v: k for k, v in key.items()}
offsets = dict((id, s) for id, s in state["continue"])
order = [id for id, _ in state["continue"]]

def film(id): return next((media / "films").glob(f"{id}.m??"), None)

@lru_cache(None)
def probe(id):
    f = film(id)
    if not f: return None
    return json.loads(subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json", "-show_streams", "-show_format", f],
                                     capture_output=True, text=True).stdout)

LANGS = {"eng": "English", "ger": "German", "deu": "German", "spa": "Spanish", "fre": "French", "fra": "French", "ita": "Italian", "dut": "Dutch", "nld": "Dutch",
         "pol": "Polish", "por": "Portuguese", "rus": "Russian", "vie": "Vietnamese"}
def stream_rows(id, k):
    p = probe(id)
    streams = p["streams"] if p else [{"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 818, "index": 0},
                                      {"codec_type": "audio", "codec_name": "aac", "channels": 2, "index": 1, "tags": {"language": "eng"}}]
    rows, seen = [], set()
    for n, s in enumerate(streams):
        kind = {"video": 1, "audio": 2, "subtitle": 3}.get(s["codec_type"])
        if not kind or s.get("disposition", {}).get("attached_pic"): continue
        code = s.get("tags", {}).get("language", "eng"); lang = LANGS.get(code, code)
        codec = {"subrip": "srt", "hdmv_pgs_subtitle": "pgs"}.get(s["codec_name"], s["codec_name"])
        row = {"id": k * 100 + n, "streamType": kind, "codec": codec, "index": s["index"], "default": kind not in seen and kind < 3}
        if kind == 1: row.update(width=s["width"], height=s["height"], bitDepth=8, frameRate=24, displayTitle="1080p", extendedDisplayTitle=f"1080p ({codec.upper()})")
        if kind == 2:
            ch = int(s.get("channels", 2)); layout = {6: "5.1", 2: "Stereo"}.get(ch, str(ch))
            row.update(channels=ch, language=lang, languageCode=code, languageTag=code[:2], selected=kind not in seen,
                       displayTitle=f"{lang} ({codec.upper()} {layout})", extendedDisplayTitle=f"{lang} ({codec.upper()} {layout})")
        if kind == 3: row.update(language=lang, languageCode=code, languageTag=code[:2], displayTitle=f"{lang} ({codec.upper()})", extendedDisplayTitle=f"{lang} ({codec.upper()})")
        seen.add(kind); rows.append(row)
    v, a = next(r for r in rows if r["streamType"] == 1), next(r for r in rows if r["streamType"] == 2)
    return v["width"], v["height"], v["codec"], a["codec"], a["channels"], rows

def meta(id, full=False):
    t, k = titles[id], key[id]
    stamp = NOW - 30 * DAY
    n = list(titles).index(id)
    out = {"ratingKey": str(k), "key": f"/library/metadata/{k}", "guid": f"plex://{t['type']}/d3m0{k:020d}", "type": t["type"],
           "title": t["title"], "summary": t.get("summary", ""), "year": t["year"], **({"originallyAvailableAt": t["date"]} if "date" in t else {}),
           "thumb": f"/library/metadata/{k}/thumb/{stamp}", "art": f"/library/metadata/{k}/art/{stamp}",
           "addedAt": NOW - (state["new"].index(id) + 1) * 80000 if id in state["new"] else NOW - (40 + n) * DAY, "updatedAt": stamp}
    if c := colours.get(id): out["UltraBlurColors"] = c
    tags = lambda xs: [{"tag": x} for x in xs]
    if t.get("studio"): out["studio"] = t["studio"]
    out["Genre"] = tags(t.get("genres", []))
    if t.get("director"): out["Director"] = [{"id": 9000 + n, "tag": t["director"]}]
    out["Role"] = [{"id": 9100 + n * 10 + i, "tag": a, "role": r} for i, (a, r) in enumerate(t.get("cast", []))]
    out["Collection"] = tags(c[1] for c in state["collections"] if id in c[2])
    section = "1" if t["type"] == "movie" else "2"
    out.update(librarySectionID=int(section), librarySectionTitle={"1": "Films", "2": "Shows"}[section], librarySectionKey=f"/library/sections/{section}")
    if t["type"] == "show":
        eps = episodes(id)
        out.update(key=f"/library/metadata/{k}/children", leafCount=len(eps), childCount=1,
                   viewedLeafCount=sum(e in state["watched"] for e in eps), duration=130000)
        return out
    if id in state["watched"]: out.update(viewCount=1, lastViewedAt=NOW - (3 + n) * DAY)
    if id in offsets: out.update(viewOffset=offsets[id] * 1000, lastViewedAt=NOW - 3600 * (1 + order.index(id) * 20))
    w, h, vc, ac, ch, rows = stream_rows(id, k)
    p = probe(id)
    duration = int(float(p["format"]["duration"]) * 1000) if p else t["duration"] * 1000
    size = film(id).stat().st_size if p else 90_000_000
    box = film(id).suffix[1:] if p else "mkv"
    out["duration"] = duration
    out["Media"] = [{"id": k, "duration": duration, "bitrate": int(size * 8 / duration), "width": w, "height": h, "aspectRatio": round(w / h, 2),
                     "audioChannels": ch, "audioCodec": ac, "videoCodec": vc, "videoResolution": "1080", "container": box, "videoFrameRate": "24p",
                     "Part": [{"id": k, "key": f"/library/parts/{k}/{stamp}/file.{box}", "duration": duration, "file": f"/films/{t['title']}.{box}",
                               "size": size, "container": box, **({"Stream": rows} if full else {})}]}]
    if t["type"] == "episode":
        s, sk = titles[t["show"]], key[t["show"]]
        out.update(index=t["index"], parentIndex=1, parentRatingKey=str(SEASON), grandparentRatingKey=str(sk), parentKey=f"/library/metadata/{SEASON}",
                   grandparentKey=f"/library/metadata/{sk}", parentTitle="Season 1", grandparentTitle=s["title"],
                   grandparentThumb=f"/library/metadata/{sk}/thumb/{stamp}", parentThumb=f"/library/metadata/{sk}/thumb/{stamp}",
                   grandparentArt=f"/library/metadata/{sk}/art/{stamp}", art=f"/library/metadata/{sk}/art/{stamp}")
    if full:
        marks = []
        if t.get("intro"): marks.append({"id": k * 10 + 5, "type": "intro", "startTimeOffset": t["intro"][0] * 1000, "endTimeOffset": t["intro"][1] * 1000})
        if t.get("credits"): marks.append({"id": k * 10 + 6, "type": "credits", "startTimeOffset": t["credits"] * 1000, "endTimeOffset": duration, "final": True})
        out["Marker"] = marks
    return out

def episodes(show): return [i for i, t in titles.items() if t.get("show") == show]

def season():
    s = titles["caminandes"]; k = key["caminandes"]; eps = episodes("caminandes")
    return {"ratingKey": str(SEASON), "key": f"/library/metadata/{SEASON}/children", "guid": f"plex://season/d3m0{SEASON:020d}", "type": "season",
            "title": "Season 1", "index": 1, "parentIndex": 1, "parentRatingKey": str(k), "parentKey": f"/library/metadata/{k}", "parentTitle": s["title"],
            "thumb": f"/library/metadata/{k}/thumb/1", "art": f"/library/metadata/{k}/art/1", "leafCount": len(eps), "summary": s["summary"],
            "viewedLeafCount": sum(e in state["watched"] for e in eps), "addedAt": NOW - 60 * DAY, "updatedAt": NOW - 30 * DAY,
            "librarySectionID": 2, "librarySectionTitle": "Shows", "librarySectionKey": "/library/sections/2"}

def of(*types): return [i for i, t in titles.items() if t["type"] in types]
def hub(id, title, ids, kind="mixed"):
    return {"hubIdentifier": id, "key": f"/hubs/{id}", "title": title, "type": kind, "size": len(ids), "more": False, "promoted": True,
            "Metadata": [meta(i) for i in ids]}
def newest(*types): return sorted(of(*types), key=lambda i: -meta(i)["addedAt"])
def collection(n):
    s, title, ids = state["collections"][n]
    return {"ratingKey": str(300 + n), "key": f"/library/collections/{300 + n}/children", "guid": f"collection://d3m0-{n}", "type": "collection",
            "subtype": "movie", "title": title, "summary": "", "childCount": len(ids), "thumb": f"/library/metadata/{key[ids[0]]}/thumb/1",
            "art": f"/library/metadata/{key[ids[0]]}/art/1", "addedAt": NOW - 50 * DAY, "updatedAt": NOW - 30 * DAY,
            "librarySectionID": int(s), "librarySectionTitle": "Films"}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): print("DEMO", self.command, urlsplit(self.path).path, flush=True) if "-v" in sys.argv else None
    def send(self, body, kind="application/json", status=200, extra=()):
        self.send_response(status); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body)))
        for k, v in extra: self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def box(self, rows=None, name="Metadata", **extra):
        c = {"size": len(rows or []), **extra}
        if rows is not None: c[name] = rows
        self.send(json.dumps({"MediaContainer": c}).encode())
    def page(self, rows):
        q = parse_qs(urlsplit(self.path).query)
        start = int(self.headers.get("X-Plex-Container-Start") or q.get("X-Plex-Container-Start", ["0"])[0])
        size = int(self.headers.get("X-Plex-Container-Size") or q.get("X-Plex-Container-Size", ["500"])[0])
        self.box(rows[start:start + size], totalSize=len(rows), offset=start)
    def file(self, path, kind):
        if not path.exists(): return self.send(b"", status=404)
        size, start, end, status = path.stat().st_size, 0, path.stat().st_size - 1, 200
        if m := re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", "")):
            start, end, status = int(m[1]), min(int(m[2] or size - 1), size - 1), 206
        if start >= size: return self.send(b"", status=416)
        self.send_response(status)
        for k, v in [("Content-Type", kind), ("Content-Length", str(end - start + 1)), ("Accept-Ranges", "bytes")]: self.send_header(k, v)
        if status == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD": return
        with open(path, "rb") as f:
            f.seek(start); left = end - start + 1
            try:
                while left > 0 and (b := f.read(min(1 << 18, left))): self.wfile.write(b); left -= len(b)
            except (BrokenPipeError, ConnectionResetError): self.close_connection = True
    def picture(self, path):
        m = re.search(r"/library/metadata/(\d+)/(thumb|art)", unquote(path))
        if not m: return self.send(b"", status=404)
        k, what = int(m[1]), m[2]
        id = "caminandes" if k == SEASON else by_key.get(k)
        if not id: return self.send(b"", status=404)
        wide = titles[id]["type"] == "episode" or what == "art"
        if wide: id = titles[id].get("artOf", id)
        self.file(media / "art" / f"{id}-{'art' if wide else 'poster'}.jpg", "image/jpeg")
    def write_dropped(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        self.box()
    do_PUT = do_POST = do_DELETE = write_dropped
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        u = urlsplit(self.path); p, q = u.path, parse_qs(u.query)
        if p == "/identity": return self.box(machineIdentifier=MACHINE, version="1.43.5", claimed=True)
        if p in ("/:/timeline", "/:/scrobble", "/:/unscrobble", "/:/progress"): return self.box()
        if p == "/library/sections/watchlist/all": return self.page([meta(i) for i in state["watchlist"]])
        if p == "/library/sections":
            return self.box([{"key": k, "type": ty, "title": ti, "agent": f"tv.plex.agents.{ty}", "scanner": "Plex", "language": "en-US",
                              "uuid": f"d3m0-{k}", "updatedAt": NOW, "createdAt": NOW - 90 * DAY, "scannedAt": NOW, "content": True, "directory": True, "hidden": 0}
                             for k, ty, ti in [("1", "movie", "Films"), ("2", "show", "Shows")]], "Directory", title1="Plex Library")
        if m := re.fullmatch(r"/library/sections/(\d+)/all", p):
            kind = {"1": "movie", "2": "show", "3": "season", "4": "episode"}.get(q.get("type", [""])[0], "movie" if m[1] == "1" else "show")
            rows = [season()] if kind == "season" else [meta(i) for i in of(kind)]
            if (kind == "movie") != (m[1] == "1"): rows = []
            since = int(next((v[0] for k, v in q.items() if k.startswith("updatedAt")), "0") or 0)
            return self.page([r for r in rows if r["updatedAt"] > since])
        if m := re.fullmatch(r"/library/sections/(\d+)/collections", p):
            return self.page([collection(n) for n, c in enumerate(state["collections"]) if c[0] == m[1]])
        if m := re.fullmatch(r"/library/collections/(\d+)/children", p): return self.page([meta(i) for i in state["collections"][int(m[1]) - 300][2]])
        if m := re.fullmatch(r"/library/metadata/([\d,]+)", p):
            ks = [int(x) for x in m[1].split(",")]
            return self.box([season() if k == SEASON else collection(k - 300) if 300 <= k < 400 else meta(by_key[k], full=True) for k in ks if k in by_key or k == SEASON or 300 <= k < 300 + len(state["collections"])])
        if m := re.fullmatch(r"/library/metadata/(\d+)/(children|allLeaves)", p):
            k = int(m[1])
            if m[2] == "children" and by_key.get(k) == "caminandes": return self.page([season()])
            return self.page([meta(i) for i in episodes("caminandes")])
        if m := re.fullmatch(r"/library/metadata/(\d+)/related", p):
            id = by_key.get(int(m[1])); mates = [c for c in state["collections"] if id in c[2]]
            like = [i for i in of("movie") if i != id and set(titles[i]["genres"]) & set(titles.get(id, {}).get("genres", []))][:10]
            return self.box([hub(f"related.{n}", c[1], [i for i in c[2] if i != id], "movie") for n, c in enumerate(mates)] + [hub("similar", "More Like This", like, "movie")], "Hub")
        if p == "/hubs/continueWatching/items": return self.page([meta(i) for i in order])
        if p == "/hubs": return self.box([hub("home.continue", "Continue Watching", order), hub("home.movies.recent", "Recently Added Films", newest("movie"), "movie"),
                                          hub("home.television.recent", "Recently Added Shows", of("show"), "show")], "Hub")
        if p.startswith("/hubs/sections/"):
            ids = newest("movie") if p.endswith("/1") else of("show")
            return self.box([hub(f"recent.{p[-1]}", "Recently Added", ids)], "Hub")
        if p == "/hubs/search":
            s = q.get("query", [""])[0].lower()
            return self.box([hub("movie", "Films", [i for i in of("movie") if s in titles[i]["title"].lower()], "movie"),
                             hub("show", "Shows", [i for i in of("show") if s in titles[i]["title"].lower()], "show")], "Hub")
        if p == "/photo/:/transcode": return self.picture(q.get("url", [""])[0])
        if re.fullmatch(r"/library/metadata/\d+/(thumb|art)(/\d+)?", p): return self.picture(p)
        if m := re.fullmatch(r"/library/parts/(\d+)/\d+/file\.\w+", p):
            f = film(by_key.get(int(m[1]), "-"))
            return self.file(f, "video/x-matroska") if f else self.send(b"", status=404)
        if p == "/playlists": return self.page([])
        self.send(b'{"MediaContainer":{"size":0}}', status=200 if p.startswith("/hubs") or p.endswith(("/posters", "/arts")) else 404)

if __name__ == "__main__":
    port = next((int(a) for a in sys.argv[1:] if a.isdigit()), 32499)
    print(f"Demo server on http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
