param(
 [Parameter(Mandatory=$true)][string]$ReferenceDirectory,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$SourceDirectory=$PSScriptRoot
)
$ErrorActionPreference='Stop'
# Build-only tool: PowerShell 7 with its bundled Roslyn assemblies; not required by recipients.
$ref=[IO.Path]::GetFullPath($ReferenceDirectory)
$out=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($out)
$source=[IO.File]::ReadAllText((Join-Path $SourceDirectory 'WindowsLauncher.cs'))
$tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($source)
$refs=[Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
foreach($name in @('mscorlib.dll','System.dll','System.Core.dll','System.Windows.Forms.dll','System.Drawing.dll')) {
 $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ref $name)))
}
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::WindowsApplication).WithPlatform([Microsoft.CodeAnalysis.Platform]::AnyCpu).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release)
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('Delegatus',[Microsoft.CodeAnalysis.SyntaxTree[]]@($tree),$refs,$options)
$icon=[IO.File]::OpenRead((Join-Path $out 'Resources/Delegatus.ico'))
$resource=$null; $pe=$null
try {
 $resource=$compilation.CreateDefaultWin32Resources($true,$false,$null,$icon)
 $pe=[IO.File]::Create((Join-Path $out 'Delegatus.exe'))
 $result=$compilation.Emit($pe,$null,$null,$resource)
 if(-not $result.Success){ $result.Diagnostics | ForEach-Object {Write-Host $_.ToString()}; throw 'Windows compilation failed.' }
} finally {if($pe){$pe.Dispose()};if($resource){$resource.Dispose()};$icon.Dispose()}
Write-Output 'Built Delegatus.exe: Windows GUI, AnyCPU, embedded icon, .NET Framework 4.7.2.'
