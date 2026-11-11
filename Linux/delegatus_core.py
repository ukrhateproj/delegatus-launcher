"""Private Linux runtime and process management for Delegatus Launcher.

No GUI dependencies and no package-manager or privileged system changes.
"""
from __future__ import annotations

from dataclasses import dataclass
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import threading
import time
from urllib.parse import urljoin, urlsplit
from urllib.error import HTTPError
from urllib.request import build_opener, HTTPRedirectHandler, ProxyHandler, Request
import zipfile

VERSION = "2.0.1"
BUN_VERSION = "1.4.3"
DELEGATUS_VERSION = "1.11.0"
ASSETS = {
    "x86_64": ("bun-linux-x64-baseline.zip", "1fc2edac843102909e3a1be1d8d9802cc6071cf074e67e88231f4ffe0f8b397b"),
    "aarch64": ("bun-linux-aarch64.zip", "efa9813da5ed72423bf847f916e8d2c47c0d776add972354026a75e10da9aa21"),
}


class LauncherError(Exception):
    pass


class Cancelled(LauncherError):
    pass


@dataclass(frozen=True)
class Runtime:
    bun: Path
    cli: Path


@dataclass(frozen=True)
class PortOwner:
    pid: int
    start: str
    name: str
    uid: int = -1


class Paths:
    def __init__(self, home: Path | None = None, env: dict | None = None):
        self.home = (home or Path.home()).absolute()
        self.env = dict(os.environ if env is None else env)
        def xdg(key, fallback):
            value = self.env.get(key, "")
            return Path(value) if value and Path(value).is_absolute() else self.home / fallback
        self.data = xdg("XDG_DATA_HOME", ".local/share") / "delegatus-launcher"
        self.config = xdg("XDG_CONFIG_HOME", ".config") / "delegatus-launcher"
        self.state = xdg("XDG_STATE_HOME", ".local/state") / "delegatus-launcher"
        self.runtime = self.data / "Runtime"
        self.logs = self.state / "Logs"
        self.settings = self.config / "settings.json"

    def prepare(self):
        for directory in (self.data, self.config, self.state, self.logs):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class _HttpsRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise LauncherError("Refused a non-HTTPS download redirect.")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def _version(text):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+][\w.-]+)?", text.strip())
    if not match:
        raise LauncherError("Invalid Bun or Delegatus version: " + text[:100])
    return tuple(int(part) for part in match.groups())


def _identity(pid: int, proc: Path = Path("/proc")) -> tuple[str, int, str]:
    folder = proc / str(pid)
    # comm may contain spaces or parentheses: starttime is field 22 after the final ')'.
    fields = (folder / "stat").read_text().rsplit(")", 1)[1].split()
    return fields[19], folder.stat().st_uid, (folder / "comm").read_text().strip()


class Launcher:
    def __init__(self, paths: Paths | None = None, viewer: str = "http://127.0.0.1:8898/"):
        self.paths = paths or Paths()
        address = urlsplit(viewer)
        if address.scheme != "http" or address.hostname != "127.0.0.1" or not address.port or address.username or address.password:
            raise LauncherError("The viewer must use an explicit local IPv4 loopback port.")
        self.viewer = viewer
        self.port = address.port
        self.paths.prepare()
        self.settings = {}
        if self.paths.settings.exists():
            try:
                self.settings = json.loads(self.paths.settings.read_text(encoding="utf-8"))
                if not isinstance(self.settings, dict):
                    raise ValueError("settings must be a JSON object")
            except (ValueError, OSError) as error:
                raise LauncherError(f"Cannot read settings. Preserve and inspect {self.paths.settings}: {error}") from error
        self._owned: subprocess.Popen | None = None
        self._owned_start: str | None = None
        self.log("Linux launcher " + VERSION + " opened. Downloads require confirmation.")

    def log(self, message):
        with (self.paths.logs / "launcher.log").open("a", encoding="utf-8") as output:
            output.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + str(message) + "\n")

    def save_settings(self):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".settings-", dir=self.paths.config, delete=False) as output:
                temporary = Path(output.name)
                os.chmod(temporary, 0o600)
                json.dump(self.settings, output, indent=2, ensure_ascii=False)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.paths.settings)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def suppress_notice(self):
        return self.settings.get("suppress_running_notice") is True

    def _environment(self, bun: Path | None = None):
        env = {key: value for key, value in self.paths.env.items()
               if not key.startswith(("LLV_", "DELEGATUS_")) and key not in
               ("BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN", "BUN_INSTALL_CACHE_DIR")}
        search = [str(self.paths.home / ".bun/bin"), str(self.paths.home / ".local/bin")]
        search += [part for part in env.get("PATH", "").split(os.pathsep) if Path(part).is_absolute()]
        search += ["/usr/local/bin", "/usr/bin", "/bin", "/snap/bin"]
        if bun:
            search.insert(0, str(bun.parent))
        env["PATH"] = os.pathsep.join(dict.fromkeys(search))
        env["NO_COLOR"] = "1"
        return env

    def _validate(self, bun: Path, cli: Path) -> Runtime:
        bun, cli = bun.resolve(), cli.resolve()
        if not bun.is_file() or not os.access(bun, os.X_OK) or cli.name != "cli.mjs" or not cli.is_file():
            raise LauncherError("Choose an executable Bun and Delegatus bin/cli.mjs.")
        try:
            meta = json.loads((cli.parent.parent / "package.json").read_text())
            if not isinstance(meta, dict) or meta.get("name") != "delegatus-cli":
                raise ValueError("incorrect package name")
            _version(meta["version"])
            engines = meta.get("engines", {})
            required = engines.get("bun", ">=1.4.0")
            match = re.fullmatch(r">=\s*(\d+\.\d+\.\d+)", required)
            if not match:
                raise ValueError("unsupported Bun requirement")
            minimum = max((1, 4, 0), _version(match.group(1)))
            result = subprocess.run([str(bun), "--version"], env=self._environment(bun),
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=4, check=True)
            if len(result.stdout) > 4096 or _version(result.stdout.decode().strip()) < minimum:
                raise ValueError("Bun does not meet the package requirement")
        except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
            raise LauncherError(f"The selected runtime is not compatible: {error}") from error
        return Runtime(bun, cli)

    def set_runtime(self, bun: str, cli: str) -> Runtime:
        runtime = self._validate(Path(bun), Path(cli))
        previous = dict(self.settings)
        self.settings.update(bun_path=str(runtime.bun), cli_path=str(runtime.cli))
        try:
            self.save_settings()
        except Exception:
            self.settings = previous
            raise
        return runtime

    def discover(self) -> Runtime | None:
        dirs = [Path(part) for part in self._environment()["PATH"].split(os.pathsep)]
        bun_install = self.paths.env.get("BUN_INSTALL", "")
        if bun_install and Path(bun_install).is_absolute():
            dirs.insert(0, Path(bun_install) / "bin")
        buns = [self.paths.runtime / "bun/bin/bun"] + [directory / "bun" for directory in dirs]
        clis = [self.paths.runtime / "packages/node_modules/delegatus-cli/bin/cli.mjs",
                self.paths.home / ".bun/install/global/node_modules/delegatus-cli/bin/cli.mjs",
                self.paths.home / ".npm-global/lib/node_modules/delegatus-cli/bin/cli.mjs"]
        global_dir = self.paths.env.get("BUN_INSTALL_GLOBAL_DIR", "")
        if global_dir and Path(global_dir).is_absolute():
            clis.append(Path(global_dir) / "node_modules/delegatus-cli/bin/cli.mjs")
        for directory in dirs:
            clis.extend([directory / "delegatus", directory.parent / "lib/node_modules/delegatus-cli/bin/cli.mjs"])
        for key, candidates in (("bun_path", buns), ("cli_path", clis)):
            saved = self.settings.get(key)
            if isinstance(saved, str) and Path(saved).is_absolute():
                candidates.insert(0, Path(saved))
        for cli in dict.fromkeys(clis):
            if not cli.is_file():
                continue
            for bun in dict.fromkeys(buns):
                if bun.is_file():
                    try:
                        return self._validate(bun, cli)
                    except LauncherError:
                        pass
        return None

    @staticmethod
    def _cancel(cancel):
        if cancel.is_set():
            raise Cancelled("Cancelled. Previously completed installations were preserved.")

    def _download(self, url, destination, digest, cancel):
        checksum = hashlib.sha256()
        total = 0
        # Official GitHub assets redirect to HTTPS release-asset storage. Follow only HTTPS.
        opener = build_opener(_HttpsRedirect())
        request = Request(url, headers={"User-Agent": "Delegatus-Launcher/" + VERSION})
        with opener.open(request, timeout=20) as response, destination.open("wb") as output:
            if urlsplit(response.url).scheme != "https":
                raise LauncherError("Refused a non-HTTPS runtime download.")
            while True:
                self._cancel(cancel)
                chunk = response.read(262144)
                if not chunk:
                    break
                total += len(chunk)
                if total > 150 * 1024 * 1024:
                    raise LauncherError("Runtime archive exceeded the download limit.")
                checksum.update(chunk)
                output.write(chunk)
        if checksum.hexdigest() != digest:
            raise LauncherError("Bun archive SHA-256 mismatch. Nothing was installed.")

    @staticmethod
    def _unpack_bun(archive: Path, asset: str, target: Path):
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                name = PurePosixPath(item.filename)
                mode = item.external_attr >> 16
                if name.is_absolute() or ".." in name.parts or "\\" in item.filename or stat.S_ISLNK(mode):
                    raise LauncherError("Refused an unsafe Bun archive entry.")
            member = source.getinfo(asset.removesuffix(".zip") + "/bun")
            if member.file_size > 300 * 1024 * 1024:
                raise LauncherError("The Bun executable exceeded the extraction limit.")
            target.parent.mkdir(parents=True)
            with source.open(member) as incoming, target.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            target.chmod(0o700)

    def _install_package(self, bun, package_dir, cancel, progress):
        package_dir.mkdir()
        (package_dir / "package.json").write_text(json.dumps({
            "name": "delegatus-community-launcher-runtime", "private": True,
            "dependencies": {"delegatus-cli": DELEGATUS_VERSION},
            "trustedDependencies": ["sharp", "unrs-resolver"]}))
        env = self._environment(bun)
        env["BUN_INSTALL_CACHE_DIR"] = str(package_dir.parent / "cache")
        with (self.paths.logs / "install.log").open("a", encoding="utf-8") as output:
            child = subprocess.Popen([str(bun), "install", "--cwd", str(package_dir), "--no-progress"],
                                     env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            started = time.monotonic()
            try:
                while child.poll() is None:
                    self._cancel(cancel)
                    if time.monotonic() - started > 900:
                        raise LauncherError("Dependency installation timed out; see install.log.")
                    time.sleep(0.1)
            except BaseException:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        # Only this newly-created setup session is eligible for forced cancellation.
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=3)
                raise
            if child.returncode:
                raise LauncherError("Delegatus installation failed; see install.log.")

    def install(self, cancel: threading.Event, progress) -> Runtime:
        """Caller must first obtain explicit installation consent."""
        self._cancel(cancel)
        if platform.system() != "Linux" or platform.machine() not in ASSETS:
            raise LauncherError("Private setup supports glibc Linux x86_64 or aarch64 only.")
        lock = (self.paths.data / ".setup.lock").open("a")
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise LauncherError("Another private runtime setup is already running.") from error
            with tempfile.TemporaryDirectory(prefix=".runtime-stage-", dir=self.paths.data) as work:
                work = Path(work)
                stage = work / "Runtime"
                stage.mkdir()
                asset, digest = ASSETS[platform.machine()]
                progress("Downloading Bun " + BUN_VERSION + " (verified SHA-256)…")
                self._download("https://github.com/oven-sh/bun/releases/download/bun-v" + BUN_VERSION + "/" + asset,
                               work / "bun.zip", digest, cancel)
                self._cancel(cancel)
                bun = stage / "bun/bin/bun"
                self._unpack_bun(work / "bun.zip", asset, bun)
                progress("Installing Delegatus " + DELEGATUS_VERSION + " privately…")
                self._install_package(bun, stage / "packages", cancel, progress)
                cli = stage / "packages/node_modules/delegatus-cli/bin/cli.mjs"
                self._validate(bun, cli)
                meta = json.loads((cli.parent.parent / "package.json").read_text())
                if meta["version"] != DELEGATUS_VERSION:
                    raise LauncherError("The installed Delegatus version did not match the pinned release.")
                self._cancel(cancel)
                previous_settings = dict(self.settings)
                backup = work / "previous-runtime"
                had_previous = self.paths.runtime.exists()
                published = False
                try:
                    if had_previous:
                        os.replace(self.paths.runtime, backup)
                    os.replace(stage, self.paths.runtime)
                    published = True
                    runtime = self.set_runtime(str(self.paths.runtime / "bun/bin/bun"),
                                               str(self.paths.runtime / "packages/node_modules/delegatus-cli/bin/cli.mjs"))
                except BaseException:
                    self.settings = previous_settings
                    if published:
                        os.replace(self.paths.runtime, work / "failed-runtime")
                    if backup.exists():
                        os.replace(backup, self.paths.runtime)
                    raise
                progress("Private runtime is ready.")
                return runtime
        finally:
            lock.close()

    def healthy(self) -> bool:
        opener = build_opener(ProxyHandler({}), _NoRedirect())
        def get(url, limit):
            with opener.open(Request(url, headers={"Cache-Control": "no-cache"}), timeout=1.5) as reply:
                if reply.status != 200 or reply.url != url:
                    raise ValueError("Unexpected local response")
                value = reply.read(limit + 1)
                if len(value) > limit or not value:
                    raise ValueError("Empty or oversized local response")
                return value
        try:
            document = get(self.viewer, 4 * 1024 * 1024).decode("utf-8")
            if "delegatus" not in document.lower():
                return False
            match = re.search(r'''src\s*=\s*["']([^"']+\.js(?:\?[^"']*)?)["']''', document, re.I)
            if not match:
                return False
            script = urljoin(self.viewer, html.unescape(match.group(1)))
            expected, actual = urlsplit(self.viewer), urlsplit(script)
            if (actual.scheme, actual.hostname, actual.port) != (expected.scheme, expected.hostname, expected.port) or actual.username or actual.password:
                return False
            # A script can be large; only require its first byte, not the entire bundle.
            with opener.open(script, timeout=1.5) as reply:
                return reply.status == 200 and reply.url == script and bool(reply.read(1))
        except HTTPError as error:
            error.close()
            return False
        except (OSError, ValueError, UnicodeError):
            return False

    def port_owners(self, proc: Path = Path("/proc")) -> list[PortOwner]:
        """Return all verified listener owners or fail closed if any remain unknown."""
        inodes = set()
        for filename in ("tcp", "tcp6"):
            table = proc / "net" / filename
            try:
                lines = table.read_text().splitlines()[1:]
            except FileNotFoundError:
                if filename == "tcp6":
                    continue
                raise LauncherError("Linux /proc network information is unavailable.")
            except PermissionError as error:
                raise LauncherError("Cannot inspect port ownership; close its application manually.") from error
            for line in lines:
                fields = line.split()
                if len(fields) >= 10 and fields[3] == "0A" and int(fields[1].rsplit(":", 1)[1], 16) == self.port:
                    inodes.add(fields[9])
        if not inodes:
            return []
        found = set()
        owners = []
        for directory in proc.iterdir():
            if not directory.name.isdigit():
                continue
            pid = int(directory.name)
            try:
                first = _identity(pid, proc)
                matches = set()
                for fd in (directory / "fd").iterdir():
                    try:
                        value = os.readlink(fd)
                    except (FileNotFoundError, PermissionError):
                        continue
                    match = re.fullmatch(r"socket:\[(\d+)\]", value)
                    if match and match.group(1) in inodes:
                        matches.add(match.group(1))
                if matches and _identity(pid, proc) == first:
                    owners.append(PortOwner(pid, first[0], first[2], first[1]))
                    found.update(matches)
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        if found != inodes:
            raise LauncherError("Port ownership could not be fully verified. Close the owning application manually; no process was stopped.")
        return sorted(owners, key=lambda owner: owner.pid)

    def free_port(self, owners: list[PortOwner]):
        if not owners:
            raise LauncherError("No confirmed process owners were supplied.")
        if self.port_owners() != owners:
            raise LauncherError("Port ownership changed. Nothing was stopped; review the owners again.")
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
            raise LauncherError("Safe process signalling needs Linux pidfd support. Close the owning application manually.")
        handles = []
        try:
            for owner in owners:
                if owner.uid != os.getuid():
                    raise LauncherError("The port belongs to another user. No elevation was requested; close it manually.")
                handle = os.pidfd_open(owner.pid)
                handles.append(handle)
                start, uid, _ = _identity(owner.pid)
                if (start, uid) != (owner.start, owner.uid):
                    raise LauncherError("Process identity changed; no process was stopped.")
            # All identities are verified before any SIGTERM. Handles prevent PID-reuse races.
            for handle in handles:
                signal.pidfd_send_signal(handle, signal.SIGTERM)
        finally:
            for handle in handles:
                os.close(handle)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not self.port_owners():
                return
            time.sleep(0.1)
        raise LauncherError("Port is still occupied. Close its application manually; no forced termination was attempted.")

    def owned_running(self):
        return self._owned is not None and self._owned.poll() is None

    def start(self, runtime: Runtime, cancel: threading.Event, progress):
        self._cancel(cancel)
        if self.healthy():
            return
        if self.port_owners():
            raise LauncherError("The viewer port is occupied. Use Free port to review its owner.")
        runtime = self._validate(runtime.bun, runtime.cli)
        progress("Starting Delegatus…")
        stamp = time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid())
        with (self.paths.logs / ("server-" + stamp + ".log")).open("a", encoding="utf-8") as output:
            self._owned = subprocess.Popen([str(runtime.bun), str(runtime.cli), "--port", str(self.port),
                                            "--hostname", "127.0.0.1", "--no-open"],
                                           cwd=self.paths.data, env=self._environment(runtime.bun),
                                           stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
        started = time.monotonic()
        try:
            try:
                self._owned_start = _identity(self._owned.pid)[0]
            except FileNotFoundError as error:
                self._owned.poll()
                raise LauncherError("Delegatus exited before startup identity verification. Open Logs.") from error
            while time.monotonic() - started < 60:
                self._cancel(cancel)
                if not self.owned_running():
                    raise LauncherError("Delegatus exited during startup. Open Logs for the server output.")
                if self.healthy():
                    return
                time.sleep(0.2)
            raise LauncherError("Delegatus did not become ready within 60 seconds. Open Logs.")
        except BaseException:
            self.stop()
            raise

    def stop(self):
        if not self.owned_running():
            return
        assert self._owned is not None
        start, uid, _ = _identity(self._owned.pid)
        if start != self._owned_start or uid != os.getuid() or os.getpgid(self._owned.pid) != self._owned.pid:
            raise LauncherError("The owned server identity changed; no process was stopped.")
        os.killpg(self._owned.pid, signal.SIGTERM)
        try:
            self._owned.wait(timeout=8)
        except subprocess.TimeoutExpired as error:
            raise LauncherError("The owned server did not stop after SIGTERM. See Logs; no forced stop was attempted.") from error

    def open_viewer(self) -> bool:
        env = self._environment()
        browser = next((shutil.which(name, path=env["PATH"]) for name in
                        ("microsoft-edge", "microsoft-edge-stable", "google-chrome", "google-chrome-stable", "chromium", "chromium-browser")
                        if shutil.which(name, path=env["PATH"])), None)
        if not browser:
            return False
        # Ubuntu's confined Chromium Snap cannot access arbitrary hidden XDG folders.
        # Its own common data directory is allowed by Snap confinement.
        snap_chromium = "chromium" in Path(browser).name and (
            str(Path(browser).resolve()).startswith("/snap/") or
            (Path("/snap/bin/chromium").exists() and Path(browser).name in ("chromium", "chromium-browser")))
        profile = (self.paths.home / "snap/chromium/common/delegatus-launcher-profile"
                   if snap_chromium else self.paths.data / "BrowserProfile")
        profile.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (self.paths.logs / "browser.log").open("a", encoding="utf-8") as output:
            child = subprocess.Popen([browser, "--app=" + self.viewer, "--user-data-dir=" + str(profile),
                              "--class=Delegatus", "--no-first-run", "--no-default-browser-check"],
                             env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                             start_new_session=True)
        time.sleep(0.2)
        if child.poll() not in (None, 0):
            raise LauncherError("The browser app window failed to open. See browser.log.")
        return True
