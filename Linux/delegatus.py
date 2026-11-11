#!/usr/bin/env python3
"""Delegatus Launcher 2.0.1: Linux desktop controller (Tk on the main thread)."""
from __future__ import annotations

import fcntl
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import traceback
import webbrowser

VERSION = "2.0.1"
URL = "http://127.0.0.1:8898/"


class SingleInstance:
    """Hold a per-user advisory lock; a repeated launch requests window focus."""

    def __init__(self, state: Path):
        self.state = state
        self.wake = state / "controller.wake"
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        self.fd = os.open(state / "controller.lock", flags, 0o600)
        self.acquired = False
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.acquired = True
        except BlockingIOError:
            self.request_focus()
        self.last_wake = self.wake.stat().st_mtime_ns if self.wake.exists() else 0

    def request_focus(self):
        temporary = self.state / (".wake-" + str(os.getpid()))
        try:
            with open(temporary, "x", encoding="ascii") as stream:
                os.chmod(temporary, 0o600)
                stream.write(str(time.time_ns()))
            os.replace(temporary, self.wake)
        finally:
            temporary.unlink(missing_ok=True)

    def focused(self):
        try:
            stamp = self.wake.stat().st_mtime_ns
        except FileNotFoundError:
            return False
        if stamp != self.last_wake:
            self.last_wake = stamp
            return True
        return False

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class Controller:
    def __init__(self, root, launcher, instance=None, auto_start=True):
        # Lazy imports keep installation checks and desktop tests usable without Tk.
        import tkinter as tk
        from tkinter import ttk, messagebox, filedialog
        self.tk, self.ttk = tk, ttk
        self.messagebox, self.filedialog = messagebox, filedialog
        self.root, self.launcher, self.instance = root, launcher, instance
        self.events = queue.Queue()
        self.cancel = threading.Event()
        self.busy = False
        self.ready = False
        self.closing = False
        self.worker = None
        self.health_pending = False
        self.health_at = time.monotonic() + 5
        self.root.title("Delegatus — Control")
        self.root.geometry("790x325")
        self.root.minsize(720, 300)
        self.root.protocol("WM_DELETE_WINDOW", self.exit)
        icon = Path(__file__).resolve().parent / "Resources" / "delegatus.png"
        try:
            self.icon = tk.PhotoImage(file=str(icon))
            root.iconphoto(True, self.icon)
        except tk.TclError:
            self.icon = None
        frame = ttk.Frame(root, padding=20)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Delegatus", font=("Sans", 23, "bold")).pack(anchor="w")
        self.status = tk.StringVar(value="Checking Delegatus and installed dependencies…")
        ttk.Label(frame, textvariable=self.status, wraplength=740, justify="left").pack(anchor="w", pady=(12, 16), fill="x")
        self.progress = ttk.Progressbar(frame, mode="indeterminate")
        self.progress.pack(fill="x", pady=(0, 15))
        actions = ttk.Frame(frame)
        actions.pack(fill="x")
        self.buttons = {}
        commands = [("open", "Open Delegatus", self.open_viewer), ("logs", "Logs", self.logs),
                    ("settings", "Settings", self.settings), ("port", "Free port", self.free_port),
                    ("stop", "Stop own server", self.stop)]
        for column, (key, label, command) in enumerate(commands):
            button = ttk.Button(actions, text=label, command=command)
            button.grid(row=0, column=column, sticky="ew", padx=(0, 6))
            actions.columnconfigure(column, weight=1)
            self.buttons[key] = button
        setup = ttk.Frame(frame)
        setup.pack(fill="x", pady=(10, 0))
        for key, label, command in [("install", "Install dependencies", self.install),
                                    ("manual", "Choose existing files", self.manual),
                                    ("retry", "Retry", self.inspect), ("cancel", "Cancel", self.cancel_work),
                                    ("exit", "Exit", self.exit)]:
            button = ttk.Button(setup, text=label, command=command)
            button.pack(side="left", padx=(0, 7))
            self.buttons[key] = button
        self.update_buttons()
        self.root.after(100, self.poll)
        if auto_start:
            self.root.after(150, self.inspect)

    def update_buttons(self):
        for key, button in self.buttons.items():
            allowed = not self.busy
            if key == "cancel":
                allowed = self.busy
            elif key == "open":
                allowed = self.ready and not self.busy
            elif key == "stop":
                allowed = not self.busy and self.launcher.owned_running()
            elif key in ("install", "manual"):
                allowed = not self.busy and not self.ready
            elif key == "logs":
                allowed = True
            button.configure(state="normal" if allowed else "disabled")

    def log_safely(self, message):
        try:
            self.launcher.log(message)
        except Exception as error:
            try:
                print("Delegatus could not write its log: " + str(error), file=sys.stderr)
            except Exception:
                pass  # Error visibility must not depend on either log or stderr writes.

    def error(self, error):
        self.log_safely("ERROR: " + str(error))
        self.status.set(str(error) + "\nUse Logs for details.")
        self.messagebox.showerror("Delegatus", str(error), parent=self.root)

    def begin(self, action, task, done=None):
        if self.busy:
            return
        self.busy = True
        self.cancel.clear()
        self.status.set(action)
        self.progress.start(12)
        self.update_buttons()

        def work():
            try:
                result = task()
                self.events.put(("done", result, done))
            except Exception as exc:
                self.log_safely(traceback.format_exc())
                self.events.put(("error", exc, None))

        self.worker = threading.Thread(target=work, name="Delegatus task", daemon=False)
        self.worker.start()

    def note(self, text):
        self.events.put(("progress", str(text), None))

    def inspect(self):
        def task():
            if self.launcher.healthy():
                return "ready"
            runtime = self.launcher.discover()
            if runtime is None:
                return "setup"
            if self.launcher.port_owners():
                return "busy_port"
            self.launcher.start(runtime, self.cancel, self.note)
            return "ready"
        self.begin("Checking Delegatus…", task, self.inspected)

    def inspected(self, result):
        self.ready = result == "ready"
        if self.ready:
            owned = self.launcher.owned_running()
            self.status.set("Delegatus is running in its own app window.\n" +
                            ("This launcher owns the server. Closing the app window leaves it running." if owned else
                             "Using an existing server. This launcher will not stop it."))
            self.open_viewer()
        elif result == "busy_port":
            self.status.set("Port 8898 is occupied by another or unready service. Use Free port to review its owner.")
        else:
            self.status.set("Compatible dependencies were not found. Install them privately or choose existing Bun and Delegatus files.")
        self.update_buttons()

    def open_viewer(self):
        if self.busy or not self.ready:
            return
        try:
            if not self.launcher.open_viewer() and self.messagebox.askyesno(
                    "Browser needed", "No Edge, Chrome or Chromium was found. Open Delegatus in your default browser instead?", parent=self.root):
                if not webbrowser.open(URL):
                    raise RuntimeError("The default browser could not be opened. Open " + URL + " manually.")
        except Exception as exc:
            self.error(exc)

    def install(self):
        if self.busy or self.ready:
            return
        if not self.messagebox.askyesno(
                "Install private dependencies?",
                "Download Bun 1.4.3 from the official GitHub release and install Delegatus 1.11.0 from npm?\n\n"
                "The Bun archive SHA-256 is checked. Files are installed only under:\n" + str(self.launcher.paths.runtime) +
                "\n\nExisting global installations and shell profiles are preserved. Internet is required. "
                "Each user connects their own Codex or Claude Code account separately.", parent=self.root):
            return
        def task():
            runtime = self.launcher.install(self.cancel, self.note)
            if self.launcher.healthy():
                return "ready"
            if self.launcher.port_owners():
                return "busy_port"
            self.launcher.start(runtime, self.cancel, self.note)
            return "ready"
        self.begin("Installing dependencies privately…", task, self.inspected)

    def manual(self):
        if self.busy or self.ready:
            return
        bun = self.filedialog.askopenfilename(title="Choose the Bun executable", parent=self.root)
        if not bun:
            return
        cli = self.filedialog.askopenfilename(title="Choose Delegatus bin/cli.mjs", parent=self.root,
                                              filetypes=[("Delegatus entry point", "cli.mjs"), ("All files", "*")])
        if not cli:
            return
        def task():
            self.launcher.set_runtime(bun, cli)
            return True
        self.begin("Validating selected dependencies…", task, lambda _: self.inspect())

    def logs(self):
        try:
            subprocess.Popen(["xdg-open", str(self.launcher.paths.logs)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as exc:
            self.messagebox.showinfo("Delegatus logs", str(self.launcher.paths.logs) + "\n\n" + str(exc), parent=self.root)

    def settings(self):
        if self.busy:
            return
        if not self.ready:
            self.messagebox.showinfo("Delegatus settings", "Use Install dependencies or Choose existing files to set up Delegatus. Each user connects their own Codex or Claude Code.", parent=self.root)
            return
        if self.launcher.suppress_notice():
            return
        dialog = self.tk.Toplevel(self.root)
        dialog.title("Delegatus settings")
        dialog.transient(self.root)
        dialog.resizable(False, False)
        dialog.grab_set()
        frame = self.ttk.Frame(dialog, padding=20)
        frame.pack(fill="both", expand=True)
        self.ttk.Label(frame, text="Delegatus is already running. Dependencies can be changed after the server has stopped.\n\nEach user installs and connects their own Codex or Claude Code in the Delegatus setup guide.",
                       wraplength=540, justify="left").pack(anchor="w")
        checked = self.tk.BooleanVar(value=self.launcher.suppress_notice())
        self.ttk.Checkbutton(frame, text="Do not show again", variable=checked).pack(anchor="w", pady=15)
        def dismiss(instructions=False):
            key = "suppress_running_notice"
            existed = key in self.launcher.settings
            previous = self.launcher.settings.get(key)
            try:
                self.launcher.settings[key] = bool(checked.get())
                self.launcher.save_settings()
            except Exception as exc:
                if existed:
                    self.launcher.settings[key] = previous
                else:
                    self.launcher.settings.pop(key, None)
                self.error(exc)
                return
            dialog.destroy()
            if instructions:
                webbrowser.open("https://github.com/Latand/delegatus#quick-start")
        row = self.ttk.Frame(frame)
        row.pack(fill="x")
        self.ttk.Button(row, text="OK", command=dismiss).pack(side="right")
        self.ttk.Button(row, text="Delegatus instructions", command=lambda: dismiss(True)).pack(side="right", padx=8)
        dialog.protocol("WM_DELETE_WINDOW", dismiss)
        dialog.bind("<Escape>", lambda _: dismiss())

    def free_port(self):
        if self.busy:
            return
        if self.ready:
            self.messagebox.showinfo("Delegatus", "Delegatus is already running. No port needs to be freed.", parent=self.root)
            return
        def owners_ready(owners):
            if not owners:
                self.inspect()
                return
            detail = "\n".join(str(owner.pid) + " — " + owner.name for owner in owners)
            if self.messagebox.askyesno("Free port 8898?", "Port 8898 is used by:\n\n" + detail +
                    "\n\nSend a termination request to exactly these processes and retry Delegatus? Their work may be interrupted. New or changed processes will not be stopped.", parent=self.root):
                self.begin("Freeing port 8898…", lambda: self.launcher.free_port(owners), lambda _: self.inspect())
        self.begin("Checking port owners…", self.launcher.port_owners, owners_ready)

    def stop(self):
        if self.busy or not self.launcher.owned_running():
            return
        if self.messagebox.askyesno("Stop own server?", "Stop the Delegatus server started by this launcher? Active agent work may be interrupted.", parent=self.root):
            self.begin("Stopping this launcher's server…", self.launcher.stop, lambda _: self.stopped())

    def stopped(self):
        self.ready = False
        self.status.set("The owned server has stopped. Logs are available. Use Retry to start Delegatus again.")
        self.update_buttons()

    def cancel_work(self):
        if self.busy:
            self.cancel.set()
            self.status.set("Cancelling… Existing completed dependencies will be retained.")
            self.buttons["cancel"].configure(state="disabled")

    def exit(self):
        if self.busy:
            if self.messagebox.askyesno("Cancel current task?", "Cancel the current task? Wait for it to finish before exiting.", parent=self.root):
                self.cancel_work()
            return
        if self.launcher.owned_running():
            choice = self.messagebox.askyesnocancel("Exit Delegatus launcher?", "Stop the server started here before exiting?\n\nYes: stop own server and exit.\nNo: leave the server running and exit.", parent=self.root)
            if choice is None:
                return
            if choice:
                self.begin("Stopping own server before exit…", self.launcher.stop, lambda _: self.close())
                return
        self.close()

    def close(self):
        self.closing = True
        if self.instance:
            self.instance.close()
        self.root.destroy()

    def poll(self):
        if self.closing:
            return
        try:
            while True:
                kind, value, callback = self.events.get_nowait()
                if kind == "progress":
                    self.status.set(value)
                    continue
                if kind == "health":
                    self.health_pending = False
                    if not value and self.ready and not self.busy:
                        self.ready = False
                        self.status.set("Delegatus is no longer responding. Use Logs or Retry.")
                        self.update_buttons()
                    continue
                self.busy = False
                self.progress.stop()
                if kind == "error":
                    from delegatus_core import Cancelled
                    self.ready = False
                    if isinstance(value, Cancelled):
                        self.status.set("Cancelled. Previous completed dependencies were retained.")
                    else:
                        self.error(value)
                elif callback:
                    callback(value)
                self.update_buttons()
        except queue.Empty:
            pass
        try:
            if self.instance and self.instance.focused():
                self.root.deiconify()
                self.root.lift()
                self.root.focus_force()
                if self.ready and not self.busy:
                    self.open_viewer()
            if self.ready and not self.busy and not self.health_pending and time.monotonic() >= self.health_at:
                self.health_pending = True
                self.health_at = time.monotonic() + 5
                def check_health():
                    try:
                        value = self.launcher.healthy()
                    except Exception:
                        value = False
                    self.events.put(("health", value, None))
                threading.Thread(target=check_health, name="Delegatus health", daemon=True).start()
        except Exception as exc:
            self.error(exc)
        self.root.after(500, self.poll)


def main():
    if sys.platform != "linux":
        raise RuntimeError("This launcher is for Linux. Use the Mac or Windows launcher on those systems.")
    if os.geteuid() == 0:
        raise RuntimeError("Run Delegatus as your regular desktop user, without sudo.")
    import tkinter as tk
    from delegatus_core import Launcher
    launcher = Launcher()
    launcher.paths.prepare()
    instance = SingleInstance(launcher.paths.state)
    if not instance.acquired:
        instance.close()
        return 0
    try:
        root = tk.Tk(className="Delegatus")
        controller = Controller(root, launcher, instance)
        root.report_callback_exception = lambda _type, value, _tb: controller.error(value)
        root.mainloop()
    finally:
        instance.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("Delegatus: " + str(error), file=sys.stderr)
        raise SystemExit(1)
