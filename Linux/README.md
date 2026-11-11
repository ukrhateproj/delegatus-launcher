# Delegatus Launcher for Linux

An unofficial Delegatus launcher for **Ubuntu and Arch Linux**, with an app-menu
icon, a graphical controller and a dedicated Chromium-family app window.
Version **2.0.1**. The launcher code uses Python's standard library; no pip packages
or system-wide Bun installation are required.

## Requirements

- A desktop session with X11 or XWayland, Python 3.10 or later, and Tkinter.
- Google Chrome, Chromium or Microsoft Edge for the dedicated app window.
  If no compatible browser is found, the launcher offers to open the default
  browser instead.
- Internet access for first-time dependency installation. Existing compatible
  Bun and Delegatus installations can be selected manually and reused.
- A supported Bun CPU: x86_64 with SSE4.2, or aarch64 on a glibc-based system.
  Official Arch Linux targets x86_64; the aarch64 installer path is provided for
  compatible Linux distributions and is not a claim of Arch Linux ARM testing.

Install missing **desktop** requirements yourself through your distribution:

Ubuntu ([official Tkinter package](https://packages.ubuntu.com/noble/python3-tk)):

```sh
sudo apt install python3 python3-tk
```

Arch ([Python](https://archlinux.org/packages/core/x86_64/python/),
[Tk](https://archlinux.org/packages/extra/x86_64/tk/)):

```sh
sudo pacman -S python tk ttf-dejavu
```

Install a supported browser through its official distribution channel if needed.
The launcher does not run apt, pacman or sudo and does not change security settings.

## Install the app icon

1. Download the repository with **Code → Download ZIP** and fully extract it.
2. In a terminal, open the extracted `Linux` directory and run:

   ```sh
   bash install.sh
   ```

3. Open **Delegatus** from the application menu. You can pin its icon to your
   desktop environment's dock or panel.
4. If Bun or Delegatus is missing, choose **Install dependencies**, review the
   proposed downloads and destination, and confirm. The installer uses private
   **Bun 1.4.3** and **Delegatus 1.11.0**; Bun's archive SHA-256 is checked.
5. Each user installs and connects their own Codex or Claude Code and signs in
   using their own account. Those agent tools and credentials are not bundled.

The app-menu install is per user and needs no administrator rights. A file manager
may require a script to be executable or trusted before double-clicking it; the
terminal command above avoids that dependency. Do not run the launcher as root.

You can also start the extracted copy with `bash launch.sh`.

## Controls

- **Open Delegatus** opens the local viewer at `http://127.0.0.1:8898`.
- **Logs** opens the launcher's logs directory.
- **Choose existing files** selects a Bun executable and Delegatus entry point.
- **Settings** explains setup before the server starts, or shows the running-server
  notice with a persistent **Do not show again** checkbox while it is running.
- **Free port** lists the owning processes and asks for confirmation. Process
  identity is checked again before sending SIGTERM; it never silently kills an
  unknown or replacement process.
- **Stop own server** affects only the server created by this controller.
- **Exit** offers to stop an owned server or leave it running. A reused server is
  not stopped. Closing the browser window leaves the server running.

A second launch wakes the existing controller instead of starting another server.
Cancellation keeps a previously completed private runtime intact. Information
notice suppression does not hide install consent, stop confirmations or errors.

## Files and privacy

The launcher follows XDG user directories. Defaults are:

- App files, private runtime and browser profile: `~/.local/share/delegatus-launcher/`.
- Settings: `~/.config/delegatus-launcher/settings.json`.
- Logs and controller state: `~/.local/state/delegatus-launcher/`.
- With Ubuntu's Chromium Snap, its separate profile is stored in
  `~/snap/chromium/common/delegatus-launcher-profile/` so it stays inside the Snap's
  permitted data directory.

Delegatus and the browser can also create their normal per-user state. Existing
global installations, shell profiles and personal browser profiles are preserved.
Do not share your runtime settings, logs, browser data or agent accounts with the
launcher files.

## Validation

The [Linux workflow](../.github/workflows/linux.yml) checks Ubuntu 22.04, Ubuntu
24.04 and an Arch Linux container. It runs core and desktop-installer tests, Tk
controller checks under Xvfb, and an explicit private Bun/Delegatus startup check.
See the repository's **Actions** tab for results for a particular commit.

An Xvfb check is not a physical GNOME/KDE/Wayland desktop test. Native ARM64,
Chromium Snap confinement and each desktop environment's dock behaviour need
receiver testing. The Linux launcher is distributed as readable scripts and a
freedesktop entry, rather than a signed binary or a `.deb`/AUR package.

MIT; the existing Delegatus logo is reused under its original MIT license.
See [LICENSE.txt](LICENSE.txt) and [third-party notices](THIRD_PARTY_NOTICES.txt).
