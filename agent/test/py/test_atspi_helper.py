# Tree logic of the AT-SPI helper: flattening, limits, password field, stale id, window matching, commands.
# Uses recorded fake trees (fixtures/: mousepad.json recorded under Xvfb, firefox.json written by hand); no gi needed.
# Run: cd agent/test/py && python3 -I -m unittest
import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "helpers"))
import atspi_helper as h  # noqa: E402


def load(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return json.load(f)


class FakeAdapter:
    """Dict tree: {role, name, states[], children[], actions[], text, value, pid}."""

    def __init__(self, desktop):
        self.desktop = desktop
        self.parents = {}
        self.calls = []
        self.texts = {}

        def link(n):
            for c in n.get("children", []):
                self.parents[id(c)] = n
                link(c)

        link(desktop)

    def role(self, n):
        return n["role"]

    def name(self, n):
        return n.get("name", "")

    def desc(self, n):
        return n.get("desc", "")

    def pid(self, n):
        return n.get("pid")

    def states(self, n):
        if n.get("broken"):
            raise RuntimeError("D-Bus zaman aşımı")
        return set(n.get("states", []))

    def children(self, n):
        return n.get("children", [])

    def child(self, n, i):
        return n.get("children", [])[i]

    def value(self, n):
        return n.get("value")

    def text(self, n, limit):
        if n["role"] == "password text":
            raise AssertionError("şifre alanı metni okundu")
        t = n.get("text")
        return t[:limit] if t is not None else None

    def actions(self, n):
        return n.get("actions", [])

    def do_action(self, n, i):
        self.calls.append(("action", n.get("name"), n["actions"][i]))
        return True

    def set_text(self, n, text):
        if n["role"] not in ("entry", "password text"):
            return False
        self.calls.append(("set_text", n.get("name"), text))
        return True

    def focus(self, n):
        self.calls.append(("focus", n.get("name")))
        if n.get("focusable") is False:
            return False
        if n.get("focus_moves", True):
            n["states"] = sorted(set(n.get("states", [])) | {"focused"})
        return True

    def select(self, n):
        p = self.parents.get(id(n))
        if not p or p["role"] != "page tab list":
            return False
        self.calls.append(("select", n.get("name"), p["children"].index(n)))
        return True

    def set_value(self, n, v):
        if n.get("value") is None:
            return False
        self.calls.append(("set_value", n.get("name"), v))
        return True


def session(tree):
    ad = FakeAdapter(tree)
    return h.Session(ad, tree), ad


def by_name(nodes, name):
    return next(n for n in nodes if n["name"] == name)


class WalkTest(unittest.TestCase):
    def test_firefox_flatten(self):
        s, _ = session(load("firefox.json"))
        r = s.handle({"id": 1, "cmd": "snapshot", "pid": 4321, "title": "Giriş — Mozilla Firefox"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["gen"], 1)
        self.assertFalse(r["partial"])
        self.assertEqual(r["title"], "Giriş — Mozilla Firefox")
        names = [n["name"] for n in r["nodes"]]
        # No subtree of a hidden menu, read-only text, empty label, or a label with the same name as its button.
        for absent in ("Gizli menü", "Görünmemeli", "Salt okunur paragraf"):
            self.assertNotIn(absent, names)
        self.assertEqual(names.count("Giriş yap"), 1)
        self.assertNotIn("", [n["name"] for n in r["nodes"] if n["role"] == "label"])
        # Context label stays; groups and hierarchy.
        self.assertIn("Kullanıcı adı", [n["name"] for n in r["nodes"] if n["role"] == "label"])
        tb = by_name(r["nodes"], "Gezinti")
        self.assertEqual((tb["role"], tb["parent"], tb["depth"]), ("tool bar", None, 0))
        back = by_name(r["nodes"], "Geri")
        self.assertEqual((back["parent"], back["depth"], back["actions"]), (tb["id"], 1, ["press"]))
        self.assertEqual(back["states"], ["enabled"])
        self.assertEqual(by_name(r["nodes"], "İleri")["states"], [])
        url = by_name(r["nodes"], "Ara ya da adres gir")
        self.assertEqual(url["text"], "https://example.com/giris")
        self.assertEqual(url["states"], ["focused", "enabled", "editable"])
        self.assertEqual(by_name(r["nodes"], "Koyu tema")["states"], ["checked", "enabled"])
        self.assertEqual(by_name(r["nodes"], "Ses")["value"], {"now": 40, "min": 0, "max": 100, "step": 1})
        self.assertEqual(by_name(r["nodes"], "Giriş")["role"], "page tab")
        doc = next(n for n in r["nodes"] if n["role"] == "document web")
        self.assertEqual(by_name(r["nodes"], "Hesabına gir")["parent"], doc["id"])

    def test_password_never_read(self):
        s, _ = session(load("firefox.json"))
        r = s.handle({"id": 1, "cmd": "snapshot", "pid": 4321, "title": "Giriş — Mozilla Firefox"})
        pw = by_name(r["nodes"], "Şifre")
        self.assertIsNone(pw["text"])
        self.assertTrue(pw["password"])
        self.assertNotIn("GİZLİ", json.dumps(r, ensure_ascii=False))

    def test_mousepad_recorded(self):
        s, _ = session(load("mousepad.json"))
        r = s.handle({"id": 1, "cmd": "snapshot", "pid": 4321, "title": "Untitled 1 - Mousepad"})
        roles = [n["role"] for n in r["nodes"]]
        self.assertEqual(roles.count("menu"), 6)  # items of closed menus aren't visible
        self.assertNotIn("menu item", roles)
        self.assertIn("menu bar", roles)
        self.assertEqual(by_name(r["nodes"], "File")["actions"], ["click"])
        self.assertIn("editable", next(n for n in r["nodes"] if n["role"] == "text")["states"])

    def test_limits(self):
        def chain(n):
            node = {"role": "button", "name": "en alt", "states": ["showing", "visible"]}
            for i in range(n):
                node = {"role": "panel", "name": f"p{i}", "states": ["showing", "visible"], "children": [node]}
            return node

        wide = {"role": "panel", "states": ["showing", "visible"], "children": [
            {"role": "button", "name": f"b{i}", "states": ["showing", "visible"]} for i in range(2000)]}
        ad = FakeAdapter({"children": []})
        nodes, partial, _ = h.walk(ad, {"children": [chain(10)]})
        self.assertEqual((len(nodes), partial), (1, False))
        nodes, partial, _ = h.walk(ad, {"children": [chain(45)]})
        self.assertEqual((len(nodes), partial), (0, True))
        nodes, partial, _ = h.walk(ad, {"children": [wide]})
        self.assertEqual((len(nodes), partial), (h.MAX_NODES, True))
        t = iter(range(0, 1000, 1))  # fake clock that advances 1 s per call
        nodes, partial, _ = h.walk(ad, {"children": [wide]}, clock=lambda: next(t))
        self.assertTrue(partial)
        self.assertLess(len(nodes), 3)

    def test_broken_node_skipped(self):
        tree = load("firefox.json")
        win = tree["children"][1]["children"][1]
        win["children"][0]["children"][0]["broken"] = True
        s, _ = session(tree)
        r = s.handle({"id": 1, "cmd": "snapshot", "pid": 4321, "title": "Giriş — Mozilla Firefox"})
        self.assertNotIn("Geri", [n["name"] for n in r["nodes"]])
        self.assertIn("İleri", [n["name"] for n in r["nodes"]])


class WindowTest(unittest.TestCase):
    def unsupported(self, fn):
        with self.assertRaises(h.HelperError) as e:
            fn()
        self.assertEqual(e.exception.code, "unsupported")

    def test_match(self):
        tree = load("firefox.json")
        ad = FakeAdapter(tree)
        app = tree["children"][1]
        self.assertEqual(h.find_window(ad, tree, 4321, "Giriş — Mozilla Firefox")[1], "Giriş — Mozilla Firefox")
        self.assertEqual(h.find_window(ad, tree, 4321, "Eski sekme — Mozilla Firefox")[1], "Eski sekme — Mozilla Firefox")
        # Exact title only: no substring, active window or first-frame fallback.
        for title in ("Başka", "Giriş", "giriş — mozilla firefox", ""):
            self.unsupported(lambda: h.find_window(ad, tree, 4321, title))
        # Two windows with the same title → it can't tell which one.
        app["children"].append({"role": "dialog", "name": "Giriş — Mozilla Firefox", "states": ["showing", "visible"]})
        self.unsupported(lambda: h.find_window(ad, tree, 4321, "Giriş — Mozilla Firefox"))
        with self.assertRaises(h.HelperError) as e:
            h.find_window(ad, tree, 1, "x")
        self.assertEqual(e.exception.code, "unsupported")
        s, _ = session(tree)
        self.assertEqual(s.handle({"id": 3, "cmd": "snapshot", "pid": 900, "title": ""}), {"id": 3, "error": {"code": "unsupported"}})
        self.assertEqual(s.handle({"id": 4, "cmd": "snapshot", "pid": "4321"})["error"]["code"], "badRequest")

    def test_private_window(self):
        tree = load("firefox.json")
        ad = FakeAdapter(tree)
        frame = tree["children"][1]["children"][1]
        # Firefox 140 ESR (Linux) and macOS formats, TR and EN.
        for title in ("Giriş — Mozilla Firefox Private Browsing", "Mozilla Firefox Private Browsing",
                      "Giriş — Mozilla Firefox Gizli Gezinti", "Mozilla Firefox Gizli Gezinti", "Giriş — Gizli Gezinti"):
            frame["name"] = title
            self.unsupported(lambda: h.find_window(ad, tree, 4321, title))

    def test_flatpak_cgroup(self):
        tree = load("firefox.json")
        ad = FakeAdapter(tree)
        app = tree["children"][1]
        app["pid"] = 7001  # xdg-dbus-proxy
        scope = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-org.mozilla.firefox-1234.scope\n"
        other = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-com.visualstudio.code-99.scope\n"
        proc = {4321: scope, 7001: scope, 900: "0::/user.slice/user-1000.slice/session-2.scope\n"}
        read = lambda pid: proc.get(pid, "")  # noqa: E731
        self.assertEqual(h.flatpak_scope(scope), "app-flatpak-org.mozilla.firefox-1234.scope")
        self.assertIsNone(h.flatpak_scope(proc[900]))
        self.assertIsNone(h.flatpak_scope(""))
        self.assertEqual(h.find_window(ad, tree, 4321, "Giriş — Mozilla Firefox", cgroup=read)[1], "Giriş — Mozilla Firefox")
        # A process in another scope or with no scope isn't matched; the exact title rule applies to matching too.
        self.unsupported(lambda: h.find_window(ad, tree, 4321, "Giriş — Mozilla Firefox", cgroup=lambda p: other if p == 7001 else scope))
        self.unsupported(lambda: h.find_window(ad, tree, 4321, "Giriş — Mozilla Firefox", cgroup=lambda p: ""))
        self.unsupported(lambda: h.find_window(ad, tree, 4321, "Başka", cgroup=read))
        # If a second app in the same scope offers a window with the same title, the single-match requirement still
        # holds.
        tree["children"].append({"role": "application", "name": "Firefox", "pid": 7002, "children": [
            {"role": "frame", "name": "Giriş — Mozilla Firefox", "states": ["showing", "visible"]}]})
        proc[7002] = scope
        self.unsupported(lambda: h.find_window(ad, tree, 4321, "Giriş — Mozilla Firefox", cgroup=read))


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.tree = load("firefox.json")
        self.s, self.ad = session(self.tree)
        self.snap = self.s.handle({"id": 1, "cmd": "snapshot", "pid": 4321, "title": "Giriş — Mozilla Firefox"})
        self.ids = {n["name"]: n["id"] for n in self.snap["nodes"]}

    def cmd(self, cmd, name, **kw):
        return self.s.handle({"id": 9, "cmd": cmd, "gen": self.snap["gen"], "node": self.ids[name], **kw})

    def test_actions(self):
        self.assertTrue(self.cmd("act", "Geri", action="press")["ok"])
        self.assertTrue(self.cmd("act", "Şifremi unuttum", action="activate")["ok"])  # genel ad → jump
        self.assertEqual(self.cmd("act", "Beni hatırla", action="explode")["error"]["code"], "noAction")
        self.assertEqual(self.cmd("act", "Hesabına gir", action="click")["error"]["code"], "noAction")
        # Without an allowed generic name, the first (unknown) action isn't run.
        self._find(self.tree, "Beni hatırla")["actions"] = ["dismiss"]
        before = list(self.ad.calls)
        self.assertEqual(self.cmd("act", "Beni hatırla", action="click")["error"]["code"], "noAction")
        self.assertEqual(self.ad.calls, before)
        self.assertTrue(self.cmd("select", "Haberler")["ok"])
        self.assertEqual(self.cmd("select", "Geri")["error"]["code"], "noAction")
        self.assertTrue(self.cmd("set_value", "Ses", value=75)["ok"])
        self.assertEqual(self.cmd("set_value", "Ses", value=True)["error"]["code"], "badRequest")
        self.assertTrue(self.cmd("focus", "Kullanıcı adı")["ok"])
        self.assertEqual(self.ad.calls, [("action", "Geri", "press"), ("action", "Şifremi unuttum", "jump"), ("select", "Haberler", 1), ("set_value", "Ses", 75.0), ("focus", "Kullanıcı adı")])

    def test_text(self):
        self.assertEqual(self.cmd("set_text", "Kullanıcı adı", text="Çağrı")["needsTyping"], False)
        self.assertEqual(self.cmd("set_text", "Şifre", text="x")["error"]["code"], "confirmRequired")
        self.assertTrue(self.cmd("set_text", "Şifre", text="x", confirm=True)["ok"])
        # No editable interface → focus + the agent types.
        self.assertTrue(self.cmd("set_text", "Geri", text="y")["needsTyping"])
        self.assertEqual(self.ad.calls, [("set_text", "Kullanıcı adı", "Çağrı"), ("set_text", "Şifre", "x"), ("focus", "Geri")])
        self.assertEqual(self.cmd("is_focused", "Geri"), {"id": 9, "ok": True, "focused": True})
        self.assertEqual(self.cmd("is_focused", "İleri"), {"id": 9, "ok": True, "focused": False})

    def test_typing_fallback_needs_focus(self):
        def node(name):
            return self._find(self.tree, name)
        # Focus couldn't be taken or stayed elsewhere → no keyboard fallback (so text doesn't land in another focused
        # field).
        node("Geri")["focusable"] = False
        self.assertEqual(self.cmd("set_text", "Geri", text="y")["error"]["code"], "noAction")
        node("İleri")["focus_moves"] = False
        self.assertEqual(self.cmd("set_text", "İleri", text="y")["error"]["code"], "noAction")
        # "typing": false (Claude) → not even focus is given.
        self.ad.calls.clear()
        self.assertEqual(self.cmd("set_text", "Beni hatırla", text="y", typing=False)["error"]["code"], "noAction")
        self.assertEqual(self.ad.calls, [])
        # A (confirmed) password field without an editable interface isn't typed into via the keyboard either.
        pw = node("Şifre")
        pw["role"] = "password text"
        self.ad.set_text = lambda n, t: False
        self.assertEqual(self.cmd("set_text", "Şifre", text="x", confirm=True)["error"]["code"], "noAction")

    def _find(self, n, name):
        if n.get("name") == name:
            return n
        for c in n.get("children", []):
            r = self._find(c, name)
            if r is not None:
                return r
        return None

    def test_stale(self):
        node = self.ids["Geri"]
        self.assertEqual(self.s.handle({"id": 2, "cmd": "act", "gen": 0, "node": node, "action": "press"})["error"]["code"], "stale")
        self.assertEqual(self.s.handle({"id": 2, "cmd": "act", "gen": 1, "node": "9.9.9", "action": "press"})["error"]["code"], "stale")
        self.assertEqual(self.s.handle({"id": 2, "cmd": "act", "gen": 1, "node": "0;rm", "action": "press"})["error"]["code"], "stale")
        # The tree changed (another node replaced the button) → the same path is stale too.
        tb = self.tree["children"][1]["children"][1]["children"][0]
        tb["children"].insert(0, {"role": "button", "name": "Ana sayfa", "states": ["showing", "visible"], "actions": ["press"]})
        self.assertEqual(self.cmd("act", "Geri", action="press")["error"]["code"], "stale")
        # New snapshot: the generation increments, the old one becomes invalid.
        snap2 = self.s.handle({"id": 3, "cmd": "snapshot", "pid": 4321, "title": "Giriş — Mozilla Firefox"})
        self.assertEqual(snap2["gen"], 2)
        self.assertEqual(self.s.handle({"id": 4, "cmd": "act", "gen": 1, "node": node, "action": "press"})["error"]["code"], "stale")
        self.assertEqual(self.ad.calls, [])

    def test_never_raises(self):
        for req in ([1], {"cmd": "nope"}, {"id": 5, "cmd": "act"}, {"id": 6, "cmd": "set_text", "gen": 1, "node": self.ids["Kullanıcı adı"], "text": 5}):
            r = self.s.handle(req)
            self.assertIn("error", r)
        boom = copy.deepcopy(self.tree)
        s, ad = session(boom)
        s.handle({"id": 1, "cmd": "snapshot", "pid": 4321, "title": "Giriş — Mozilla Firefox"})
        ad.do_action = lambda n, i: (_ for _ in ()).throw(RuntimeError("D-Bus"))
        r = s.handle({"id": 7, "cmd": "act", "gen": 1, "node": self.ids["Geri"], "action": "press"})
        self.assertEqual(r, {"id": 7, "error": {"code": "failed"}})


class IoTest(unittest.TestCase):
    def test_broken_stdout_quits(self):
        class Broken:
            def write(self, _):
                raise BrokenPipeError()

            def flush(self):
                raise BrokenPipeError()

        quit_calls = []
        old_out, old_hook = sys.stdout, h.ON_BROKEN[0]
        sys.stdout, h.ON_BROKEN[0] = Broken(), lambda: quit_calls.append(1)
        try:
            h.write({"event": "changed"})  # no exception leaks
        finally:
            sys.stdout, h.ON_BROKEN[0] = old_out, old_hook
        self.assertEqual(quit_calls, [1])

    def test_lazy_children_deadline(self):
        # Children are fetched lazily: once time runs out, the remaining children are never requested.
        pulled = []

        class Lazy(FakeAdapter):
            def children(self, n):
                for c in n.get("children", []):
                    pulled.append(c.get("name"))
                    yield c

        wide = {"role": "panel", "states": ["showing", "visible"], "children": [
            {"role": "button", "name": f"b{i}", "states": ["showing", "visible"]} for i in range(100)]}
        t = iter(range(0, 1000))
        _, partial, _ = h.walk(Lazy({"children": []}), {"children": [wide]}, clock=lambda: next(t))
        self.assertTrue(partial)
        self.assertLess(len(pulled), 5)


if __name__ == "__main__":
    unittest.main()
