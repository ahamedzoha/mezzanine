# dmgbuild settings for Mezzanine's installer window (dmgbuild -s settings.py -D app=… -D background=…).
# Layout matches Scripts/dmg/make-background.swift: app at (170, 220), Applications at (470, 220).
import os.path

app = defines["app"]
format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
hide_extension = [os.path.basename(app)]

background = defines["background"]
# Origin is from the bottom of the screen; the height leaves room for Finder's tab and path bars.
window_rect = ((240, 420), (640, 470))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 220),
    "Applications": (470, 220),
}
