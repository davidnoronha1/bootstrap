"""System tray / top-bar recording indicator (StatusNotifierItem over D-Bus).

Needs only PyGObject (Gio/GLib) - no AppIndicator bindings. GNOME shows it via
the AppIndicator extension; KDE and most other panels support SNI natively.

Run as a child process:
    stdin  <- "label <text>"    update the text next to the icon
              "paused true|false"  update the Pause/Resume menu item
              "quit"               remove the icon and exit
    stdout -> "stop"             the user clicked the icon or the Stop menu item
              "pause"            the user clicked Pause/Resume in the menu

Left-clicking the icon stops the recording (quick action). Right-clicking (or
however the panel opens a StatusNotifierItem's context menu) shows a small
menu with explicit Pause/Resume and Stop items.
"""

import os
import sys

from gi.repository import Gio, GLib

ITEM_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"

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

MENU_XML = """
<node>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg name="parentId" type="i" direction="in"/>
      <arg name="recursionDepth" type="i" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="revision" type="u" direction="out"/>
      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="properties" type="a(ia{sv})" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg name="id" type="i" direction="in"/>
      <arg name="name" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="Event">
      <arg name="id" type="i" direction="in"/>
      <arg name="eventId" type="s" direction="in"/>
      <arg name="data" type="v" direction="in"/>
      <arg name="timestamp" type="u" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg name="events" type="a(isvu)" direction="in"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg name="id" type="i" direction="in"/>
      <arg name="needUpdate" type="b" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})"/>
      <arg type="a(ias)"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u"/>
      <arg type="i"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i"/>
      <arg type="u"/>
    </signal>
  </interface>
</node>
"""

PAUSE_ID = 1
STOP_ID = 2


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
        self.paused = False
        self.menu_revision = 1
        self.loop = GLib.MainLoop()
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

        item_node = Gio.DBusNodeInfo.new_for_xml(SNI_XML)
        self.bus.register_object(ITEM_PATH, item_node.interfaces[0], self._on_item_call, self._on_item_get, None)

        menu_node = Gio.DBusNodeInfo.new_for_xml(MENU_XML)
        self.bus.register_object(MENU_PATH, menu_node.interfaces[0], self._on_menu_call, self._on_menu_get, None)

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

    # ---- StatusNotifierItem -------------------------------------------------

    def _on_item_get(self, conn, sender, path, iface, prop):
        pixmaps = [(s, s, red_dot(s)) for s in (16, 22, 32, 48)]
        return {
            "Category": GLib.Variant("s", "ApplicationStatus"),
            "Id": GLib.Variant("s", "rec"),
            "Title": GLib.Variant("s", "rec: recording"),
            "Status": GLib.Variant("s", "Active"),
            "IconName": GLib.Variant("s", ""),
            "IconPixmap": GLib.Variant("a(iiay)", pixmaps),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], "Recording", "Click to stop, right-click to pause")),
            "ItemIsMenu": GLib.Variant("b", False),
            "Menu": GLib.Variant("o", MENU_PATH),
            "XAyatanaLabel": GLib.Variant("s", self.label),
        }.get(prop)

    def _on_item_call(self, conn, sender, path, iface, method, params, invocation):
        if method in ("Activate", "SecondaryActivate"):
            print("stop", flush=True)
        elif method == "ContextMenu":
            pass  # panel opens the Menu object itself
        invocation.return_value(None)

    # ---- com.canonical.dbusmenu ---------------------------------------------

    def _pause_label(self) -> str:
        return "Resume" if self.paused else "Pause"

    def _item_props(self, iid: int) -> dict:
        if iid == PAUSE_ID:
            return {"label": self._pause_label(), "enabled": True, "visible": True}
        if iid == STOP_ID:
            return {"label": "Stop", "enabled": True, "visible": True}
        return {}

    @staticmethod
    def _props_variant(props: dict) -> dict:
        out = {}
        for k, v in props.items():
            if isinstance(v, bool):
                out[k] = GLib.Variant("b", v)
            else:
                out[k] = GLib.Variant("s", str(v))
        return out

    def _leaf(self, iid: int):
        return (iid, self._props_variant(self._item_props(iid)), [])

    def _build_layout(self):
        children = [GLib.Variant("(ia{sv}av)", self._leaf(iid)) for iid in (PAUSE_ID, STOP_ID)]
        return (0, self._props_variant({"children-display": "submenu"}), children)

    def _on_menu_get(self, conn, sender, path, iface, prop):
        return {
            "Version": GLib.Variant("u", 3),
            "TextDirection": GLib.Variant("s", "ltr"),
            "Status": GLib.Variant("s", "normal"),
            "IconThemePath": GLib.Variant("as", []),
        }.get(prop)

    def _on_menu_call(self, conn, sender, path, iface, method, params, invocation):
        if method == "GetLayout":
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (self.menu_revision, self._build_layout())))
        elif method == "GetGroupProperties":
            ids = params.unpack()[0]
            result = [(iid, self._props_variant(self._item_props(iid))) for iid in ids]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (result,)))
        elif method == "GetProperty":
            iid, name = params.unpack()
            val = self._item_props(iid).get(name, "")
            invocation.return_value(GLib.Variant("(v)", (GLib.Variant("s", str(val)),)))
        elif method == "Event":
            iid, event_id, _data, _ts = params.unpack()
            self._handle_click(iid, event_id)
            invocation.return_value(None)
        elif method == "EventGroup":
            events = params.unpack()[0]
            for iid, event_id, _data, _ts in events:
                self._handle_click(iid, event_id)
            invocation.return_value(GLib.Variant("(ai)", ([],)))
        elif method == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        else:
            invocation.return_value(None)

    def _handle_click(self, iid: int, event_id: str) -> None:
        if event_id != "clicked":
            return
        if iid == PAUSE_ID:
            print("pause", flush=True)
        elif iid == STOP_ID:
            print("stop", flush=True)

    def _bump_menu(self) -> None:
        self.menu_revision += 1
        self.bus.emit_signal(None, MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated",
                             GLib.Variant("(ui)", (self.menu_revision, 0)))

    # ---- stdin protocol -------------------------------------------------------

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
        elif cmd == "paused":
            self.paused = arg.strip() == "true"
            self._bump_menu()
        return True

    def run(self) -> None:
        self.loop.run()


if __name__ == "__main__":
    try:
        Tray().run()
    except GLib.Error as e:
        print(f"tray unavailable: {e.message}", file=sys.stderr)
        sys.exit(1)
