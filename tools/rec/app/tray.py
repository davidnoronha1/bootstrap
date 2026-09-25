"""System tray / top-bar recording indicator (StatusNotifierItem over D-Bus).

Needs only PyGObject (Gio/GLib) - no AppIndicator bindings. GNOME shows it via
the AppIndicator extension; KDE and most other panels support SNI natively.

Run as a child process:
    stdin  <- "label <text>"   update the text next to the icon
              "quit"           remove the icon and exit
    stdout -> "stop"           the user clicked the icon
"""

import os
import sys

from gi.repository import Gio, GLib

ITEM_PATH = "/StatusNotifierItem"

SNI_XML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <property name="XAyatanaLabel" type="s" access="read"/>
    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus"><arg type="s"/></signal>
    <signal name="XAyatanaNewLabel"><arg type="s"/><arg type="s"/></signal>
  </interface>
</node>
"""


def red_dot(size: int) -> bytes:
    """ARGB32 (network byte order) filled circle in the app's accent colour."""
    r2 = (size / 2 - 1) ** 2
    c = (size - 1) / 2
    out = bytearray()
    for y in range(size):
        for x in range(size):
            inside = (x - c) ** 2 + (y - c) ** 2 <= r2
            out += bytes((255, 0xE1, 0x1D, 0x48)) if inside else bytes(4)
    return bytes(out)


class Tray:
    def __init__(self) -> None:
        self.label = "REC"
        self.loop = GLib.MainLoop()
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        node = Gio.DBusNodeInfo.new_for_xml(SNI_XML)
        self.bus.register_object(ITEM_PATH, node.interfaces[0], self._on_call, self._on_get, None)
        self.name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        Gio.bus_own_name_on_connection(self.bus, self.name, Gio.BusNameOwnerFlags.NONE, None, None)
        self.bus.call_sync(
            "org.kde.StatusNotifierWatcher",
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem",
            GLib.Variant("(s)", (self.name,)),
            None,
            Gio.DBusCallFlags.NONE,
            3000,
            None,
        )
        GLib.io_add_watch(GLib.IOChannel.unix_new(sys.stdin.fileno()), GLib.PRIORITY_DEFAULT,
                          GLib.IOCondition.IN | GLib.IOCondition.HUP, self._on_stdin)

    def _on_get(self, conn, sender, path, iface, prop):
        pixmaps = [(s, s, red_dot(s)) for s in (16, 22, 32, 48)]
        return {
            "Category": GLib.Variant("s", "ApplicationStatus"),
            "Id": GLib.Variant("s", "rec"),
            "Title": GLib.Variant("s", "rec: recording"),
            "Status": GLib.Variant("s", "Active"),
            "IconName": GLib.Variant("s", ""),
            "IconPixmap": GLib.Variant("a(iiay)", pixmaps),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], "Recording", "Click to stop")),
            "ItemIsMenu": GLib.Variant("b", False),
            "Menu": GLib.Variant("o", "/NO_DBUSMENU"),
            "XAyatanaLabel": GLib.Variant("s", self.label),
        }.get(prop)

    def _on_call(self, conn, sender, path, iface, method, params, invocation):
        if method in ("Activate", "SecondaryActivate", "ContextMenu"):
            print("stop", flush=True)
        invocation.return_value(None)

    def _on_stdin(self, channel, condition):
        line = sys.stdin.readline()
        if not line or line.strip() == "quit":
            self.loop.quit()
            return False
        cmd, _, arg = line.rstrip("\n").partition(" ")
        if cmd == "label":
            self.label = arg
            self.bus.emit_signal(None, ITEM_PATH, "org.kde.StatusNotifierItem",
                                 "XAyatanaNewLabel", GLib.Variant("(ss)", (arg, "")))
        return True

    def run(self) -> None:
        self.loop.run()


if __name__ == "__main__":
    try:
        Tray().run()
    except GLib.Error as e:
        print(f"tray unavailable: {e.message}", file=sys.stderr)
        sys.exit(1)
