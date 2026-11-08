DELEGATUS LAUNCHER 2.0 — WINDOWS

This folder is a shareable Windows launcher. It contains no personal accounts,
chat history, API keys, cookies, or installed Bun/Delegatus runtime.

REQUIREMENTS
- 64-bit Windows 10 version 1809 (build 17763) or newer, or Windows 11.
- x64 (Intel/AMD with SSE4.2) or Windows ARM64.
- Built-in Windows PowerShell 5.1 and .NET Framework 4.7.2 or newer (included
  in Windows 10 1809 and later); standard WinForms components.
- Microsoft Edge (recommended), or Google Chrome, for a separate app window.
- Internet access and enough disk space for first-time dependency installation.
  Existing compatible Bun and Delegatus installations can be reused offline.
- Bun 1.4.0+ is required; the private installer pins Bun 1.4.3 and Delegatus 1.11.0.
  A separate Codex/Claude CLI and its own login may be needed for agent features.
  The launcher does not install or sign in to those agent tools.

HOW TO START
1. Extract the whole folder to a location you own. Keep Resources next to the CMD.
2. Double-click Delegatus.exe (the program with the icon). Do not run it as administrator.
   Start Delegatus.cmd is an optional console fallback.
3. If dependencies are missing, click Install to review the installation summary.
   Nothing is downloaded until you choose Yes in that confirmation.
   Choose Bun selects an existing bun.exe; Choose Delegatus selects its bin/cli.mjs.
4. Delegatus opens at http://127.0.0.1:8898 in its own Edge/Chrome app window.
   A small control window offers Open Delegatus, Logs, Stop own server and Exit.
   Closing the app window leaves the server alive. Exit lets you choose whether
   to stop an owned server or keep it running. A reused server is never stopped.
   Download/install/startup progress has a Cancel button.
   The optional CMD fallback has the console controls listed below.

CONTROL CONSOLE
O — open or raise the existing Delegatus app window.
L — open the Logs folder.
S — confirm stopping the server created by this control console and its children.
Q — exit; when a server belongs to this console, choose whether to stop or leave it.
Closing the browser app window leaves the server running. Closing the console
with its X button can also leave the server running; use S or Q for a clear choice.
A later launcher reuses a healthy existing server and will not stop that server.
Repeated double-clicks signal the existing control process; no second CLI starts.

WINDOWS STOP BEHAVIOUR
Windows has no Unix SIGTERM for this CLI. S or Q→Yes uses Windows taskkill only
for the verified server process tree created by this launcher. This can interrupt
active agent work. The confirmation says so before anything is stopped.
For a conflicting port, the launcher lists each owning PID, process name and start
time, asks separately, rechecks identity, then terminates only confirmed owners.
It requests no elevation and does not stop replacement/new processes silently.

PRIVATE FILES AND INSTALLATION
Files are stored under %LOCALAPPDATA%\Delegatus Launcher:
  Logs          Launcher, installer and server stdout/stderr logs.
  Runtime       Private Bun and local node_modules; no global package installation.
  BrowserProfile Dedicated local Edge/Chrome profile and website data.
  settings.json Paths selected or installed on this Windows account.
The official Delegatus application may create its normal per-user configuration,
state and agent-skill links when it starts. Those files are not in this package.
The launcher does not modify PATH permanently, shell profiles, PowerShell execution
policy, existing global Bun/Delegatus packages, or system settings.
Use the progress window Cancel button (or C in the CMD fallback) to cancel. Partial private Runtime files and logs
can remain for diagnosis; existing installations are not rolled back or deleted.
To remove launcher files, first stop its owned server and close its browser window,
then remove this extracted folder and its own LocalAppData folder. Keep any normal
Delegatus state you want to preserve. Do not delete shared Bun/agent installations.

SECURITY AND TROUBLESHOOTING
Delegatus.exe and its PowerShell resource are not Authenticode-signed. It does not disable
SmartScreen or other Windows security checks. Inspect Resources/Launch-Delegatus.ps1
and the supplied hashes before using it. Organizational security controls can block
it; ask your administrator if that happens. No policy-bypass option is included.
The CMD passes its folder through an environment variable and reads the UTF-8
PowerShell resource as an inline script block, without modifying execution policy.
Errors appear in a message box in the program. In the optional CMD fallback
errors stay visible in the console. Read them before pressing a key.
Logs may contain private application output. Do not include runtime logs, settings
or BrowserProfile when sending this package to someone else.
If no Edge/Chrome is found, you may explicitly choose the ordinary default browser.
If port 8898 is busy, review the named owner carefully before confirming termination.
If readiness fails, open Logs; the launcher verifies both Delegatus HTML and a
same-origin JavaScript response, rather than treating an occupied port as success.

VALIDATION STATUS
Prepared and statically inspected on macOS. This package has NOT been executed
on Windows, and no Windows end-to-end PASS is claimed. The source passes a PowerShell 7.6.9 AST parse on macOS; its embedded C# helpers
compile in that tool. These checks do not execute Windows APIs. Windows PowerShell 5.1,
Win32 window activation, GUI setup/cancellation and native process/file-handle
behaviour require a real Windows smoke test before a production rollout.
No Bun/Delegatus installation was executed to prepare this Windows package.

OFFICIAL SOURCES
Bun installation/platform requirements: https://bun.sh/docs/installation
Pinned release: https://github.com/oven-sh/bun/releases/tag/bun-v1.4.3
Asset SHA-256 source: https://api.github.com/repos/oven-sh/bun/releases/tags/bun-v1.4.3
Delegatus: https://github.com/Latand/delegatus
Private local package command: bun add --cwd <private-folder> --exact delegatus-cli@1.11.0
Pinned archive names/hashes: Resources/Runtime-manifest.json.
Third-party licence notices are supplied in the enclosing distribution package.
