#!/usr/bin/env python3
"""Pulls one version's notes out of CHANGELOG.md.

release-notes.py <version>            -> the Markdown lines (bullets) for that version
release-notes.py <version> --html     -> the same as an HTML fragment for Sparkle's update window
Exits 1 if CHANGELOG.md has no "## <version>" section.
"""
import html, re, sys
from pathlib import Path

version, as_html = sys.argv[1], "--html" in sys.argv
text = (Path(__file__).resolve().parent.parent / "CHANGELOG.md").read_text()
match = re.search(rf"^## {re.escape(version)}\b[^\n]*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
if not match or not match.group(1).strip():
    sys.exit(f"CHANGELOG.md has no notes for {version}")
body = match.group(1).strip()
if not as_html:
    print(body)
    sys.exit(0)

def inline(s):
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)

out, in_list = [], False
for line in body.splitlines():
    if line.startswith("- "):
        if not in_list:
            out.append("<ul>"); in_list = True
        out.append(f"<li>{inline(line[2:].strip())}</li>")
    elif line.startswith("  ") and in_list and out:
        out[-1] = out[-1][:-5] + " " + inline(line.strip()) + "</li>"
    else:
        if in_list:
            out.append("</ul>"); in_list = False
        if line.startswith("### "):
            out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.strip():
            out.append(f"<p>{inline(line.strip())}</p>")
if in_list:
    out.append("</ul>")
print("\n".join(out))
