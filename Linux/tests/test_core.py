"""Behavior checks; all persistent changes use disposable directories."""
import contextlib
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from delegatus_core import ASSETS, Cancelled, Launcher, LauncherError, Paths, PortOwner, Runtime, _identity, _HttpsRedirect


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="delegatus-checks-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "Олег O'Neil space"
        self.paths = Paths(self.root, {"PATH": "/usr/bin:/bin"})
        self.launcher = Launcher(self.paths)

    def runtime(self, version="1.4.3", requirement=">=1.4.0"):
        bun = self.root / "chosen bun"
        bun.parent.mkdir(parents=True, exist_ok=True)
        bun.write_text("#!" + sys.executable + "\nprint(" + repr(version) + ")\n")
        bun.chmod(0o700)
        package = self.root / "chosen packages/delegatus-cli"
        (package / "bin").mkdir(parents=True, exist_ok=True)
        cli = package / "bin/cli.mjs"
        cli.write_text("// fixture")
        (package / "package.json").write_text(json.dumps({"name": "delegatus-cli", "version": "1.11.0", "engines": {"bun": requirement}}))
        return Runtime(bun, cli)

    def test_xdg_absolute_and_relative_fallback(self):
        p = Paths(self.root, {"XDG_DATA_HOME": str(self.root / "data"), "XDG_CONFIG_HOME": "relative"})
        self.assertEqual(p.data, self.root / "data/delegatus-launcher")
        self.assertEqual(p.config, self.root / ".config/delegatus-launcher")

    def test_constructor_never_downloads(self):
        with patch.object(Launcher, "_download", side_effect=AssertionError("unapproved download")):
            other = Launcher(Paths(self.root / "fresh", {}))
            self.assertIsNone(other.discover())

    def test_preferences_survive_new_process_keep_fields_and_unicode(self):
        self.launcher.settings.update(suppress_running_notice=True, bun_path="/tmp/Олег O'Neil bun", retained={"x": 1})
        self.launcher.save_settings()
        code = "from delegatus_core import *; import sys; x=Launcher(Paths(Path(sys.argv[1]),{})); assert x.suppress_notice(); assert x.settings['retained']=={'x':1}"
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
        subprocess.run([sys.executable, "-c", code, str(self.root)], env=env, check=True)
        restored = Launcher(self.paths)
        self.assertEqual(restored.settings["bun_path"], "/tmp/Олег O'Neil bun")
        self.assertEqual(self.paths.settings.stat().st_mode & 0o777, 0o600)
        for value in ("true", "false", 1, None, False):
            restored.settings["suppress_running_notice"] = value
            self.assertFalse(restored.suppress_notice())

    def test_save_failure_preserves_disk_and_cleans_temporary(self):
        self.launcher.settings = {"retained": "old"}
        self.launcher.save_settings()
        before = self.paths.settings.read_bytes()
        self.launcher.settings["retained"] = "new"
        with patch("delegatus_core.os.replace", side_effect=OSError("read only")):
            with self.assertRaises(OSError):
                self.launcher.save_settings()
        self.assertEqual(before, self.paths.settings.read_bytes())
        self.assertEqual(list(self.paths.config.glob(".settings-*")), [])

    def test_malformed_settings_remain_untouched(self):
        self.paths.settings.write_text("not JSON")
        with self.assertRaises(LauncherError):
            Launcher(self.paths)
        self.assertEqual(self.paths.settings.read_text(), "not JSON")

    def test_runtime_validation_and_discovery(self):
        runtime = self.runtime()
        self.launcher.settings["retained"] = 42
        self.launcher.set_runtime(str(runtime.bun), str(runtime.cli))
        self.assertEqual(self.launcher.discover(), runtime)
        self.assertEqual(self.launcher.settings["retained"], 42)
        self.runtime(version="1.3.9")
        with self.assertRaises(LauncherError):
            self.launcher.set_runtime(str(runtime.bun), str(runtime.cli))
        self.runtime(version="1.4.3", requirement=">=1.5.0")
        self.assertIsNone(self.launcher.discover())

    def test_manual_selection_rolls_back_when_save_fails(self):
        runtime = self.runtime()
        self.launcher.settings = {"retained": 42}
        with patch.object(self.launcher, "save_settings", side_effect=OSError("read only")):
            with self.assertRaises(OSError):
                self.launcher.set_runtime(str(runtime.bun), str(runtime.cli))
        self.assertEqual(self.launcher.settings, {"retained": 42})

    def archive(self, unsafe=None):
        p = self.root / "bun.zip"
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("bun-linux-x64-baseline/bun", "fixture")
            if unsafe:
                z.writestr(unsafe, "bad")
        return p

    def test_zip_extraction_refuses_traversal(self):
        for entry in ("../outside", "/outside", "a/../../outside", "a\\outside"):
            with self.assertRaises(LauncherError):
                self.launcher._unpack_bun(self.archive(entry), "bun-linux-x64-baseline.zip", self.root / "extract/bun")
        self.assertFalse((self.root / "outside").exists())

    def test_zip_extraction_uses_only_expected_executable(self):
        target = self.root / "extract/bun"
        self.launcher._unpack_bun(self.archive(), "bun-linux-x64-baseline.zip", target)
        self.assertEqual(target.read_text(), "fixture")
        self.assertEqual(target.stat().st_mode & 0o777, 0o700)

    def test_cancel_before_install_preserves_old_runtime(self):
        self.paths.runtime.mkdir()
        previous = self.paths.runtime / "keep"
        previous.write_text("old runtime")
        cancel = threading.Event(); cancel.set()
        with self.assertRaises(Cancelled):
            self.launcher.install(cancel, lambda _: None)
        self.assertEqual(previous.read_text(), "old runtime")

    def test_cancel_download_discards_stage_preserves_old_runtime(self):
        self.paths.runtime.mkdir()
        (self.paths.runtime / "keep").write_text("old")
        cancel = threading.Event()
        def download(*args):
            cancel.set()
        with patch("delegatus_core.platform.system", return_value="Linux"), patch("delegatus_core.platform.machine", return_value="x86_64"), patch.object(self.launcher, "_download", side_effect=download):
            with self.assertRaises(Cancelled):
                self.launcher.install(cancel, lambda _: None)
        self.assertEqual((self.paths.runtime / "keep").read_text(), "old")
        self.assertEqual(list(self.paths.data.glob(".runtime-stage-*")), [])

    def test_publish_save_failure_restores_previous_runtime(self):
        self.paths.runtime.mkdir()
        (self.paths.runtime / "keep").write_text("old")
        self.launcher.settings = {"retained": 42}
        def unpack(archive, asset, bun):
            bun.parent.mkdir(parents=True)
            bun.write_text("fixture")
        def package(bun, directory, *args):
            metadata = directory / "node_modules/delegatus-cli"
            (metadata / "bin").mkdir(parents=True)
            (metadata / "bin/cli.mjs").write_text("fixture")
            (metadata / "package.json").write_text('{"version":"1.11.0"}')
        with patch("delegatus_core.platform.system", return_value="Linux"), patch("delegatus_core.platform.machine", return_value="x86_64"), patch.object(self.launcher, "_download"), patch.object(self.launcher, "_unpack_bun", side_effect=unpack), patch.object(self.launcher, "_install_package", side_effect=package), patch.object(self.launcher, "_validate", return_value=Runtime(Path("/fixture/bun"), Path("/fixture/cli"))), patch.object(self.launcher, "save_settings", side_effect=OSError("read only")):
            with self.assertRaises(OSError):
                self.launcher.install(threading.Event(), lambda _: None)
        self.assertEqual((self.paths.runtime / "keep").read_text(), "old")
        self.assertEqual(self.launcher.settings, {"retained": 42})
        self.assertEqual(list(self.paths.data.glob(".runtime-stage-*")), [])

    def test_download_hash_and_https_redirect_are_enforced(self):
        class Response(io.BytesIO):
            url = "https://release-assets.githubusercontent.com/fixture"
        class Opener:
            def open(self, *args, **kwargs):
                return Response(b"official fixture bytes")
        destination = self.root / "download.zip"
        expected = hashlib.sha256(b"official fixture bytes").hexdigest()
        with patch("delegatus_core.build_opener", return_value=Opener()):
            self.launcher._download("https://github.com/fixture", destination, expected, threading.Event())
            self.assertEqual(destination.read_bytes(), b"official fixture bytes")
            with self.assertRaises(LauncherError):
                self.launcher._download("https://github.com/fixture", destination, "0" * 64, threading.Event())
        with self.assertRaises(LauncherError):
            _HttpsRedirect().redirect_request(None, None, 302, "Found", {}, "http://example.invalid/file")

    def test_cancelling_owned_setup_child_stops_it(self):
        bun = self.root / "setup bun"
        bun.write_text("#!" + sys.executable + "\nimport os,time\nprint('PID='+str(os.getpid()),flush=True)\ntime.sleep(60)\n")
        bun.chmod(0o700)
        cancel = threading.Event()
        ready = threading.Event()
        log = self.paths.logs / "install.log"
        def cancel_after_child_is_ready():
            # A loaded host may take longer than an arbitrary timer to start Python.
            # Cancel only after the fixture has flushed its PID, with bounded cleanup
            # even when the fixture itself cannot start.
            deadline = time.monotonic() + 10
            try:
                while time.monotonic() < deadline and not cancel.is_set():
                    try:
                        text = log.read_text()
                    except FileNotFoundError:
                        text = ""
                    if "PID=" in text:
                        ready.set()
                        break
                    time.sleep(0.02)
            finally:
                cancel.set()
        monitor = threading.Thread(target=cancel_after_child_is_ready, daemon=True)
        monitor.start()
        try:
            with self.assertRaises(Cancelled):
                self.launcher._install_package(bun, self.root / "stage-packages", cancel, lambda _: None)
        finally:
            cancel.set()
            monitor.join(timeout=11)
        self.assertFalse(monitor.is_alive(), "child readiness monitor did not stop")
        self.assertTrue(ready.is_set(), "fixture did not report its PID within 10 seconds")
        text = log.read_text()
        pid = int(text.split("PID=")[1].splitlines()[0])
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_browser_arguments_preserve_unicode_and_spaces_without_shell(self):
        class Child:
            def poll(self): return None
        with patch("delegatus_core.shutil.which", return_value="/usr/bin/google-chrome"), patch("delegatus_core.subprocess.Popen", return_value=Child()) as launch:
            self.assertTrue(self.launcher.open_viewer())
        args, kwargs = launch.call_args
        self.assertIn("--app=http://127.0.0.1:8898/", args[0])
        self.assertIn("--user-data-dir=" + str(self.paths.data / "BrowserProfile"), args[0])
        self.assertNotIn("shell", kwargs)

    def test_changed_port_owners_are_never_signalled(self):
        original = PortOwner(123, "first", "python", os.getuid())
        replacement = PortOwner(123, "second", "python", os.getuid())
        with patch.object(self.launcher, "port_owners", return_value=[replacement]), patch("delegatus_core.os.kill") as kill:
            with self.assertRaises(LauncherError):
                self.launcher.free_port([original])
            kill.assert_not_called()

    def test_unknown_port_owner_fails_closed(self):
        proc = self.root / "proc"
        (proc / "net").mkdir(parents=True)
        (proc / "net/tcp").write_text("header\n0: 0100007F:22C2 00000000:0000 0A 0 0 0 0 0 999\n")
        with self.assertRaises(LauncherError):
            self.launcher.port_owners(proc)

    def test_proc_starttime_parses_parentheses(self):
        proc = self.root / "proc"; child = proc / "123"; child.mkdir(parents=True)
        (child / "comm").write_text("name with ) bracket\n")
        fields = ["S"] + ["0"] * 18 + ["987654"] + ["0"] * 5
        (child / "stat").write_text("123 (name with ) bracket) " + " ".join(fields))
        self.assertEqual(_identity(123, proc)[0], "987654")

    @contextlib.contextmanager
    def server(self, body, script=b"console.log('ready')", redirect=False):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if redirect:
                    self.send_response(302); self.send_header("Location", "/other"); self.end_headers(); return
                self.send_response(200); self.end_headers()
                self.wfile.write(script if self.path == "/bundle.js" else body)
            def log_message(self, *args): pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            yield "http://127.0.0.1:" + str(server.server_port) + "/"
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_readiness_checks_html_and_same_origin_script(self):
        cases = [(b'<title>Delegatus</title><script src="/bundle.js"></script>', b"ready", False, True),
                 (b'<title>Other app</title><script src="/bundle.js"></script>', b"ready", False, False),
                 (b'<title>Delegatus</title><script src="https://example.invalid/bundle.js"></script>', b"ready", False, False),
                 (b'<title>Delegatus</title><script src="/bundle.js"></script>', b"", False, False),
                 (b"Delegatus", b"ready", True, False)]
        for body, script, redirect, expected in cases:
            with self.server(body, script, redirect) as viewer:
                launcher = Launcher(self.paths, viewer)
                self.assertEqual(launcher.healthy(), expected)

    @unittest.skipUnless(platform.system() == "Linux", "requires Linux /proc and process sessions")
    def test_real_linux_listener_identity_and_verified_release(self):
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
            self.skipTest("kernel/Python lacks pidfd")
        child = subprocess.Popen([sys.executable, "-u", "-c", "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1],flush=True);s.listen();time.sleep(60)"], stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.addCleanup(child.stdout.close)
        port = int(child.stdout.readline())
        launcher = Launcher(self.paths, "http://127.0.0.1:" + str(port) + "/")
        owners = launcher.port_owners()
        self.assertEqual([owner.pid for owner in owners], [child.pid])
        launcher.free_port(owners)
        child.wait(timeout=5)
        self.assertEqual(child.returncode, -signal.SIGTERM)

    @unittest.skipUnless(platform.system() == "Linux", "requires Linux /proc and process sessions")
    def test_real_start_stop_owned_and_reused_preservation(self):
        # A Python fixture replaces Bun only inside this disposable test runtime.
        listener = socket.socket(); listener.bind(("127.0.0.1", 0)); port = listener.getsockname()[1]; listener.close()
        runtime = self.runtime()
        server_file = self.root / "fixture_server.py"
        server_file.write_text('''import http.server,sys
port=int(sys.argv[sys.argv.index('--port')+1])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.end_headers(); self.wfile.write(b'ready' if self.path=='/bundle.js' else b'<title>Delegatus</title><script src="/bundle.js"></script>')
 def log_message(self,*args): pass
http.server.HTTPServer(('127.0.0.1',port),Handler).serve_forever()
''')
        runtime.bun.write_text("#!" + sys.executable + "\nimport os,sys\nif sys.argv[1:] == ['--version']: print('1.4.3')\nelse: os.execv(sys.executable,[sys.executable," + repr(str(server_file)) + "]+sys.argv[2:])\n")
        launcher = Launcher(self.paths, "http://127.0.0.1:" + str(port) + "/")
        self.addCleanup(lambda: launcher.owned_running() and launcher.stop())
        launcher.start(runtime, threading.Event(), lambda _: None)
        self.assertTrue(launcher.owned_running()); self.assertTrue(launcher.healthy())
        reused = Launcher(self.paths, launcher.viewer)
        reused.start(runtime, threading.Event(), lambda _: None)
        self.assertFalse(reused.owned_running())
        reused.stop()
        self.assertTrue(launcher.healthy())
        launcher.stop()
        self.assertFalse(launcher.owned_running())


if __name__ == "__main__":
    unittest.main()
