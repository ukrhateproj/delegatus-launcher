Delegatus Launcher 2.0.1 — macOS

Unofficial community launcher for the open-source Delegatus project.
You may share this package. It includes no personal paths, projects,
logs, accounts or sign-in data. Windows users need the separate Windows folder.

Requirements: macOS 13 or later, Apple Silicon or Intel. The app is a universal
binary. Apple Silicon was tested locally; the Intel slice was compiled but
not run on physical Intel hardware. Internet is needed for first-time setup.

1. Extract the archive. Move Delegatus.app to Applications or ~/Applications.
2. Open the app. You may keep its icon in the Dock.
3. Existing compatible Bun and Delegatus installations are discovered.
4. If dependencies are missing, choose the explicit Install dependencies
   action in the setup window. The interface is in Ukrainian. The app explains
   the downloads and private destination before starting. It downloads
   Bun 1.4.3 from the official oven-sh/bun GitHub release and installs
   delegatus-cli 1.11.0 from npm. Bun's archive SHA256 is checked.
   You can also select your own Bun executable and Delegatus entry point.
5. Connect your own Codex or Claude Code and choose your project inside
   Delegatus. Agent CLIs and accounts are not included in this archive.
   Official setup: https://github.com/Latand/delegatus#quick-start

Managed dependencies and logs belong to the receiving user:
~/Library/Application Support/Delegatus Launcher/Runtime
~/Library/Application Support/Delegatus Launcher/Logs
Settings: ~/Library/Application Support/Delegatus Launcher/settings.json
Global installations and shell profiles are not overwritten.
Delegatus keeps its own user data in its regular user directories.

The site opens in a dedicated app window. Cmd+W closes the window while the
server keeps running. Clicking the app again restores the window. Cmd+Q sends
SIGTERM only to a server created by this launcher. An already-running healthy
server on 127.0.0.1:8898 is reused and remains running when the launcher quits.
The port-release control displays process names and IDs and asks for explicit
confirmation before terminating a conflicting process.

Signing: this build has an ad-hoc local signature, no Developer ID and no
Apple notarization. A recipient's Mac may block the first launch. If you trust
and have verified the package, consult Apple's normal instructions:
https://support.apple.com/en-us/102445
Do not disable macOS protections globally. Organization-managed Macs may have
policies that prevent running this app.

Uninstall: quit the launcher and move the app to Trash. You may separately
keep or remove its Application Support/Delegatus Launcher directory. This does
not remove Delegatus's own accounts or project files.

See LICENSE.txt and THIRD_PARTY_NOTICES.txt. Physical Windows and clean second-Mac
runtime testing were not available on the build computer.

Mac update 2.0.1 adds a persistent Do not show again checkbox to the
already-running information notice only. Install consent and errors remain visible.
