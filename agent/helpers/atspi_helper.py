#!/usr/bin/python3 -I
# Tiphys AT-SPI helper (11.4 mobile view): reads the accessibility tree of the focused window and runs component
# actions. Started by the agent (python3 -I); lives only while the mobile view is open.
# Protocol (version 1): JSON lines on stdin/stdout.
#   request:  {"id": n, "cmd": "snapshot", "pid", "title"} | {"id": n, "cmd": "act"|"set_text"|"focus"|"select"|
#           "set_value"|"is_focused", "gen", "node": "3.0.1", ...}  (node = child-index path from the window root)
#           set_text: "typing": false → the keyboard fallback is never tried (no focus given, noAction).
#   response:  {"id": n, "ok": true, ...} or {"id": n, "error": {"code": "..."}}
#   event:   {"event": "hello", "version": 1} (at startup), {"event": "changed"} (coalesced over 300 ms),
#           {"event": "fatal", "code": "helperMissing"} (no python3-gi / Atspi; the process exits)
# PRIVACY: the text of a password field (password text) is never read; tree and text are never written anywhere (incl. stderr).
import json
import os
import re
import sys
import time

VERSION = 1
MAX_DEPTH = 40
MAX_NODES = 1500
MAX_SECONDS = 1.5
MAX_TEXT = 200
MAX_LINE = 1 << 20
COALESCE_MS = 300

# Roles drawn on the phone (Atspi.role_get_name names; also older versions' "push button").
ACTIONABLE = {
    "button", "push button", "push button menu", "toggle button", "check box", "radio button", "switch",
    "menu", "menu item", "check menu item", "radio menu item", "link", "entry", "text", "password text",
    "combo box", "list item", "table cell", "tree item", "page tab", "slider", "spin button",
}
CONTEXT = {"heading", "label"}
GROUPS = {"tool bar", "menu bar", "document web"}
INTERESTING = ACTIONABLE | CONTEXT | GROUPS
WINDOW_ROLES = {"frame", "window", "dialog", "alert", "file chooser"}
TEXT_ROLES = {"entry", "text", "password text"}
STATES = ("focused", "checked", "enabled", "expanded", "selected", "editable")
GENERIC_ACTIONS = ("click", "press", "activate", "toggle", "jump", "open")
# Firefox private window title (140 ESR, Linux: "<page> — Mozilla Firefox Private Browsing"; TR "… Gizli Gezinti";
# macOS format "— Private Browsing"). The tree of these windows is not read (neither by the phone nor by Claude).
PRIVATE_TITLE = re.compile(r"(?:Private Browsing|Gizli Gezinti)\s*$")
# Flatpak apps expose a11y via xdg-dbus-proxy: the pid in AT-SPI may differ from Hyprland's,
# both are in the same systemd scope (app-flatpak-<id>-<n>.scope).
FLATPAK_SCOPE = re.compile(r"(?:^|/)(app-flatpak-[A-Za-z0-9._-]+-\d+\.scope)(?:/|$)")
PATH = re.compile(r"^\d{1,5}(\.\d{1,5}){0,%d}$" % MAX_DEPTH)


class HelperError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _clip(s, n=MAX_TEXT):
    return s[:n] if isinstance(s, str) else ""


def _name(ad, node):
    return _clip((ad.name(node) or "").strip())


def node_states(raw):
    """Raw state names → the small list sent to the phone (PRESSED on a toggle button counts as 'checked')."""
    return [s for s in STATES if s in raw or (s == "checked" and "pressed" in raw)]


def walk(ad, root, clock=time.monotonic, max_depth=MAX_DEPTH, max_nodes=MAX_NODES, max_seconds=MAX_SECONDS):
    """
    Flattens the relevant nodes from the window root into a list (document order). Only SHOWING+VISIBLE nodes;
    a hidden node's subtree is skipped. Over the limit → partial=True. Returns: (nodes, partial, index{path: (role, name)}).
    """
    start = clock()
    nodes = []
    index = {}
    partial = False

    def visit(node, path, depth, parent, level, parent_name):
        nonlocal partial
        if len(nodes) >= max_nodes or clock() - start > max_seconds:
            partial = True
            return False
        if depth > max_depth:
            partial = True
            return True
        try:
            raw = ad.states(node)
        except Exception:
            return True
        if "showing" not in raw or "visible" not in raw:
            return True
        try:
            role = ad.role(node)
            name = _name(ad, node)
        except Exception:
            return True
        keep = role in INTERESTING
        if role == "text" and "editable" not in raw:
            keep = False
        if role in CONTEXT and (not name or name == parent_name):
            keep = False
        my_parent, my_level, my_name = parent, level, parent_name
        if keep:
            n = {"id": path, "parent": parent, "depth": level, "role": role, "name": name}
            n["desc"] = _clip(_safe(lambda: ad.desc(node)) or "")
            n["states"] = node_states(raw)
            n["value"] = _safe(lambda: ad.value(node))
            if role == "password text":
                n["text"] = None
                n["password"] = True
            elif role in TEXT_ROLES:
                n["text"] = _safe(lambda: ad.text(node, MAX_TEXT))
            else:
                n["text"] = None
            n["actions"] = _safe(lambda: ad.actions(node)) or []
            nodes.append(n)
            index[path] = (role, name)
            my_parent, my_level, my_name = path, level + 1, name
        for i, c in enumerate(_kids(ad, node)):
            if not visit(c, f"{path}.{i}" if path else str(i), depth + 1, my_parent, my_level, my_name):
                return False
        return True

    for i, c in enumerate(_kids(ad, root)):
        if not visit(c, str(i), 1, None, 0, None):
            break
    return nodes, partial, index


def _safe(fn):
    try:
        return fn()
    except Exception:
        return None


def _kids(ad, node):
    """Yields children lazily (so the time limit is checked on every child); stops on a read error."""
    try:
        it = iter(ad.children(node))
    except Exception:
        return
    while True:
        try:
            c = next(it)
        except Exception:  # including StopIteration
            return
        yield c


def resolve(ad, root, index, path):
    """Path → node; 'stale' if the role/name in the snapshot doesn't match (the tree changed)."""
    if not isinstance(path, str) or not PATH.match(path) or path not in index:
        raise HelperError("stale")
    node = root
    for part in path.split("."):
        try:
            node = ad.child(node, int(part))
        except Exception:
            raise HelperError("stale")
    try:
        if (ad.role(node), _name(ad, node)) != index[path]:
            raise HelperError("stale")
    except HelperError:
        raise
    except Exception:
        raise HelperError("stale")
    return node


def read_cgroup(pid):
    try:
        with open(f"/proc/{int(pid)}/cgroup", encoding="utf-8", errors="replace") as f:
            return f.read(4096)
    except (OSError, ValueError):
        return ""


def flatpak_scope(text):
    """/proc/<pid>/cgroup text → "app-flatpak-<id>-<n>.scope" or None."""
    for line in (text or "").splitlines():
        m = FLATPAK_SCOPE.search(line.rsplit(":", 1)[-1])
        if m:
            return m.group(1)
    return None


def find_window(ad, desktop, pid, title, cgroup=read_cgroup):
    """
    Hyprland pid → AT-SPI app (otherwise an app in the same flatpak scope) → the SINGLE frame/window whose name
    exactly equals the title. No match, several matches, or a private Firefox window → unsupported (never type into the wrong window).
    """
    apps = [a for a in _kids(ad, desktop) if _safe(lambda: ad.pid(a)) == pid]
    if not apps:
        scope = flatpak_scope(cgroup(pid))
        if scope:
            for a in _kids(ad, desktop):
                p = _safe(lambda: ad.pid(a))
                if isinstance(p, int) and p > 0 and flatpak_scope(cgroup(p)) == scope:
                    apps.append(a)
    matches = []
    for app in apps:
        for w in _kids(ad, app):
            if _safe(lambda: ad.role(w)) in WINDOW_ROLES and (_safe(lambda: ad.name(w)) or "") == title:
                matches.append(w)
    if len(matches) != 1 or not title or PRIVATE_TITLE.search(title):
        raise HelperError("unsupported")
    return matches[0], title


class Session:
    """Last snapshot (generation, root, path index) and commands. [ad] is the tree adapter (real or fake)."""

    def __init__(self, ad, desktop):
        self.ad = ad
        self.desktop = desktop
        self.gen = 0
        self.root = None
        self.pid = None
        self.index = {}

    def snapshot(self, req):
        pid, title = req.get("pid"), req.get("title")
        if not isinstance(pid, int) or pid <= 0:
            raise HelperError("badRequest")
        root, name = find_window(self.ad, self.desktop, pid, title if isinstance(title, str) else "")
        nodes, partial, index = walk(self.ad, root)
        self.gen += 1
        self.root, self.pid, self.index = root, pid, index
        return {"gen": self.gen, "title": _clip(name), "partial": partial, "nodes": nodes}

    def _node(self, req):
        if req.get("gen") != self.gen or self.root is None:
            raise HelperError("stale")
        return resolve(self.ad, self.root, self.index, req.get("node"))

    def act(self, req):
        node = self._node(req)
        action = req.get("action")
        if not isinstance(action, str):
            raise HelperError("badRequest")
        names = [a.lower() for a in self.ad.actions(node)]
        i = names.index(action.lower()) if action.lower() in names else -1
        if i < 0 and action.lower() in GENERIC_ACTIONS:
            # Only one of the allowed generic names; an unknown first action (index 0) is never run.
            i = next((names.index(a) for a in GENERIC_ACTIONS if a in names), -1)
        if i < 0:
            raise HelperError("noAction")
        if not self.ad.do_action(node, i):
            raise HelperError("failed")
        return {}

    def set_text(self, req):
        node = self._node(req)
        text = req.get("text")
        if not isinstance(text, str) or len(text) > 2000:
            raise HelperError("badRequest")
        password = self.ad.role(node) == "password text"
        if password and req.get("confirm") is not True:
            raise HelperError("confirmRequired")
        if _safe(lambda: self.ad.set_text(node, text)):
            return {"needsTyping": False}
        # No editable text interface: keyboard fallback only if focus really moved to this node (otherwise the text
        # goes to another focused field). Never types into a password field or for a "typing": false request.
        if password or req.get("typing") is False:
            raise HelperError("noAction")
        if not _safe(lambda: self.ad.focus(node)) or not self._focused(node):
            raise HelperError("noAction")
        return {"needsTyping": True}

    def _focused(self, node):
        return "focused" in (_safe(lambda: self.ad.states(node)) or set())

    def is_focused(self, req):
        """The agent asks again right before typing (focus may have shifted when the window was raised)."""
        return {"focused": self._focused(self._node(req))}

    def focus(self, req):
        if not self.ad.focus(self._node(req)):
            raise HelperError("failed")
        return {}

    def select(self, req):
        if not self.ad.select(self._node(req)):
            raise HelperError("noAction")
        return {}

    def set_value(self, req):
        node = self._node(req)
        v = req.get("value")
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise HelperError("badRequest")
        if not self.ad.set_value(node, float(v)):
            raise HelperError("noAction")
        return {}

    def handle(self, req):
        """Single request → response dict; no exception leaks out."""
        rid = req.get("id") if isinstance(req, dict) else None
        try:
            if not isinstance(req, dict):
                raise HelperError("badRequest")
            fn = {"snapshot": self.snapshot, "act": self.act, "set_text": self.set_text, "focus": self.focus,
                  "select": self.select, "set_value": self.set_value, "is_focused": self.is_focused}.get(req.get("cmd"))
            if fn is None:
                raise HelperError("badRequest")
            out = fn(req)
            out.update({"id": rid, "ok": True})
            return out
        except HelperError as e:
            return {"id": rid, "error": {"code": e.code}}
        except Exception:
            return {"id": rid, "error": {"code": "failed"}}


class AtspiAdapter:
    """Real AT-SPI (gi Atspi 2.0). Interface methods are called explicitly (so they don't clash with Accessible.get_name)."""

    def __init__(self, Atspi):
        self.A = Atspi

    def role(self, n):
        return self.A.role_get_name(n.get_role())

    def name(self, n):
        return n.get_name()

    def desc(self, n):
        return n.get_description()

    def pid(self, n):
        return n.get_process_id()

    def states(self, n):
        return {s.value_nick for s in n.get_state_set().get_states()}

    def children(self, n):
        # Lazy: the walk's time limit is checked on every child (doesn't prefetch 5000 children).
        for i in range(min(n.get_child_count(), 5000)):
            yield n.get_child_at_index(i)

    def child(self, n, i):
        if not 0 <= i < n.get_child_count():
            raise IndexError(i)
        return n.get_child_at_index(i)

    def value(self, n):
        v = n.get_value_iface()
        if v is None:
            return None
        V = self.A.Value
        return {"now": V.get_current_value(v), "min": V.get_minimum_value(v), "max": V.get_maximum_value(v), "step": V.get_minimum_increment(v)}

    def text(self, n, limit):
        t = n.get_text_iface()
        if t is None:
            return None
        return self.A.Text.get_text(t, 0, min(self.A.Text.get_character_count(t), limit))

    def actions(self, n):
        a = n.get_action_iface()
        if a is None:
            return []
        return [self.A.Action.get_action_name(a, i) for i in range(min(self.A.Action.get_n_actions(a), 20))]

    def do_action(self, n, i):
        return self.A.Action.do_action(n.get_action_iface(), i)

    def set_text(self, n, text):
        e = n.get_editable_text_iface()
        return bool(e and self.A.EditableText.set_text_contents(e, text))

    def focus(self, n):
        c = n.get_component_iface()
        return bool(c and self.A.Component.grab_focus(c))

    def select(self, n):
        p = n.get_parent()
        s = p.get_selection_iface() if p else None
        return bool(s and self.A.Selection.select_child(s, n.get_index_in_parent()))

    def set_value(self, n, v):
        iface = n.get_value_iface()
        if iface is None:
            return False
        V = self.A.Value
        return bool(V.set_current_value(iface, min(max(v, V.get_minimum_value(iface)), V.get_maximum_value(iface))))


# Called when stdout closes (agent died): the main loop ends, the helper isn't left orphaned.
ON_BROKEN = [lambda: None]


def write(obj):
    try:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except (OSError, ValueError):  # BrokenPipeError, closed file
        ON_BROKEN[0]()


def main():
    import warnings
    warnings.simplefilter("ignore", DeprecationWarning)  # keep gi's deprecated-method warnings from flooding stderr
    try:
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi, GLib
    except Exception:
        write({"event": "fatal", "code": "helperMissing"})
        sys.exit(3)
    Atspi.init()
    # A hung app must not lock up the helper: 1 s per call, no extra time for startup.
    Atspi.set_timeout(1000, 0)
    session = Session(AtspiAdapter(Atspi), Atspi.get_desktop(0))
    loop = GLib.MainLoop()
    ON_BROKEN[0] = loop.quit
    pending = [False]

    def flush_changed():
        pending[0] = False
        write({"event": "changed"})
        return False

    def on_event(ev, *_):
        try:
            if session.pid is None or pending[0] or ev.source is None or ev.source.get_process_id() != session.pid:
                return
            pending[0] = True
            GLib.timeout_add(COALESCE_MS, flush_changed)
        except Exception:
            pass

    listener = Atspi.EventListener.new(on_event)
    for ev in ("object:children-changed", "object:state-changed", "focus:", "object:text-changed"):
        listener.register(ev)

    buf = bytearray()
    fd = sys.stdin.fileno()

    def on_input(_fd, cond):
        if cond & (GLib.IOCondition.ERR | GLib.IOCondition.NVAL):
            loop.quit()
            return False
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            loop.quit()
            return False
        buf.extend(chunk)
        while True:
            i = buf.find(b"\n")
            if i < 0:
                if len(buf) > MAX_LINE:
                    buf.clear()
                    write({"id": None, "error": {"code": "badRequest"}})
                break
            line = bytes(buf[:i])
            del buf[: i + 1]
            if not line.strip():
                continue
            try:
                req = json.loads(line)
            except Exception:
                write({"id": None, "error": {"code": "badRequest"}})
                continue
            write(session.handle(req))
        return True

    GLib.io_add_watch(fd, GLib.PRIORITY_DEFAULT, GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR | GLib.IOCondition.NVAL, on_input)
    write({"event": "hello", "version": VERSION})
    loop.run()


if __name__ == "__main__":
    main()
