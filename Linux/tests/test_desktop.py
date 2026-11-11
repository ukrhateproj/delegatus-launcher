"""Desktop installation tests; GLib launch and Tk smoke run on Linux under Xvfb."""
import importlib.util
import os
import queue
import threading
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock

LINUX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LINUX))
from delegatus import Controller, SingleInstance


class DesktopInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="delegatus-desktop-")
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        shutil.copy2(LINUX / "install.sh", self.source / "install.sh")
        for name in ("LICENSE.txt", "THIRD_PARTY_NOTICES.txt", "Delegatus-LICENSE.txt"):
            shutil.copy2(LINUX / name, self.source / name)
        (self.source / "delegatus.py").write_text("# fixture\n")
        (self.source / "delegatus_core.py").write_text("# fixture\n")
        (self.source / "Resources").mkdir()
        (self.source / "Resources/delegatus.png").write_bytes(b"test icon")
        (self.source / "launch.sh").write_text('#!/bin/sh\nprintf "%s\\n" "$0" > "$DELEGATUS_DESKTOP_TEST_MARKER"\n')
        self.data = self.base / "data Олег O'Neil % dollar$ slash\\ quote\" tick` ="
        self.env = dict(os.environ, XDG_DATA_HOME=str(self.data),
                        PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"))
        self.desktop = self.data / "applications/org.delegatus.community-launcher.desktop"

    def tearDown(self):
        self.temp.cleanup()

    def install(self):
        return subprocess.run(["/bin/sh", str(self.source / "install.sh")], env=self.env, capture_output=True, text=True)

    def test_install_and_upgrade_preserve_running_copy(self):
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stderr)
        first_desktop = self.desktop.read_text()
        release = list((self.data / "delegatus-launcher/app").glob("2.0.1-*"))[0]
        self.assertTrue((release / "launch.sh").is_file())
        second = self.install()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotEqual(first_desktop, self.desktop.read_text())
        self.assertTrue((release / "launch.sh").is_file(), "a running previous copy must remain intact")
        self.assertIn("Terminal=false", self.desktop.read_text())
        self.assertIn("StartupWMClass=Delegatus", self.desktop.read_text())
        self.assertIn("%%", self.desktop.read_text())

    def test_unrelated_desktop_is_not_overwritten(self):
        self.desktop.parent.mkdir(parents=True)
        self.desktop.write_text("[Desktop Entry]\nType=Application\nName=Mine\nExec=/bin/true\n")
        before = self.desktop.read_bytes()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.desktop.read_bytes(), before)
        self.assertFalse((self.data / "delegatus-launcher/app").exists())

    def test_unrelated_app_directory_is_not_overwritten(self):
        destination = self.data / "delegatus-launcher/app"
        destination.mkdir(parents=True)
        (destination / "mine.txt").write_text("keep")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((destination / "mine.txt").read_text(), "keep")
        self.assertFalse(self.desktop.exists())

    def test_incomplete_folder_cannot_install(self):
        (self.source / "delegatus_core.py").unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.desktop.exists())

    def test_desktop_file_validate(self):
        if not shutil.which("desktop-file-validate"):
            if os.environ.get("CI") == "true":
                self.fail("CI requires desktop-file-utils; this check must not be skipped")
            self.skipTest("desktop-file-utils is unavailable on this host")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        validation = subprocess.run(["desktop-file-validate", str(self.desktop)], capture_output=True, text=True)
        self.assertEqual(validation.returncode, 0, validation.stderr + validation.stdout)

    def test_glib_launch_preserves_literal_unusual_path(self):
        try:
            import gi
            gi.require_version("Gio", "2.0")
            from gi.repository import Gio
        except ImportError:
            if os.environ.get("CI") == "true":
                self.fail("CI requires PyGObject/GLib; this check must not be skipped")
            self.skipTest("PyGObject/GLib is unavailable on this host")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = Gio.DesktopAppInfo.new_from_filename(str(self.desktop))
        self.assertIsNotNone(app, "GLib must parse the generated desktop entry")
        marker = self.base / "launched.txt"
        context = Gio.AppLaunchContext()
        context.setenv("DELEGATUS_DESKTOP_TEST_MARKER", str(marker))
        app.launch([], context)
        limit = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < limit:
            time.sleep(0.05)
        self.assertTrue(marker.is_file(), "desktop command must actually launch")
        expected = list((self.data / "delegatus-launcher/app").glob("2.0.1-*/launch.sh"))[0]
        self.assertEqual(marker.read_text().rstrip("\n"), str(expected))

    def test_missing_tk_error_has_visible_dialog_fallback(self):
        fakebin = self.base / "bin"
        fakebin.mkdir()
        (fakebin / "python3").write_text("#!/bin/sh\nexit 1\n")
        (fakebin / "zenity").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$DELEGATUS_DESKTOP_TEST_MARKER"\n')
        (fakebin / "python3").chmod(0o700)
        (fakebin / "zenity").chmod(0o700)
        marker = self.base / "dialog.txt"
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
                   DELEGATUS_DESKTOP_TEST_MARKER=str(marker))
        result = subprocess.run(["/bin/sh", str(LINUX / "launch.sh")], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertIn("python3-tk", marker.read_text())
        self.assertIn("pacman -S python tk", marker.read_text())


class ErrorVisibilityTests(unittest.TestCase):
    def test_failed_log_does_not_hide_error_or_leave_worker_busy(self):
        controller = object.__new__(Controller)
        controller.root = Mock()
        controller.launcher = Mock()
        controller.launcher.log.side_effect = OSError("disk full")
        controller.status = Mock()
        controller.progress = Mock()
        controller.update_buttons = Mock()
        controller.messagebox = Mock()
        controller.events = queue.Queue()
        controller.cancel = threading.Event()
        controller.busy = False
        controller.ready = False
        controller.closing = False
        controller.instance = None
        original = RuntimeError("the original task failure")
        def task():
            raise original
        controller.begin("Checking…", task)
        controller.worker.join(timeout=3)
        self.assertFalse(controller.worker.is_alive())
        kind, error, callback = controller.events.get_nowait()
        self.assertEqual(kind, "error")
        self.assertIs(error, original)
        controller.events.put((kind, error, callback))
        controller.poll()
        self.assertFalse(controller.busy)
        controller.messagebox.showerror.assert_called_once()
        self.assertEqual(controller.messagebox.showerror.call_args.args[1], str(original))


class SingleInstanceTests(unittest.TestCase):
    def test_second_click_focuses_first_without_new_controller(self):
        with tempfile.TemporaryDirectory() as directory:
            first = SingleInstance(Path(directory))
            try:
                self.assertTrue(first.acquired)
                second = SingleInstance(Path(directory))
                try:
                    self.assertFalse(second.acquired)
                    self.assertTrue(first.focused())
                    self.assertFalse(first.focused())
                finally:
                    second.close()
            finally:
                first.close()
            third = SingleInstance(Path(directory))
            try:
                self.assertTrue(third.acquired)
            finally:
                third.close()


class ControllerSmokeTests(unittest.TestCase):
    def test_tk_controller_setup_and_settings_are_real_widgets(self):
        try:
            import tkinter as tk
            root = tk.Tk(className="Delegatus")
        except Exception as error:
            if os.environ.get("CI") == "true" or (sys.platform == "linux" and os.environ.get("DISPLAY")):
                raise
            self.skipTest("Tk/display unavailable: " + str(error))
        with tempfile.TemporaryDirectory() as directory:
            root.withdraw()
            launcher = Mock()
            launcher.paths.logs = Path(directory)
            launcher.settings = {"retained": "keep"}
            launcher.owned_running.return_value = False
            launcher.healthy.return_value = False
            launcher.suppress_notice.return_value = False
            controller = Controller(root, launcher, auto_start=False)
            controller.inspect = lambda: None
            controller.ready = True
            controller.settings()
            root.update()
            dialogs = [widget for widget in root.winfo_children() if isinstance(widget, tk.Toplevel)]
            self.assertEqual(len(dialogs), 1)
            dialog = dialogs[0]
            def descendants(widget):
                result = []
                for child in widget.winfo_children():
                    result.append(child)
                    result.extend(descendants(child))
                return result
            from tkinter import ttk
            checkbox = next(widget for widget in descendants(dialog) if isinstance(widget, ttk.Checkbutton))
            self.assertFalse(checkbox.instate(["selected"]))
            checkbox.invoke()
            button = next(widget for widget in descendants(dialog) if isinstance(widget, ttk.Button) and widget.cget("text") == "OK")
            button.invoke()
            self.assertTrue(launcher.settings["suppress_running_notice"])
            self.assertEqual(launcher.settings["retained"], "keep")
            launcher.save_settings.assert_called_once()
            launcher.suppress_notice.return_value = True
            controller.settings()
            root.update()
            self.assertFalse([widget for widget in root.winfo_children() if isinstance(widget, tk.Toplevel)])
            controller.close()


if __name__ == "__main__":
    unittest.main()
