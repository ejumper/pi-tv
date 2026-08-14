#!/usr/bin/env python3
import os
import signal

os.environ.setdefault("GDK_BACKEND", "wayland")

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")

from gi.repository import Gdk, Gtk, GtkLayerShell, GLib
import cairo

OPACITY = float(os.environ.get("DIM_OPACITY", "0.75"))
TINT = os.environ.get("DIM_TINT", "0.02,0.01,0.0")
try:
    TINT_R, TINT_G, TINT_B = (float(x.strip()) for x in TINT.split(","))
except ValueError:
    TINT_R, TINT_G, TINT_B = 0.05, 0.03, 0.0


def _quit(*_args):
    Gtk.main_quit()
    return False


def _set_pass_through(widget):
    gdk_window = widget.get_window()
    if not gdk_window:
        return
    try:
        region = cairo.Region()
        gdk_window.input_shape_combine_region(region, 0, 0)
        gdk_window.set_pass_through(True)
    except Exception:
        pass


def main():
    window = Gtk.Window()
    window.set_app_paintable(True)
    window.set_decorated(False)
    window.set_skip_taskbar_hint(True)
    window.set_skip_pager_hint(True)
    window.set_accept_focus(False)
    window.set_focus_on_map(False)
    window.set_name("screen-dimmer")

    screen = window.get_screen()
    visual = screen.get_rgba_visual() if screen else None
    if visual:
        window.set_visual(visual)

    display = Gdk.Display.get_default()
    monitor = display.get_primary_monitor() if display else None
    if monitor is None and display:
        monitor = display.get_monitor(0)
    geom_width = None
    geom_height = None
    if monitor:
        geom = monitor.get_geometry()
        geom_width = geom.width
        geom_height = geom.height
        window.set_default_size(geom_width, geom_height)

    GtkLayerShell.init_for_window(window)
    GtkLayerShell.set_layer(window, GtkLayerShell.Layer.OVERLAY)
    GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.NONE)
    GtkLayerShell.set_exclusive_zone(window, -1)
    for edge in (
        GtkLayerShell.Edge.TOP,
        GtkLayerShell.Edge.BOTTOM,
        GtkLayerShell.Edge.LEFT,
        GtkLayerShell.Edge.RIGHT,
    ):
        GtkLayerShell.set_anchor(window, edge, True)

    def on_draw(_widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(TINT_R, TINT_G, TINT_B, OPACITY)
        cr.paint()
        return False

    area = Gtk.DrawingArea()
    area.set_hexpand(True)
    area.set_vexpand(True)
    if geom_width and geom_height:
        area.set_size_request(geom_width, geom_height)
    area.connect("draw", on_draw)
    area.connect("realize", _set_pass_through)
    area.connect("size-allocate", _set_pass_through)
    window.add(area)

    window.connect("realize", _set_pass_through)
    window.connect("map-event", _set_pass_through)
    window.connect("size-allocate", _set_pass_through)
    window.connect("destroy", _quit)

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, _quit)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, _quit)

    window.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
