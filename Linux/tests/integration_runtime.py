"""Explicit network smoke check for disposable Linux CI users, never auto-run."""
from __future__ import annotations
import argparse
from pathlib import Path
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from delegatus_core import Launcher, Paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install-private-runtime', action='store_true', required=True,
                        help='Consent to download and install pinned dependencies into a temporary test directory.')
    parser.parse_args()
    if not sys.platform.startswith('linux'):
        raise SystemExit('This real process/kernel check must run on Linux.')
    with tempfile.TemporaryDirectory(prefix='delegatus-linux-integration-') as directory:
        root = Path(directory)
        paths = Paths(home=root, env={
            'PATH': '/usr/local/bin:/usr/bin:/bin',
            'XDG_DATA_HOME': str(root / 'data'),
            'XDG_CONFIG_HOME': str(root / 'config'),
            'XDG_STATE_HOME': str(root / 'state'),
        })
        launcher = Launcher(paths)
        cancel = threading.Event()
        try:
            assert not launcher.port_owners(), 'Test port 8898 is busy; nothing was stopped.'
            runtime = launcher.install(cancel, lambda message: print(message, flush=True))
            assert runtime.bun.is_file() and runtime.cli.is_file()
            assert Launcher(paths).discover() == runtime, 'Published runtime could not be rediscovered.'
            launcher.start(runtime, cancel, lambda message: print(message, flush=True))
            assert launcher.healthy(), 'Real Delegatus HTML/JS readiness failed.'
            assert launcher.owned_running(), 'The real server exited unexpectedly.'
            owners = launcher.port_owners()
            assert owners, 'Real Linux listener owner was not identified.'
            reused = Launcher(paths)
            reused.start(runtime, cancel, print)
            assert not reused.owned_running(), 'A second server was created instead of reusing the first.'
            reused.stop()
            assert launcher.healthy(), 'A reused controller stopped someone else\'s server.'
            launcher.stop()
            deadline = time.monotonic() + 5
            while launcher.healthy() and time.monotonic() < deadline:
                time.sleep(.1)
            assert not launcher.owned_running() and not launcher.healthy()
            print('PASS: real verified Bun download, private Delegatus installation, rediscovery, '
                  'Linux listener identity, HTML/JS readiness, reuse and owned stop.', flush=True)
        except BaseException:
            for log in paths.logs.glob('*.log'):
                print('\n--- ' + log.name + ' (tail) ---', file=sys.stderr)
                print(log.read_text(errors='replace')[-12000:], file=sys.stderr)
            raise
        finally:
            launcher.stop()


if __name__ == '__main__':
    main()
