#!/usr/bin/env python3
"""Plays a Plex controller against a running Mezzanine (Plex Companion check).

Scripts/companion-check.py <server machineIdentifier> [ratingKey]

Finds the player with a GDM search, reads /resources, subscribes to the timeline (a local HTTP
server on 32499 receives it), then plays the title from 10:00, pauses, seeks to 20:00, resumes,
polls and stops, and prints the timeline states it received. Run the Debug build with
-MezzanineNoActivity YES first; the server's machineIdentifier comes from
`Scripts/plex.sh pms /identity`.
"""
import socket, sys, time, threading, urllib.request, re
from http.server import BaseHTTPRequestHandler, HTTPServer

server_machine = sys.argv[1]
rating_key = sys.argv[2] if len(sys.argv) > 2 else "1508"
got = []
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        m = re.search(r'<Timeline type="video" state="(\w+)"(?:[^>]*time="(\d+)")?', body)
        cid = re.search(r'commandID="(\d+)"', body)
        got.append((round(time.time()-t0,1), m.group(1) if m else "?", int(m.group(2))//1000 if m and m.group(2) else None, cid.group(1) if cid else None))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
srv = HTTPServer(("0.0.0.0", 32499), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
t0 = time.time()

# 1. GDM search (multicast + loopback)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
msg = b"M-SEARCH * HTTP/1.1\r\n\r\n"
s.sendto(msg, ("239.0.0.250", 32412)); s.sendto(msg, ("127.0.0.1", 32412))
port = None
try:
    while True:
        data, addr = s.recvfrom(4096)
        text = data.decode()
        if "Mezzanine" in text:
            port = int(re.search(r"Port: (\d+)", text).group(1))
            print("GDM reply from", addr[0], "->", text.splitlines()[0], "| Name:", re.search(r"Name: (.*)", text).group(1).strip(), "| Port:", port)
            break
except socket.timeout:
    print("GDM: no reply"); sys.exit(1)

base = f"http://127.0.0.1:{port}"
hdr = {"X-Plex-Client-Identifier": "test-controller", "X-Plex-Device-Name": "Test Controller"}
def get(path):
    r = urllib.request.urlopen(urllib.request.Request(base + path, headers=hdr), timeout=10); return r.status, r.read().decode()
st, body = get("/resources"); print("resources", st, re.search(r'<Player [^>]*>', body).group(0)[:160])
print("subscribe", get("/player/timeline/subscribe?port=32499&protocol=http&commandID=1")[0])
time.sleep(1)
print("playMedia", get(f"/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F{rating_key}&offset=600000&machineIdentifier={server_machine}&commandID=2")[0])
time.sleep(12)
print("pause", get("/player/playback/pause?commandID=3")[0]); time.sleep(3)
print("seekTo 20:00", get("/player/playback/seekTo?offset=1200000&commandID=4")[0]); time.sleep(3)
print("play", get("/player/playback/play?commandID=5")[0]); time.sleep(4)
st, body = get("/player/timeline/poll?commandID=6"); print("poll", st, re.search(r'<Timeline type="video"[^>]*>', body).group(0)[:150])
print("stop", get("/player/playback/stop?commandID=7")[0]); time.sleep(3)
print("unsubscribe", get("/player/timeline/unsubscribe")[0])
# Summarise timelines: first, transitions, last
last = None
for t, state, secs, cid in got:
    if state != last or t == got[-1][0]:
        print(f"  timeline @{t}s state={state} time={secs}s commandID={cid}")
    last = state
print("timelines received:", len(got))
