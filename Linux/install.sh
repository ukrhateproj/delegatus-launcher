#!/bin/sh
# Install a per-user application menu entry. No root privileges or package manager.
set -eu
launcher_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'Python 3.10+ is required. Install python3 on Ubuntu or python on Arch Linux, then retry.' >&2
    exit 1
fi
exec python3 - "$launcher_source" <<'PY'
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid

MARKER = 'Delegatus community launcher install v1\n'
DESKTOP_MARKER = 'X-Delegatus-Launcher-Managed=true'


def fail(message):
    raise RuntimeError(message)


def no_control(value):
    if any(ord(c) < 32 or ord(c) == 127 for c in str(value)):
        fail('Installation paths cannot contain control characters.')
    return str(value)


def desktop_arg(value):
    value = no_control(value).replace('%', '%%')
    value = ''.join(('\\' + c) if c in '"`$\\' else c for c in value)
    return '"' + value.replace('\\', '\\\\') + '"'


try:
    if sys.version_info < (3, 10):
        fail('Python 3.10 or later is required.')
    if os.geteuid() == 0:
        fail('Run this installer as your regular desktop user, without sudo.')
    try:
        import tkinter
    except ImportError:
        fail('Tk is required. Ubuntu: sudo apt install python3-tk. Arch Linux: sudo pacman -S python tk. Run this yourself, then retry.')
    source = Path(sys.argv[1]).resolve()
    data_home = Path(os.environ.get('XDG_DATA_HOME') or str(Path.home() / '.local/share'))
    if not data_home.is_absolute():
        fail('XDG_DATA_HOME must be an absolute path.')
    no_control(data_home)
    app_root = data_home / 'delegatus-launcher' / 'app'
    applications = data_home / 'applications'
    desktop = applications / 'org.delegatus.community-launcher.desktop'
    required = ('delegatus.py', 'delegatus_core.py', 'launch.sh', 'Resources/delegatus.png',
                'LICENSE.txt', 'THIRD_PARTY_NOTICES.txt', 'Delegatus-LICENSE.txt')
    for name in required:
        if not (source / name).is_file():
            fail('The whole Linux folder is required. Missing: ' + name)
    if app_root.is_symlink() or (app_root.exists() and not app_root.is_dir()):
        fail('The application destination is not an owned directory: ' + str(app_root))
    marker = app_root / '.delegatus-launcher-managed'
    if app_root.exists() and (marker.is_symlink() or not marker.is_file() or marker.read_text() != MARKER):
        fail('Refusing to replace an unrelated application directory: ' + str(app_root))
    if desktop.is_symlink() or (desktop.exists() and (not desktop.is_file() or DESKTOP_MARKER not in desktop.read_text().splitlines())):
        fail('Refusing to replace an unrelated desktop entry: ' + str(desktop))
    app_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(app_root, 0o700)
    if not marker.exists():
        marker.write_text(MARKER)
        marker.chmod(0o600)
    applications.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.install-', dir=app_root))
    release = app_root / ('2.0.1-' + uuid.uuid4().hex[:12])
    desktop_temp = None
    published = False
    try:
        for name in required:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, target)
            target.chmod(0o700 if name.endswith('.sh') else 0o600)
        # Publish a new immutable path. A running prior installation remains intact.
        stage.rename(release)
        icon = no_control(release / 'Resources/delegatus.png').replace('\\', '\\\\')
        content = '\n'.join([
            '[Desktop Entry]', 'Version=1.0', 'Type=Application', 'Name=Delegatus',
            'Comment=Launch Delegatus in its own window',
            'Exec=' + desktop_arg('/bin/sh') + ' ' + desktop_arg(release / 'launch.sh'),
            'TryExec=/bin/sh', 'Icon=' + icon, 'Terminal=false', 'Categories=Development;',
            'StartupNotify=false', 'StartupWMClass=Delegatus', DESKTOP_MARKER, ''])
        fd, temporary = tempfile.mkstemp(prefix='.delegatus-desktop-', dir=applications)
        desktop_temp = Path(temporary)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(content)
        desktop_temp.chmod(0o644)
        os.replace(desktop_temp, desktop)
        published = True
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        if desktop_temp is not None:
            desktop_temp.unlink(missing_ok=True)
        if not published and release.exists():
            shutil.rmtree(release)
    print('Installed Delegatus for this account.')
    print('Open Delegatus from your application menu, then pin its icon if desired.')
    print('Application: ' + str(release))
    print('Desktop entry: ' + str(desktop))
    print('If the menu does not refresh immediately, sign out and sign back in.')
except Exception as error:
    print('Delegatus installation failed: ' + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
