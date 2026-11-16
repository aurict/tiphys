# Real AT-SPI test (TIPHYS_REAL=1): mousepad (GTK3) is started on a private Xvfb display, in a private D-Bus session
# (only the org.a11y.Bus service), with a temporary HOME; the helper process takes a snapshot, types into the text
# area, presses the "File" menu and verifies the state change. The user's display, D-Bus and IsEnabled setting are
# not touched; only the process groups started by this test are killed.
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helpers", "atspi_helper.py")

BUS_CONF = """<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:dir={run}</listen><auth>EXTERNAL</auth><servicedir>{svc}</servicedir>
<policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
"""


def free_display():
    for n in range(91, 200):
        if not os.path.exists(f"/tmp/.X11-unix/X{n}") and not os.path.exists(f"/tmp/.X{n}-lock"):
            return n
    raise RuntimeError("boş ekran yok")


@unittest.skipUnless(os.environ.get("TIPHYS_REAL") == "1", "TIPHYS_REAL=1 değil")
class RealMousepadTest(unittest.TestCase):
    def setUp(self):
        for cmd in ("Xvfb", "dbus-daemon", "mousepad"):
            if not shutil.which(cmd):
                self.skipTest(f"{cmd} yok")
        self.procs = []
        self.tmp = tempfile.mkdtemp(prefix="tiphys-atspi-")
        run, svc, home = (os.path.join(self.tmp, d) for d in ("run", "svc", "home"))
        for d in (run, svc, home):
            os.makedirs(d, mode=0o700)
        shutil.copy("/usr/share/dbus-1/services/org.a11y.Bus.service", svc)
        conf = os.path.join(self.tmp, "bus.conf")
        with open(conf, "w") as f:
            f.write(BUS_CONF.format(run=run, svc=svc))
        n = free_display()
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C.UTF-8", "DISPLAY": f":{n}", "GDK_BACKEND": "x11",
            "HOME": home, "XDG_RUNTIME_DIR": run, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
            "XDG_CACHE_HOME": os.path.join(home, ".cache"), "XDG_DATA_HOME": os.path.join(home, ".local/share"),
            "GSETTINGS_BACKEND": "memory", "GTK_USE_PORTAL": "0", "NO_AT_BRIDGE": "0",
        }
        self.spawn(["Xvfb", f":{n}", "-screen", "0", "1280x800x24", "-nolisten", "tcp"], stderr=subprocess.DEVNULL)
        for _ in range(50):
            if os.path.exists(f"/tmp/.X11-unix/X{n}"):
                break
            time.sleep(0.1)
        bus = self.spawn(["dbus-daemon", f"--config-file={conf}", "--nofork", "--print-address=1"], stdout=subprocess.PIPE)
        self.env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().decode().strip()
        self.app = self.spawn(["mousepad"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.helper = self.spawn([sys.executable, "-I", HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.events = []
        self.assertEqual(self.read(10), {"event": "hello", "version": 1})
        self.seq = 0

    def spawn(self, args, **kw):
        p = subprocess.Popen(args, env=self.env, start_new_session=True, **kw)
        self.procs.append(p)
        return p

    def tearDown(self):
        # Only our own process groups (the a11y bus started by dbus-daemon is in its group too).
        for p in reversed(self.procs):
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for p in self.procs:
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
            for f in (p.stdin, p.stdout, p.stderr):
                if f:
                    f.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read(self, timeout):
        r, _, _ = select.select([self.helper.stdout], [], [], timeout)
        if not r:
            raise TimeoutError("yardımcı yanıt vermedi")
        return json.loads(self.helper.stdout.readline())

    def call(self, cmd, **kw):
        self.seq += 1
        self.helper.stdin.write((json.dumps({"id": self.seq, "cmd": cmd, **kw}) + "\n").encode())
        self.helper.stdin.flush()
        while True:
            m = self.read(10)
            if m.get("event"):
                self.events.append(m)
            elif m.get("id") == self.seq:
                return m

    def wait_changed(self, timeout=5):
        end = time.time() + timeout
        while not self.events and time.time() < end:
            try:
                m = self.read(max(0.1, end - time.time()))
            except TimeoutError:
                break
            if m.get("event") == "changed":
                self.events.append(m)
        ok = bool(self.events)
        self.events.clear()
        return ok

    def snapshot(self):
        for _ in range(50):  # until the app's tree is ready
            # Exact title required (mousepad prefixes the title with "*" after typing; the agent passes
            # Hyprland's current title).
            for title in ("Untitled 1 - Mousepad", "*Untitled 1 - Mousepad"):
                s = self.call("snapshot", pid=self.app.pid, title=title)
                if s.get("ok"):
                    break
            if s.get("ok") and any(n["role"] == "menu" for n in s["nodes"]):
                return s
            time.sleep(0.2)
        self.fail(f"anlık görüntü yok: {s}")

    def test_snapshot_act_text(self):
        t0 = time.time()
        s = self.snapshot()
        self.assertFalse(s["partial"])
        self.assertIn("Mousepad", s["title"])
        menu = next(n for n in s["nodes"] if n["role"] == "menu" and n["name"] == "File")
        text = next(n for n in s["nodes"] if n["role"] == "text" and "editable" in n["states"])
        self.assertIn("click", menu["actions"])
        self.assertNotIn("menu item", [n["role"] for n in s["nodes"]])

        r = self.call("set_text", gen=s["gen"], node=text["id"], text="merhaba Tiphys")
        self.assertEqual(r.get("needsTyping"), False, r)
        self.assertTrue(self.wait_changed(), "text-changed olayı gelmedi")
        s2 = self.snapshot()
        self.assertEqual(next(n for n in s2["nodes"] if n["id"] == text["id"])["text"], "merhaba Tiphys")

        # An action with a stale generation is rejected.
        self.assertEqual(self.call("act", gen=s["gen"], node=menu["id"], action="click")["error"]["code"], "stale")
        # Press the menu: it opens and its items become visible.
        self.assertTrue(self.call("act", gen=s2["gen"], node=menu["id"], action="click").get("ok"))
        self.assertTrue(self.wait_changed(), "state-changed olayı gelmedi")
        for _ in range(25):
            s3 = self.call("snapshot", pid=self.app.pid, title="*Untitled 1 - Mousepad")
            items = [n for n in s3.get("nodes", []) if n["role"] == "menu item"]
            if items:
                break
            time.sleep(0.2)
        self.assertTrue(items, "menü açılmadı")
        self.assertIn("Save", [n["name"] for n in items])
        print(f"\ngerçek mousepad: {len(s['nodes'])} düğüm → menü açık {len(s3['nodes'])}, {time.time() - t0:.2f} sn", file=sys.stderr)


if __name__ == "__main__":
    unittest.main()
