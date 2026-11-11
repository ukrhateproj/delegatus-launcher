# Delegatus Launcher

**Launch Delegatus like a regular app — double-click its icon.**

Delegatus Launcher opens Delegatus in a dedicated window and helps set up the
dependencies needed to run it on **macOS, Windows and Linux (Ubuntu and Arch)**.

[Delegatus](https://github.com/Latand/delegatus) is a tool for coordinating work
with AI agents, including Codex and Claude Code. This project is an unofficial
community launcher for it.

**Current version: 2.0.1 for macOS, Windows and Linux.**

## Features

- **A dedicated Delegatus window** with an application icon.
- **First-run setup:** discover compatible Bun and Delegatus installations, select
  them manually, or install missing dependencies after confirmation.
- **Per-user setup:** managed dependencies, settings and logs stay in the current
  user's folders. Existing global installations and shell profiles are preserved.
- **Launch controls:** open Delegatus, view logs and see startup errors.
- **Help with a busy port:** review the owning processes and confirm before the
  launcher stops them.
- **Reuse a running server:** connect to a healthy Delegatus server at
  `http://127.0.0.1:8898` without starting another one.

## Getting started

Fully extract the package before opening the launcher.

The ready-made universal ZIP for Mac and Windows is distributed separately.
This repository contains the source, build scripts and a **prebuilt Windows
launcher** in [`Windows/`](Windows/). To get the Windows files from GitHub, choose
**Code → Download ZIP**, extract the whole archive, then open its `Windows` folder.
Downloading `Delegatus.exe` alone is not enough: it needs the adjacent `Resources`
folder.

### macOS

1. Get the ready-made Mac package, or [build the app from source](Source/BUILD.txt).
2. Move `Delegatus.app` to Applications or `~/Applications`.
3. Open the app and follow the setup prompts if dependencies are missing.
4. Keep the icon in the Dock if you want quick access.

Requires **macOS 13 or later**. The app includes Apple Silicon and Intel binaries.
The Mac launcher interface is in Ukrainian.

### Windows

1. Keep `Delegatus.exe` and its `Resources` folder together in a folder you own.
2. Double-click `Delegatus.exe`.
3. If dependencies are missing, review and confirm the proposed installation.
4. Delegatus opens in a dedicated Edge or Chrome app window.

Requires **64-bit Windows 10 version 1809 or later, or Windows 11**, Windows
PowerShell 5.1, .NET Framework 4.7.2 or later, and Microsoft Edge or Google Chrome.
The Windows launcher interface is in English. The optional `Start Delegatus.cmd`
provides a console fallback.

### Ubuntu and Arch Linux

1. Download and fully extract the repository ZIP.
2. Open a terminal in its `Linux` directory and run `bash install.sh`.
3. Open **Delegatus** from the application menu and pin its icon if you want.
4. Review and confirm dependency setup when prompted.

Requires Python 3.10+, Tkinter and an X11 or XWayland desktop session. Ubuntu
users can install the desktop requirements with `sudo apt install python3 python3-tk`;
Arch users with `sudo pacman -S python tk`. These commands are manual; the launcher
does not run a system package manager. A Chromium-family browser provides the
separate app window. App-menu installation and managed runtime setup are per user.
See the [Linux guide](Linux/README.md) for details and test limits.

Internet access is needed when installing dependencies. The private installer
uses **Bun 1.4.3** and **Delegatus 1.11.0**, checks the Bun archive's SHA-256, and
asks for confirmation before downloading. Each user installs and connects their
own Codex or Claude Code and signs in with their own account; the launcher does
not install or sign in to those agent tools.

See the [Mac guide](docs/MAC_README_EN.txt) and
[Windows guide](Windows/README_EN.txt) for details and troubleshooting.
Linux instructions are in the [Linux guide](Linux/README.md).

## Update 2.0.1

All three launchers include a **Do not show again** checkbox for the information notice
about an already-running Delegatus server. The choice persists between launches.
It hides only that notice; installation and stop confirmations and error messages
remain visible. On Windows, the notice is available through **Settings** in the
control window.

## Validation status

- **Apple Silicon:** launch, private dependency installation, cancellation,
  the dedicated window and preference persistence were tested locally;
  19 dependency-discovery and settings checks passed.
- **Intel Mac:** the `x86_64` binary was compiled, but it has not been tested on a
  physical Intel Mac.
- **Windows:** the EXE with its icon was compiled; PowerShell syntax, embedded C#
  compilation and five argument-quoting cases were checked. All 12 notice
  preference checks passed in PowerShell on macOS. **The Windows app and its UI
  have not yet been tested on Windows.**

- **Linux:** the [Linux workflow](.github/workflows/linux.yml) runs checks on
  Ubuntu 22.04, Ubuntu 24.04 and an Arch container, including Tk under Xvfb and
  private Bun/Delegatus startup. Consult Actions for each commit's result.
  Physical Linux desktop sessions and ARM64 remain unverified.

The Mac app has an ad-hoc signature and is not notarized by Apple. The Windows EXE
is not Authenticode-signed. The recipient's system may warn or block the first
launch; see the platform guides for details.

See [`VALIDATION.json`](VALIDATION.json) for the recorded checks and their limits.

## Repository contents

- [`Source/`](Source/): launcher source, build scripts, checks and license notices.
- [`Windows/`](Windows/): prebuilt Windows launcher, resources and guides.
- [`Linux/`](Linux/): Linux launcher scripts, per-user desktop installer, icon and tests.
- [`docs/`](docs/): Mac guides in English and Ukrainian.
- [`Source/BUILD.txt`](Source/BUILD.txt): build and check instructions.

## Personal data

The repository and distribution packages exclude the author's personal accounts,
keys, projects, chat history, logs and browser profiles. Each recipient's local
runtime data remains their own; do not include it when sharing the launcher.

## License

MIT. The Delegatus logo comes from the original MIT-licensed project.
See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.txt`](THIRD_PARTY_NOTICES.txt).
