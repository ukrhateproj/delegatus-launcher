param(
    [Parameter(Mandatory=$true)][string]$TestDirectory,
    [string]$LauncherPath = (Join-Path $PSScriptRoot '../Windows/Resources/Launch-Delegatus.ps1'),
    [switch]$AssertPersisted
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($LauncherPath), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('LoadSettings','SaveSettings','IsRunningNoticeSuppressed','SetRunningNoticeSuppressed')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $function) { throw ('Missing notice persistence function: ' + $name) }
    Invoke-Expression $function.Extent.Text
}
function Log([string]$Text) {}
$script:Base = [IO.Path]::GetFullPath($TestDirectory)
$script:Settings = @{}
if ($AssertPersisted) {
    LoadSettings
    if (-not (IsRunningNoticeSuppressed)) { throw 'Preference did not survive a fresh PowerShell process.' }
    if ($script:Settings['BunPath'] -ne "C:\Users\Олег O'Neil\Bun\bun.exe") { throw 'BunPath changed during preference save.' }
    'PASS: preference restored in a new process'
    exit 0
}
if (Test-Path -LiteralPath $script:Base) { throw 'Supply a new test directory; existing files are not modified.' }
[void][IO.Directory]::CreateDirectory($script:Base)
$passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('FAIL: ' + $Name) }
    $script:passed++
    Write-Output ('PASS: ' + $Name)
}
Check (-not (IsRunningNoticeSuppressed)) 'fresh user sees the information notice'
$script:Settings = @{ BunPath="C:\Users\Олег O'Neil\Bun\bun.exe"; Entrypoint='C:\Delegatus\bin\cli.mjs'; RetainedField='keep' }
SetRunningNoticeSuppressed $true
Check (IsRunningNoticeSuppressed) 'checked preference suppresses the information notice'
$saved = [IO.File]::ReadAllText((Join-Path $script:Base 'settings.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
Check ($saved.SuppressRunningRuntimeNoticeV1 -is [bool] -and $saved.SuppressRunningRuntimeNoticeV1) 'JSON stores a boolean true'
Check ($saved.Entrypoint -eq 'C:\Delegatus\bin\cli.mjs' -and $saved.RetainedField -eq 'keep') 'runtime paths and unrelated settings are preserved'
$hostExecutable = (Get-Process -Id $PID).Path
& $hostExecutable -NoLogo -NoProfile -File $PSCommandPath -TestDirectory $TestDirectory -LauncherPath $LauncherPath -AssertPersisted
Check ($LASTEXITCODE -eq 0) 'preference survives a process restart and Unicode paths'
SetRunningNoticeSuppressed $false
$script:Settings = @{}; LoadSettings
Check (-not (IsRunningNoticeSuppressed)) 'unchecked preference restores the information notice'
$script:Settings['SuppressRunningRuntimeNoticeV1'] = 'false'
Check (-not (IsRunningNoticeSuppressed)) 'string false is not treated as a true flag'
$script:Settings['SuppressRunningRuntimeNoticeV1'] = 'true'
Check (-not (IsRunningNoticeSuppressed)) 'only boolean true can suppress the notice'
$script:Settings.Remove('SuppressRunningRuntimeNoticeV1')
$originalBase = $script:Base
$script:Base = Join-Path $originalBase 'missing-parent'
$failed = $false
try { SetRunningNoticeSuppressed $true } catch { $failed = $true }
Check $failed 'save failure is reported to the caller'
Check (-not (IsRunningNoticeSuppressed)) 'save failure does not suppress the notice in memory'
$script:Base = $originalBase
$script:Settings = @{}; LoadSettings
Check ($script:Settings['BunPath'] -eq "C:\Users\Олег O'Neil\Bun\bun.exe") 'failed save leaves existing user settings intact'
Check (@(Get-ChildItem -LiteralPath $script:Base -Filter '.settings-*.tmp' -File).Count -eq 0) 'temporary settings files are cleaned'
Write-Output ($passed.ToString() + ' PASS / 0 FAIL (persistence logic only; no Windows UI invoked)')
