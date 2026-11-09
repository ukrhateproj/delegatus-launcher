# Delegatus Launcher for Windows, version 2.0.1.
# Requires Windows 10 (1809+)/11, Windows PowerShell 5.1 and Edge or Chrome.
# Deliberately changes neither PowerShell policy nor global package installations.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Base = $null
$script:Log = $null
$script:OwnedServer = $null
$script:OwnedIdentity = $null
$script:BrowserWindow = [IntPtr]::Zero
$script:Mutex = $null
$script:Wake = $null
$script:OwnMutex = $false
$script:Settings = @{}
$script:Ready = $false
$script:Gui = $env:DELEGATUS_GUI -eq '1'
$script:GuiCancel = $false
$script:GuiProgress = $null
$script:GuiExitApproved = $false
if ($script:Gui) { $ProgressPreference = 'SilentlyContinue' }
$script:Viewer = [Uri]'http://127.0.0.1:8898/'
$script:DelegatusVersion = '1.11.0'
$script:BunVersion = '1.4.3'

function Log([string]$Text) {
    $line = '[' + [DateTime]::Now.ToString('s') + '] ' + $Text
    if ($script:Log) { [IO.File]::AppendAllText($script:Log, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }
}
function Confirm([string]$Text, [string]$Title = 'Delegatus Launcher') {
    return [Windows.Forms.MessageBox]::Show($Text, $Title, [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button2) -eq [Windows.Forms.DialogResult]::Yes
}
function SetFormIcon($Form) {
    $path = Join-Path $env:DELEGATUS_PACKAGE_DIR 'Resources\Delegatus.ico'
    if (Test-Path -LiteralPath $path) { try { $Form.Icon = [Drawing.Icon]::new($path) } catch {} }
}
function SetupChoice([string]$Text) {
    if (-not $script:Gui) { return (Read-Host 'Choose').Trim().ToUpperInvariant() }
    $form = [Windows.Forms.Form]::new()
    try {
        $form.Text = 'Delegatus - First-time setup'; $form.Size = [Drawing.Size]::new(650, 285)
        $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
        SetFormIcon $form
        $label = [Windows.Forms.Label]::new(); $label.Text = $Text; $label.SetBounds(20, 20, 590, 155)
        $form.Controls.Add($label)
        $script:SetupChoice = 'Q'
        $items = @(@('Install', 'I'), @('Choose Bun', 'B'), @('Choose Delegatus', 'D'), @('Cancel', 'Q'))
        for ($i = 0; $i -lt $items.Count; $i++) {
            $button = [Windows.Forms.Button]::new(); $button.Text = $items[$i][0]; $button.Tag = $items[$i][1]
            $button.SetBounds((20 + 150 * $i), 190, 140, 32)
            $button.Add_Click({ param($sender, $eventArgs) $script:SetupChoice = [string]$sender.Tag; $sender.FindForm().Close() })
            $form.Controls.Add($button)
        }
        [void]$form.ShowDialog()
        return $script:SetupChoice
    } finally { $form.Dispose() }
}
function BeginGuiProgress([string]$Text) {
    if (-not $script:Gui) { return }
    EndGuiProgress
    $script:GuiCancel = $false
    $form = [Windows.Forms.Form]::new(); $form.Text = 'Delegatus Launcher'
    $form.Size = [Drawing.Size]::new(535, 195); $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; SetFormIcon $form
    $label = [Windows.Forms.Label]::new(); $label.Text = $Text; $label.SetBounds(18, 15, 480, 46); $form.Controls.Add($label)
    $progress = [Windows.Forms.ProgressBar]::new(); $progress.Style = 'Marquee'; $progress.SetBounds(18, 68, 480, 20); $form.Controls.Add($progress)
    $button = [Windows.Forms.Button]::new(); $button.Text = 'Cancel'; $button.SetBounds(398, 102, 100, 30)
    $button.Add_Click({ $script:GuiCancel = $true }); $form.Controls.Add($button)
    $form.Add_FormClosing({ $script:GuiCancel = $true })
    $script:GuiProgress = $form; $form.Show(); [Windows.Forms.Application]::DoEvents()
}
function EndGuiProgress {
    if ($script:GuiProgress) { $script:GuiProgress.Close(); $script:GuiProgress.Dispose(); $script:GuiProgress = $null }
}
function NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW quoting. No executable paths enter shell code.
    $b = [Text.StringBuilder]::new()
    [void]$b.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]92) { $slashes++; continue }
        if ($ch -eq [char]34) {
            [void]$b.Append(('\' * (2 * $slashes + 1)))
            [void]$b.Append('"')
        } else {
            [void]$b.Append(('\' * $slashes))
            [void]$b.Append($ch)
        }
        $slashes = 0
    }
    [void]$b.Append(('\' * (2 * $slashes)))
    [void]$b.Append('"')
    return $b.ToString()
}
function NativeArguments([string[]]$Values) {
    return (($Values | ForEach-Object { NativeArgument $_ }) -join ' ')
}
function NewNativeProcess([string]$Executable, [string[]]$Values, [string]$WorkingDirectory) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = NativeArguments $Values
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $WorkingDirectory
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('LLV_', [StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith('DELEGATUS_', [StringComparison]::OrdinalIgnoreCase)) {
            $start.EnvironmentVariables.Remove($key)
        }
    }
    $start.EnvironmentVariables['NO_COLOR'] = '1'
    $start.EnvironmentVariables['BUN_INSTALL_CACHE_DIR'] = Join-Path $script:Base 'Runtime\Cache'
    $start.EnvironmentVariables['PATH'] = [IO.Path]::GetDirectoryName($Executable) + ';' + $env:PATH
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $start
    return $p
}
function RunLoggedProcess([string]$Executable, [string[]]$Values, [string]$Directory, [string]$OutputPath, [string]$ErrorPath) {
    $template = NewNativeProcess $Executable $Values $Directory
    try {
        $start = $template.StartInfo
        $block = [Text.StringBuilder]::new()
        [string[]]$keys = @($start.EnvironmentVariables.Keys)
        [Array]::Sort($keys, [StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $keys) {
            [void]$block.Append([string]$key + '=' + [string]$start.EnvironmentVariables[$key] + [char]0)
        }
        [void]$block.Append([char]0)
        # File handles belong directly to the child, not to a console pipe reader.
        $childId = [DelegatusFileProcess]::Start($Executable, ((NativeArgument $Executable) + ' ' + $start.Arguments), $Directory, $block.ToString(), $OutputPath, $ErrorPath)
        $child = Get-Process -Id $childId -ErrorAction Stop
        [void]$child.Handle
        return $child
    } finally { $template.Dispose() }
}
function ReadVersion([string]$Executable) {
    $p = NewNativeProcess $Executable @('--version') $script:Base
    try {
        [void]$p.Start()
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(5000)) { $p.Kill(); return $null }
        $text = $out.GetAwaiter().GetResult().Trim()
        [void]$err.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0 -or $text -notmatch '^(\d+\.\d+\.\d+)(?:[-+][^\s]+)?$') { return $null }
        $v = [Version]$Matches[1]
        if ($v -lt [Version]'1.4.0') { return $null }
        return $text
    } catch { return $null } finally { $p.Dispose() }
}
function ReadDelegatus([string]$Entrypoint) {
    try {
        if (-not (Test-Path -LiteralPath $Entrypoint -PathType Leaf)) { return $null }
        $entry = [IO.Path]::GetFullPath($Entrypoint)
        $package = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($entry))
        $metadata = Join-Path $package 'package.json'
        $j = [IO.File]::ReadAllText($metadata, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($j.name -ne 'delegatus-cli' -or [string]::IsNullOrWhiteSpace($j.version)) { return $null }
        if ([IO.Path]::GetFileName($entry) -ne 'cli.mjs') { return $null }
        $range = '>=1.4.0'
        if ($j.PSObject.Properties['engines'] -and $j.engines -and $j.engines.PSObject.Properties['bun']) { $range = [string]$j.engines.bun }
        if ($range -notmatch '^\s*>=\s*(\d+\.\d+\.\d+)\s*$') { return $null }
        $minimum = [Version]$Matches[1]
        if ($minimum -lt [Version]'1.4.0') { $minimum = [Version]'1.4.0' }
        return [PSCustomObject]@{ Entry = $entry; Version = [string]$j.version; Package = $package; MinimumBun = $minimum }

    } catch { return $null }
}
function LoadSettings {
    $path = Join-Path $script:Base 'settings.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $j = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($prop in $j.PSObject.Properties) { $script:Settings[$prop.Name] = $prop.Value }
        } catch { Log 'Settings were unreadable; discovery will run again.' }
    }
}
function SaveSettings {
    $text = $script:Settings | ConvertTo-Json
    $path = Join-Path $script:Base 'settings.json'
    $temporary = Join-Path $script:Base ('.settings-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $text, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function IsRunningNoticeSuppressed {
    $key = 'SuppressRunningRuntimeNoticeV1'
    return $script:Settings.ContainsKey($key) -and ($script:Settings[$key] -is [bool]) -and $script:Settings[$key]
}
function SetRunningNoticeSuppressed([bool]$Suppressed) {
    $key = 'SuppressRunningRuntimeNoticeV1'
    $existed = $script:Settings.ContainsKey($key)
    $previous = $script:Settings[$key]
    try {
        $script:Settings[$key] = $Suppressed
        SaveSettings
    } catch {
        if ($existed) { $script:Settings[$key] = $previous }
        else { $script:Settings.Remove($key) }
        throw
    }
}
function ShowRunningNotice($Owner) {
    if (-not $script:Ready -or (IsRunningNoticeSuppressed)) { return }
    if ($script:OwnedServer -and $script:OwnedServer.HasExited) { return }
    $form = [Windows.Forms.Form]::new()
    try {
        $form.Text = 'Delegatus settings'
        $form.ClientSize = [Drawing.Size]::new(640, 255)
        $form.StartPosition = 'CenterParent'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false; $form.MinimizeBox = $false
        $form.ControlBox = $false; $form.ShowInTaskbar = $false
        SetFormIcon $form
        $label = [Windows.Forms.Label]::new()
        $label.Text = "Delegatus is already running. Dependencies can be changed after the server has stopped.`r`n`r`nEach user installs and connects their own Codex or Claude Code in the Delegatus setup guide."
        $label.SetBounds(18, 18, 604, 116); $form.Controls.Add($label)
        $checkbox = [Windows.Forms.CheckBox]::new()
        $checkbox.Text = 'Do not show again'; $checkbox.Checked = $false
        $checkbox.SetBounds(20, 145, 590, 26); $form.Controls.Add($checkbox)
        $ok = [Windows.Forms.Button]::new(); $ok.Text = 'OK'
        $ok.SetBounds(360, 205, 110, 32); $ok.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Controls.Add($ok); $form.AcceptButton = $ok; $form.CancelButton = $ok
        $instructions = [Windows.Forms.Button]::new(); $instructions.Text = 'Delegatus instructions'
        $instructions.SetBounds(480, 205, 142, 32); $instructions.DialogResult = [Windows.Forms.DialogResult]::Yes
        $form.Controls.Add($instructions)
        $response = $form.ShowDialog($Owner)
        SetRunningNoticeSuppressed $checkbox.Checked
        if ($response -eq [Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath 'https://github.com/Latand/delegatus#quick-start' | Out-Null
        }
    } finally { $form.Dispose() }
}
function FindBun([Version]$Minimum = [Version]'1.4.0') {
    $paths = [Collections.Generic.List[string]]::new()
    if ($script:Settings.ContainsKey('BunPath')) { $paths.Add([string]$script:Settings['BunPath']) }
    $paths.Add((Join-Path $env:USERPROFILE '.bun\bin\bun.exe'))
    if ($env:BUN_INSTALL) { $paths.Add((Join-Path $env:BUN_INSTALL 'bin\bun.exe')) }
    $commands = @(Get-Command bun.exe -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($c in $commands) { $paths.Add($c.Source) }
    $private = Join-Path $script:Base 'Runtime\Bun'
    if (Test-Path -LiteralPath $private) {
        foreach ($file in @(Get-ChildItem -LiteralPath $private -Filter bun.exe -Recurse -File -ErrorAction SilentlyContinue)) { $paths.Add($file.FullName) }
    }
    foreach ($path in ($paths | Select-Object -Unique)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $version = ReadVersion $path
            if ($version -and [Version](($version -split '[-+]')[0]) -ge $Minimum) { return [PSCustomObject]@{ Path = $path; Version = $version } }
        }
    }
    return $null
}
function FindDelegatus {
    $paths = [Collections.Generic.List[string]]::new()
    if ($script:Settings.ContainsKey('Entrypoint')) { $paths.Add([string]$script:Settings['Entrypoint']) }
    $paths.Add((Join-Path $env:USERPROFILE '.bun\install\global\node_modules\delegatus-cli\bin\cli.mjs'))
    if ($env:BUN_INSTALL) { $paths.Add((Join-Path $env:BUN_INSTALL 'install\global\node_modules\delegatus-cli\bin\cli.mjs')) }
    if ($env:APPDATA) { $paths.Add((Join-Path $env:APPDATA 'npm\node_modules\delegatus-cli\bin\cli.mjs')) }
    foreach ($dir in ($env:PATH -split ';')) {
        if ($dir -and [IO.Directory]::Exists($dir)) {
            $paths.Add((Join-Path $dir 'node_modules\delegatus-cli\bin\cli.mjs'))
            $paths.Add((Join-Path $dir '..\install\global\node_modules\delegatus-cli\bin\cli.mjs'))
        }
    }
    $private = Join-Path $script:Base 'Runtime\Packages'
    if (Test-Path -LiteralPath $private) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $private -Directory -ErrorAction SilentlyContinue)) {
            # A cancelled package install must never be rediscovered as complete.
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'launcher-install-complete.json')) {
                $paths.Add((Join-Path $dir.FullName 'node_modules\delegatus-cli\bin\cli.mjs'))
            }
        }
    }
    foreach ($path in ($paths | Select-Object -Unique)) {
        $metadata = ReadDelegatus $path
        if ($metadata) { return $metadata }
    }
    return $null
}
function PickFile([string]$Title, [string]$Filter) {
    $picker = [Windows.Forms.OpenFileDialog]::new()
    try {
        $picker.Title = $Title; $picker.Filter = $Filter; $picker.CheckFileExists = $true
        if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { return $picker.FileName }
        return $null
    } finally { $picker.Dispose() }
}
function CancelKey {
    if ($script:Gui) { [Windows.Forms.Application]::DoEvents(); return $script:GuiCancel }
    try { if ([Console]::KeyAvailable) { return [Console]::ReadKey($true).Key -eq [ConsoleKey]::C } } catch {}
    return $false
}
function Download([string]$Url, [string]$Destination) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = [Net.WebClient]::new()
    BeginGuiProgress 'Downloading Bun 1.4.3. The archive SHA-256 will be verified before use.'
    try {
        $client.Headers['User-Agent'] = 'Delegatus-Launcher/2.0.1'
        $task = $client.DownloadFileTaskAsync([Uri]$Url, $Destination)
        $started = [DateTime]::UtcNow
        $cancelled = $false
        while (-not $task.IsCompleted) {
            Write-Progress -Activity 'Downloading verified Bun runtime' -Status 'Press C to cancel.'
            if ((CancelKey) -or ([DateTime]::UtcNow - $started).TotalMinutes -gt 10) { $cancelled = $true; $client.CancelAsync(); break }
            Start-Sleep -Milliseconds 100
        }
        if ($cancelled) { throw 'Download cancelled. No existing installation was changed.' }
        $task.GetAwaiter().GetResult()
    } finally { $client.Dispose(); EndGuiProgress; Write-Progress -Activity 'Downloading verified Bun runtime' -Completed }
}
function InstallBun {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -eq 'ARM64') {
        $asset = 'bun-windows-aarch64.zip'
        $digest = '5e8f142ef722cbc9f67dc068a166e46ee72be8307b38cac7186589d2face668f'
    } elseif ($arch -eq 'AMD64') {
        # Baseline is an official release asset for older SSE4.2-capable CPUs.
        $asset = 'bun-windows-x64-baseline.zip'
        $digest = 'd7a7d3eb216614544aab0cde2d8d9f2e4e87839bf5a30a1cd11d077f02d84e0c'
    } else { throw 'Only 64-bit Windows on x64 or ARM64 is supported.' }
    $folder = Join-Path $script:Base ('Runtime\Bun\' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $zip = Join-Path $folder 'bun.zip'
    $url = 'https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/' + $asset
    Log ('Downloading official asset ' + $asset)
    Download $url $zip
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $digest) { Remove-Item -LiteralPath $zip -Force; throw 'Bun archive SHA-256 did not match the pinned official release. Nothing from it was run.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $folder
    Remove-Item -LiteralPath $zip -Force
    $binaries = @(Get-ChildItem -LiteralPath $folder -Filter bun.exe -Recurse -File)
    if ($binaries.Count -ne 1) { throw 'Official Bun archive did not contain exactly one bun.exe.' }
    $path = $binaries[0].FullName
    $version = ReadVersion $path
    if ($version -ne $script:BunVersion) { throw ('Expected Bun ' + $script:BunVersion + '; the downloaded executable could not be verified.') }
    $script:Settings['BunPath'] = $path; SaveSettings
    return [PSCustomObject]@{ Path = $path; Version = $version }
}
function RunInstall([string]$Bun, [string]$Folder) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outPath = Join-Path $script:Base ('Logs\install-' + $stamp + '-output.log')
    $errPath = Join-Path $script:Base ('Logs\install-' + $stamp + '-errors.log')
    Log ('Installation output: ' + $outPath + ' ; ' + $errPath)
    $p = RunLoggedProcess $Bun @('add', '--cwd', $Folder, '--exact', ('delegatus-cli@' + $script:DelegatusVersion)) $Folder $outPath $errPath
    $identity = $p.StartTime.ToUniversalTime().Ticks
    BeginGuiProgress 'Installing Delegatus 1.11.0 privately. This can take several minutes.'
    try {
        $began = [DateTime]::UtcNow
        $cancelled = $false
        while (-not $p.WaitForExit(200)) {
            Write-Progress -Activity 'Installing Delegatus 1.11.0 privately' -Status 'Press C to cancel. First installation may take several minutes.'
            if ((CancelKey) -or ([DateTime]::UtcNow - $began).TotalMinutes -gt 15) { $cancelled = $true; break }
        }
        if ($cancelled) {
            if (-not $p.HasExited) { StopExactTree $p.Id $identity }
            throw 'Installation cancelled. Partial files remain only inside the private Runtime folder. Installation output was retained in Logs.'
        }
        if ($p.ExitCode -ne 0) { throw ('Delegatus installation failed (exit ' + $p.ExitCode + '). See the installation logs.') }
    } finally { $p.Dispose(); EndGuiProgress; Write-Progress -Activity 'Installing Delegatus 1.11.0 privately' -Completed }
}
function EnsureRuntime {
    while ($true) {
        $delegatus = FindDelegatus
        $requiredBun = [Version]'1.4.0'
        if ($delegatus) { $requiredBun = $delegatus.MinimumBun }
        $bun = FindBun $requiredBun
        $engineMismatch = $delegatus -and -not $bun -and $requiredBun -gt [Version]$script:BunVersion

        if ($bun -and $delegatus) {
            Log ('Runtime found. Bun ' + $bun.Version + '; Delegatus ' + $delegatus.Version + '.')
            return [PSCustomObject]@{ Bun = $bun.Path; Entry = $delegatus.Entry }
        }
        Write-Host ''
        Write-Host 'Setup required. No dependency has been downloaded automatically.'
        Write-Host ('Bun >= ' + $requiredBun.ToString() + ': ' + $(if ($bun) { $bun.Version } else { 'not found' }))
        if ($engineMismatch) { Write-Host 'The existing Delegatus requires a newer Bun. Select it with B, or I to install the pinned private Delegatus instead. The existing installation will be preserved.' }

        Write-Host ('Delegatus: ' + $(if ($delegatus) { $delegatus.Version } else { 'not found' }))
        Write-Host '[I] Install missing dependencies privately   [B] Select bun.exe   [D] Select Delegatus cli.mjs   [Q] Cancel'
        $setupText = 'No dependencies are downloaded automatically.' + "`r`n`r`nBun >= " + $requiredBun.ToString() + ': ' + $(if ($bun) { $bun.Version } else { 'not found' }) + "`r`nDelegatus: " + $(if ($delegatus) { $delegatus.Version } else { 'not found' })
        if ($engineMismatch) { $setupText += "`r`nExisting Delegatus needs a newer Bun. Choose Bun manually or install the compatible private pinned runtime. The existing package stays unchanged." }
        $choice = SetupChoice $setupText

        switch ($choice) {
            'Q' { throw 'Setup cancelled by the user.' }
            'B' {
                $path = PickFile 'Choose an existing Bun executable (1.4 or newer)' 'Bun executable (bun.exe)|bun.exe|Executables (*.exe)|*.exe'
                if ($path) {
                    if (-not (ReadVersion $path)) { throw 'The selected Bun could not run or is older than 1.4.0.' }
                    $script:Settings['BunPath'] = $path; SaveSettings
                }
            }
            'D' {
                $path = PickFile 'Choose bin\cli.mjs inside the installed delegatus-cli package' 'Delegatus entrypoint (cli.mjs)|cli.mjs'
                if ($path) {
                    if (-not (ReadDelegatus $path)) { throw 'The selected file is not bin\cli.mjs of a valid delegatus-cli package.' }
                    $script:Settings['Entrypoint'] = $path; SaveSettings
                }
            }
            'I' {
                $installPackage = -not $delegatus -or $engineMismatch
                $setupBun = $bun
                if ($engineMismatch) { $setupBun = FindBun ([Version]'1.4.0') }
                $what = @()
                if ($engineMismatch) { $what += ('Keep existing Delegatus ' + $delegatus.Version + ' unchanged; use pinned Delegatus 1.11.0 privately instead.') }
                if (-not $setupBun) { $what += 'Download official Bun 1.4.3 from github.com/oven-sh/bun and verify its pinned SHA-256.' }
                if ($installPackage) { $what += 'Download delegatus-cli 1.11.0 and its dependencies from the npm registry using Bun.' }

                $summary = ($what -join "`r`n`r`n") + "`r`n`r`nLocation: " + (Join-Path $script:Base 'Runtime') + "`r`n`r`nOnly this user's private launcher files are installed. Existing Bun/Delegatus installations, shell profiles, global packages and PowerShell policy are not changed. Internet access and disk space are required. Press C in the console to cancel while installation runs. Continue?"
                if (-not (Confirm $summary 'Install missing dependencies?')) { continue }
                if (-not $setupBun) { $setupBun = InstallBun }
                if ($installPackage) {
                    $folder = Join-Path $script:Base ('Runtime\Packages\' + [Guid]::NewGuid().ToString('N'))
                    [void][IO.Directory]::CreateDirectory($folder)
                    [IO.File]::WriteAllText((Join-Path $folder 'package.json'), '{"name":"delegatus-launcher-private-runtime","version":"1.0.0","private":true}', [Text.UTF8Encoding]::new($false))
                    RunInstall $setupBun.Path $folder
                    $entry = Join-Path $folder 'node_modules\delegatus-cli\bin\cli.mjs'
                    $metadata = ReadDelegatus $entry
                    if (-not $metadata -or $metadata.Version -ne $script:DelegatusVersion) { throw 'Installed Delegatus metadata did not match the pinned package.' }
                    $receipt = @{ version = $metadata.Version; installedAtUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
                    [IO.File]::WriteAllText((Join-Path $folder 'launcher-install-complete.json'), $receipt, [Text.UTF8Encoding]::new($false))
                    $script:Settings['Entrypoint'] = $metadata.Entry; SaveSettings
                }
            }
        }
    }
}
function GetPortOwners {
    # Get-NetTCPConnection must succeed. Access failures are never treated as free.
    $portErrors = @()
    $connections = @(Get-NetTCPConnection -LocalPort 8898 -State Listen -ErrorAction SilentlyContinue -ErrorVariable portErrors)
    if ($portErrors) {
        # Windows reports no matching instance as an error as well; distinguish it.
        $all = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
        $connections = @($all | Where-Object { $_.LocalPort -eq 8898 })
    }
    $owners = @()
    foreach ($ownerId in @($connections | Select-Object -ExpandProperty OwningProcess -Unique | Sort-Object)) {
        try {
            $p = Get-Process -Id $ownerId -ErrorAction Stop
            $owners += [PSCustomObject]@{ Id = [int]$p.Id; Name = $p.ProcessName; Started = $p.StartTime.ToUniversalTime().Ticks }
        } catch { throw ('Could not verify the identity of process ' + $ownerId + ' owning port 8898. No process was stopped.') }
    }
    return $owners
}
function OwnerKey($Owners) {
    return ((@($Owners) | Sort-Object Id | ForEach-Object { '{0}:{1}:{2}' -f $_.Id, $_.Started, $_.Name }) -join '|')
}
function ClearPort {
    $owners = @(GetPortOwners)
    if ($owners.Count -eq 0) { return $true }
    $list = ($owners | ForEach-Object { $_.Name + '  PID ' + $_.Id + '  started ' + ([DateTime]::new([long]$_.Started, [DateTimeKind]::Utc)).ToString('o') }) -join "`r`n"
    $text = "Port 8898 is used by:`r`n`r`n" + $list + "`r`n`r`nStop exactly these processes and start Delegatus? Their unsaved work may be lost. This operation terminates the listed processes on Windows. New or changed processes will not be stopped. No administrator elevation will be requested."
    if (-not (Confirm $text 'Free port 8898?')) { return $false }
    if ((OwnerKey @(GetPortOwners)) -ne (OwnerKey $owners)) { throw 'Port ownership changed. Start the launcher again to review the new owner.' }
    foreach ($owner in $owners) {
        $now = @(GetPortOwners)
        $match = @($now | Where-Object { $_.Id -eq $owner.Id -and $_.Started -eq $owner.Started -and $_.Name -eq $owner.Name })
        if ($match.Count -ne 1) { throw 'Process identity changed. No further process was stopped.' }
        Stop-Process -Id $owner.Id -Confirm:$false -ErrorAction Stop
        Log ('User approved stopping port owner ' + $owner.Name + ' PID ' + $owner.Id + '.')
    }
    $until = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $until) {
        if (@(GetPortOwners).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    }
    throw 'Port 8898 is still occupied. Close the owning application and retry. No further process was stopped.'
}
function GetHttp([Uri]$Url, [bool]$ReadBody) {
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'; $request.Proxy = $null; $request.AllowAutoRedirect = $false
        $request.Timeout = 4000; $request.ReadWriteTimeout = 4000
        $request.Headers['Cache-Control'] = 'no-cache'
        $response = $request.GetResponse()
        $body = ''
        if ($ReadBody) {
            $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
            try {
                $chars = New-Object char[] 4096; $builder = [Text.StringBuilder]::new()
                while (($count = $reader.Read($chars, 0, $chars.Length)) -gt 0) {
                    [void]$builder.Append($chars, 0, $count)
                    if ($builder.Length -gt 4194304) { throw 'Local server HTML was too large.' }
                }
                $body = $builder.ToString()
            } finally { $reader.Dispose() }
        } elseif ($response.GetResponseStream().ReadByte() -lt 0) { throw 'Local script response was empty.' }
        return [PSCustomObject]@{ Code = [int]$response.StatusCode; Text = $body }
    } finally { if ($response) { $response.Dispose() } }
}
function ViewerHealthy {
    try {
        $html = GetHttp $script:Viewer $true
        if ($html.Code -ne 200 -or $html.Text.IndexOf('Delegatus', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        $match = [Regex]::Match($html.Text, 'src=["'']([^"'']+\.js(?:\?[^"'']*)?)["'']')
        if (-not $match.Success) { return $false }
        $scriptUrl = [Uri]::new($script:Viewer, [Net.WebUtility]::HtmlDecode($match.Groups[1].Value))
        if ($scriptUrl.Scheme -ne $script:Viewer.Scheme -or $scriptUrl.Host -ne $script:Viewer.Host -or $scriptUrl.Port -ne $script:Viewer.Port) { return $false }
        $javascript = GetHttp $scriptUrl $false
        return $javascript.Code -eq 200
    } catch { return $false }
}
function StopExactTree([int]$RootId, [long]$StartTicks) {
    $p = Get-Process -Id $RootId -ErrorAction SilentlyContinue
    if (-not $p) { return }
    if ($p.StartTime.ToUniversalTime().Ticks -ne $StartTicks) { throw 'The owned process ID was reused; nothing was stopped.' }
    # Windows has no POSIX SIGTERM for this CLI. Stop only the verified tree.
    $tool = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $tool /PID $RootId /T /F | Out-Host
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $RootId -ErrorAction SilentlyContinue)) { throw 'Windows could not stop the owned process tree. See the console; no elevation was requested.' }
}
function StartServer($Runtime) {
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outPath = Join-Path $script:Base ('Logs\server-' + $stamp + '-stdout.log')
    $errPath = Join-Path $script:Base ('Logs\server-' + $stamp + '-stderr.log')
    $p = RunLoggedProcess $Runtime.Bun @($Runtime.Entry, '--port', '8898', '--hostname', '127.0.0.1', '--no-open') $script:Base $outPath $errPath
    $script:OwnedServer = $p
    $script:OwnedIdentity = $p.StartTime.ToUniversalTime().Ticks
    Log ('Started owned Delegatus CLI PID ' + $p.Id + '. Logs: ' + $outPath + ' ; ' + $errPath)
    BeginGuiProgress 'Starting Delegatus. Waiting for verified HTML and JavaScript (up to 90 seconds).'
    $until = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $until) {
        if ($p.HasExited) { throw ('Delegatus CLI exited with code ' + $p.ExitCode + '. Open the Logs folder for details.') }
        if (ViewerHealthy) { EndGuiProgress; Log 'READY: Delegatus HTML and JavaScript verified.'; return }
        Write-Progress -Activity 'Starting Delegatus' -Status 'Waiting for verified HTML and JavaScript. Press C to cancel.'
        if (CancelKey) { StopExactTree $p.Id $script:OwnedIdentity; throw 'Startup cancelled by the user.' }
        Start-Sleep -Milliseconds 500
    }
    StopExactTree $p.Id $script:OwnedIdentity
    throw 'Delegatus did not become ready within 90 seconds. Its owned process tree was stopped. Open Logs for details.'
}
function FindBrowser {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if ($root) { $paths.Add((Join-Path $root 'Microsoft\Edge\Application\msedge.exe')) }
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($root) { $paths.Add((Join-Path $root 'Google\Chrome\Application\chrome.exe')) }
    }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    foreach ($name in @('msedge.exe', 'chrome.exe')) {
        $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}
function BrowserProcessIds {
    $profile = [IO.Path]::GetFullPath((Join-Path $script:Base 'BrowserProfile')).TrimEnd([char]92)
    $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe' OR Name = 'chrome.exe'" -ErrorAction Stop)
    foreach ($process in $all) {
        if (-not $process.CommandLine) { continue }
        $m = [Regex]::Match($process.CommandLine, '(?i)(?:"--user-data-dir=([^"]+)"|--user-data-dir="([^"]+)"|--user-data-dir=([^\s"]+))')
        if (-not $m.Success) { continue }
        $selected = ''
        for ($i = 1; $i -lt $m.Groups.Count; $i++) { if ($m.Groups[$i].Success) { $selected = $m.Groups[$i].Value; break } }
        try {
            if ([IO.Path]::GetFullPath($selected).TrimEnd([char]92).Equals($profile, [StringComparison]::OrdinalIgnoreCase)) { [int]$process.ProcessId }
        } catch { continue }
    }
}
function FindBrowserWindow([IntPtr]$Prior) {
    [int[]]$allowed = @(BrowserProcessIds)
    return [DelegatusWindow]::Find($Prior, $allowed)
}
function OpenViewer {
    $handle = FindBrowserWindow $script:BrowserWindow
    if ($handle -ne [IntPtr]::Zero) { $script:BrowserWindow = $handle; [DelegatusWindow]::Activate($handle); return }
    $browser = FindBrowser
    if (-not $browser) {
        if (Confirm "Microsoft Edge or Google Chrome was not found. Open Delegatus in your default browser instead?`r`n`r`nhttp://127.0.0.1:8898/") { Start-Process -FilePath $script:Viewer.AbsoluteUri }
        return
    }
    $profile = Join-Path $script:Base 'BrowserProfile'
    $browserArgs = @(('--app=' + $script:Viewer.AbsoluteUri), ('--user-data-dir=' + $profile), '--no-first-run', '--no-default-browser-check')
    Start-Process -FilePath $browser -ArgumentList (NativeArguments $browserArgs) | Out-Null
    $until = [DateTime]::UtcNow.AddSeconds(4)
    while ([DateTime]::UtcNow -lt $until) {
        $handle = FindBrowserWindow ([IntPtr]::Zero)
        if ($handle -ne [IntPtr]::Zero) { $script:BrowserWindow = $handle; [DelegatusWindow]::Activate($handle); return }
        Start-Sleep -Milliseconds 150
    }
}
function StopOwnedServer {
    if (-not $script:OwnedServer -or $script:OwnedServer.HasExited) { Write-Host 'This launcher has no running owned server to stop.'; return }
    if (-not (Confirm "Stop the Delegatus server created by this launcher and its child processes? Active agent work in this process tree may be interrupted. The browser window can remain open but will lose its local connection." 'Stop this launcher''s server?')) { return }
    StopExactTree $script:OwnedServer.Id $script:OwnedIdentity
    $script:Ready = $false
    Log 'STOP: user requested stopping the owned Delegatus process tree.'
    Write-Host 'The owned server was stopped. Close this control window and start the launcher again to restart.'
}


function ExitAllowed {
    if ($script:OwnedServer -and -not $script:OwnedServer.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show("Stop this launcher's Delegatus server before exit?`r`n`r`nYes: terminate its process tree (active agent work may stop).`r`nNo: leave the server running.`r`nCancel: return to control.", 'Exit Delegatus Launcher', [Windows.Forms.MessageBoxButtons]::YesNoCancel, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button3)
        if ($answer -eq [Windows.Forms.DialogResult]::Cancel) { return $false }
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { StopExactTree $script:OwnedServer.Id $script:OwnedIdentity }
    }
    return $true
}
function GuiError([string]$Text) {
    Log ('GUI ERROR: ' + $Text)
    [void][Windows.Forms.MessageBox]::Show($Text + "`r`n`r`nLogs: " + (Join-Path $script:Base 'Logs'), 'Delegatus Launcher', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
}
function ShowGuiControl {
    $form = [Windows.Forms.Form]::new(); $form.Text = 'Delegatus - Control'
    $form.Size = [Drawing.Size]::new(725, 210); $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; SetFormIcon $form
    $label = [Windows.Forms.Label]::new(); $label.SetBounds(18, 18, 670, 80)
    $label.Text = $(if ($script:OwnedServer) { 'Delegatus is running in its own app window. Closing that window leaves the server running. Stop affects only the server created here.' } else { 'Using an existing Delegatus server. This control will not stop that server.' })
    $form.Controls.Add($label)
    $open = [Windows.Forms.Button]::new(); $open.Text = 'Open Delegatus'; $open.SetBounds(18, 112, 140, 32)
    $open.Add_Click({ try { if ($script:Ready) { OpenViewer } } catch { GuiError $_.Exception.Message } }); $form.Controls.Add($open)
    $logs = [Windows.Forms.Button]::new(); $logs.Text = 'Logs'; $logs.SetBounds(168, 112, 90, 32)
    $logs.Add_Click({ try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList (NativeArgument (Join-Path $script:Base 'Logs')) | Out-Null } catch { GuiError $_.Exception.Message } }); $form.Controls.Add($logs)
    $settings = [Windows.Forms.Button]::new(); $settings.Text = 'Settings'; $settings.SetBounds(268, 112, 100, 32)
    $settings.Add_Click({ param($sender, $eventArgs) try { ShowRunningNotice ($sender.FindForm()) } catch { GuiError $_.Exception.Message } }); $form.Controls.Add($settings)
    $stop = [Windows.Forms.Button]::new(); $stop.Text = 'Stop own server'; $stop.SetBounds(378, 112, 145, 32)
    $stop.Enabled = $script:OwnedServer -and -not $script:OwnedServer.HasExited
    $stop.Add_Click({ try { StopOwnedServer } catch { GuiError $_.Exception.Message } }); $form.Controls.Add($stop)
    $exitButton = [Windows.Forms.Button]::new(); $exitButton.Text = 'Exit'; $exitButton.SetBounds(558, 112, 125, 32)
    $exitButton.Add_Click({ param($sender, $eventArgs) $sender.FindForm().Close() }); $form.Controls.Add($exitButton)
    $form.Add_FormClosing({ param($sender, $eventArgs)
        try { if (-not $script:GuiExitApproved) { if (ExitAllowed) { $script:GuiExitApproved = $true } else { $eventArgs.Cancel = $true } } }
        catch { $eventArgs.Cancel = $true; GuiError $_.Exception.Message }
    })
    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 400
    $script:GuiControl = @{ Form = $form; Label = $label; Open = $open; Settings = $settings; Stop = $stop; Timer = $timer }
    $timer.Add_Tick({
        try {
            if ($script:Wake.WaitOne(0) -and $script:Ready) { OpenViewer }
            if ($script:OwnedServer -and $script:OwnedServer.HasExited -and $script:Ready) {
                $script:Ready = $false
                GuiError ('Delegatus CLI exited (code ' + $script:OwnedServer.ExitCode + ').')
            }
            if (-not $script:Ready) { $script:GuiControl.Open.Enabled = $false; $script:GuiControl.Settings.Enabled = $false; $script:GuiControl.Stop.Enabled = $false; $script:GuiControl.Label.Text = 'The owned server has stopped. Logs are available. Exit and start Delegatus again to restart.' }
        } catch { $script:GuiControl.Timer.Stop(); GuiError $_.Exception.Message }
    })
    $form.Add_Shown({ try { OpenViewer } catch { GuiError $_.Exception.Message } })
    try { $timer.Start(); [Windows.Forms.Application]::Run($form) }
    finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    if ($PSVersionTable.PSVersion -lt [Version]'5.1') { throw 'Windows PowerShell 5.1 or newer is required.' }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) { throw '64-bit Windows 10 (1809+) or Windows 11 is required.' }
    $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ([int]$os.CurrentBuildNumber -lt 17763) { throw 'Bun requires Windows 10 version 1809 (build 17763) or newer.' }
    if (-not $script:Gui) { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
    $script:Base = Join-Path $env:LOCALAPPDATA 'Delegatus Launcher'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:Base 'Logs'))
    $script:Log = Join-Path $script:Base ('Logs\launcher-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + $PID + '.log')
    if (-not $script:Gui) { [Console]::Title = 'Delegatus Launcher - Control (keep open while using the server)' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:Wake = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, ('Local\DelegatusLauncher2-Wake-' + $sid))
    $script:Mutex = [Threading.Mutex]::new($false, ('Local\DelegatusLauncher2-Mutex-' + $sid))
    try { $script:OwnMutex = $script:Mutex.WaitOne(0, $false) } catch [Threading.AbandonedMutexException] { $script:OwnMutex = $true }
    if (-not $script:OwnMutex) {
        [void]$script:Wake.Set()
        Write-Host 'Delegatus Launcher is already open. Its existing window was requested; no second server was started.'
        exit 0
    }
    Log 'Windows launcher 2.0.1 started. No automatic installation.'
    LoadSettings
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class DelegatusWindow {
    private delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr p);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int command);
    private static bool Matches(IntPtr h, int[] allowed) {
        if (!IsWindow(h) || !IsWindowVisible(h)) return false;
        StringBuilder text = new StringBuilder(1024);
        GetWindowText(h, text, text.Capacity);
        if (text.ToString().IndexOf("Delegatus", StringComparison.OrdinalIgnoreCase) < 0) return false;
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (Array.IndexOf(allowed, (int)pid) < 0) return false;
        try {
            string name = Process.GetProcessById((int)pid).ProcessName;
            return String.Equals(name, "msedge", StringComparison.OrdinalIgnoreCase) || String.Equals(name, "chrome", StringComparison.OrdinalIgnoreCase);
        } catch { return false; }
    }
    public static IntPtr Find(IntPtr prior, int[] allowed) {
        if (prior != IntPtr.Zero && Matches(prior, allowed)) return prior;
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) { if (Matches(h, allowed)) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
    public static void Activate(IntPtr h) { ShowWindow(h, 9); SetForegroundWindow(h); }
}
public static class DelegatusFileProcess {
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfo {
        public int Size; public string Reserved; public string Desktop; public string Title;
        public int X; public int Y; public int XSize; public int YSize; public int XChars; public int YChars; public int Fill;
        public int Flags; public short Show; public short ReservedSize; public IntPtr ReservedData;
        public IntPtr Input; public IntPtr Output; public IntPtr Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process; public IntPtr Thread; public int Id; public int ThreadId; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateFile(string path, uint access, uint share, ref SecurityAttributes attributes, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation info);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    private static IntPtr Open(string path, uint access, uint creation) {
        SecurityAttributes sa = new SecurityAttributes(); sa.Length = Marshal.SizeOf(typeof(SecurityAttributes)); sa.Inherit = true;
        IntPtr h = CreateFile(path, access, 3, ref sa, creation, 0x80, IntPtr.Zero);
        if (h == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cannot open launcher log or NUL device.");
        return h;
    }
    public static int Start(string application, string command, string directory, string environmentBlock, string outputPath, string errorPath) {
        IntPtr input = IntPtr.Zero, output = IntPtr.Zero, error = IntPtr.Zero, env = IntPtr.Zero;
        try {
            input = Open("NUL", 0x80000000, 3);
            output = Open(outputPath, 0x40000000, 1); // CREATE_NEW: never overwrite another log.
            error = Open(errorPath, 0x40000000, 1);
            env = Marshal.StringToHGlobalUni(environmentBlock);
            StartupInfo si = new StartupInfo(); si.Size = Marshal.SizeOf(typeof(StartupInfo)); si.Flags = 0x100; si.Input = input; si.Output = output; si.Error = error;
            ProcessInformation pi;
            if (!CreateProcess(application, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true, 0x08000400, env, directory, ref si, out pi))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not start Delegatus.");
            CloseHandle(pi.Thread); CloseHandle(pi.Process);
            return pi.Id;
        } finally {
            if (input != IntPtr.Zero) CloseHandle(input);
            if (output != IntPtr.Zero) CloseHandle(output);
            if (error != IntPtr.Zero) CloseHandle(error);
            if (env != IntPtr.Zero) Marshal.FreeHGlobal(env);
        }
    }
}
'@
    Write-Host 'Delegatus Launcher 2.0.1 - Windows'
    Write-Host ('Logs and private runtime: ' + $script:Base)
    Write-Host 'No personal configuration is included in this package.'
    if (ViewerHealthy) {
        Log 'REUSED: existing Delegatus HTML and JavaScript verified; this server will not be stopped by this launcher.'
        Write-Host 'Using an existing healthy Delegatus server. This launcher will not stop it.'
    } else {
        # Finish dependency setup before asking to interrupt another process.
        $runtime = EnsureRuntime
        if (ViewerHealthy) { Log 'REUSED: a healthy server appeared during setup.' }
        else {
            if (@(GetPortOwners).Count -gt 0 -and -not (ClearPort)) { throw 'Port operation cancelled. Existing processes were left running.' }
            StartServer $runtime
        }
    }
    Write-Progress -Activity 'Starting Delegatus' -Completed
    $script:Ready = $true
    OpenViewer
    Write-Host ''
    Write-Host 'Delegatus opens in a separate Edge/Chrome app window.'
    Write-Host 'Closing that app window does not stop the server.'
    Write-Host '[O] Open/raise app window   [L] Logs   [S] Stop owned server   [Q] Exit control'
    if ($script:Gui) { ShowGuiControl }
    $done = $script:Gui
    while (-not $done) {
        if ($script:Wake.WaitOne(0)) { if ($script:Ready) { OpenViewer } }
        if ($script:OwnedServer -and $script:OwnedServer.HasExited -and $script:Ready) { throw ('The owned Delegatus CLI exited (code ' + $script:OwnedServer.ExitCode + '). See Logs.') }
        if ([Console]::KeyAvailable) {
            switch ([Console]::ReadKey($true).Key) {
                ([ConsoleKey]::O) { if ($script:Ready) { OpenViewer } else { Write-Host 'Server is stopped. Start the launcher again to restart.' } }
                ([ConsoleKey]::L) { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList (NativeArgument (Join-Path $script:Base 'Logs')) | Out-Null }
                ([ConsoleKey]::S) { StopOwnedServer }
                ([ConsoleKey]::Q) {
                    if ($script:OwnedServer -and -not $script:OwnedServer.HasExited) {
                        $answer = [Windows.Forms.MessageBox]::Show("Stop this launcher's Delegatus server before exit?`r`n`r`nYes: terminate its process tree (active agent work may stop).`r`nNo: leave the server running.`r`nCancel: return to control.", 'Exit Delegatus Launcher', [Windows.Forms.MessageBoxButtons]::YesNoCancel, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button3)
                        if ($answer -eq [Windows.Forms.DialogResult]::Cancel) { break }
                        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { StopExactTree $script:OwnedServer.Id $script:OwnedIdentity }
                    }
                    $done = $true
                }
            }
        }
        Start-Sleep -Milliseconds 150
    }
} catch {
    $failureText = $_.Exception.Message
    try { EndGuiProgress } catch {}
    if ($script:Gui) {
        try {
            $details = $failureText
            if ($script:Base) { $details += "`r`n`r`nLogs: " + (Join-Path $script:Base 'Logs') }
            [void][Windows.Forms.MessageBox]::Show($details, 'Delegatus Launcher error', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
        } catch {}
    }
    if ($script:Log) { try { Log ('ERROR: ' + $failureText) } catch {} }
    Write-Host ''
    Write-Host ('ERROR: ' + $failureText) -ForegroundColor Red
    if ($script:Base) { Write-Host ('Logs: ' + (Join-Path $script:Base 'Logs')) }
    Write-Host 'Existing external servers and installations are not stopped automatically.'
    exit 1
} finally {
    # Closing control alone leaves the server alive. Only explicit S/Q-Yes stops it.
    if ($script:OwnMutex -and $script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
    if ($script:Mutex) { $script:Mutex.Dispose() }
    if ($script:Wake) { $script:Wake.Dispose() }
}
