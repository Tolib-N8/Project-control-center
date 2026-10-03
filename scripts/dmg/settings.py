# dmgbuild settings for Orbit's installer image.
#   dmgbuild -s scripts/dmg/settings.py -D app=/path/Orbit.app -D icon=/path/Orbit.icns \
#            -D background=scripts/dmg/background.tiff "Orbit 0.6.0" Orbit-0.6.0.dmg
# Icon positions are in points from the window's top-left and must match make-background.swift.
import os

app = defines["app"]  # noqa: F821 — provided by dmgbuild
app_name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app]
symlinks = {"Программы": "/Applications"}
icon = defines.get("icon")  # noqa: F821 — volume icon

background = defines["background"]  # noqa: F821 — dmgbuild runs this file without __file__
# 400 pt of background plus Finder's title bar and the status bar it insists on showing.
window_rect = ((200, 160), (640, 456))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    app_name: (170, 180),
    "Программы": (470, 180),
}
