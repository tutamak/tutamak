# The disk image's layout, as dmgbuild's settings file (Python). `make release` runs it with
# `-D app=<path to Tutamak.app>`.
#
# One job, nothing else in the window: Tutamak beside a link to Applications, to be dragged onto
# it. No background image: Finder draws the icon names black in light mode and white in dark mode
# whatever is behind them, and its own window color is the one both always read on.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects it)

# Compressed (lzfse) and read-only. HFS+ keeps Finder's icon layout and is understood everywhere.
format = "ULFO"
filesystem = "HFS+"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}
# The volume's icon in Finder is the app's.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 160), (560, 320))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (150, 140),
    "Applications": (410, 140),
}
