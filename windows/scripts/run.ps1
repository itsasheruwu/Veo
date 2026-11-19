param([ValidateSet('x64','ARM64')][string]$Architecture='x64',[ValidateSet('Debug','Release')][string]$Configuration='Debug')
$ErrorActionPreference='Stop'
$windowsRoot=Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $windowsRoot
try {
    $project = 'src\Veo.Windows\Veo.Windows.csproj'
    $rid = 'win-' + $Architecture.ToLowerInvariant()
    $build = Join-Path $windowsRoot "src\Veo.Windows\bin\$Architecture\$Configuration\net10.0-windows10.0.26100.0\$rid\Veo.Windows.dll"
    if (!(Test-Path -LiteralPath $build -PathType Leaf)) { throw 'Build the selected Veo configuration before launching it.' }
    & dotnet msbuild $project -t:RunPackagedApp -m:1 "-p:Platform=$Architecture" "-p:Configuration=$Configuration" -v:minimal
    if ($LASTEXITCODE -ne 0) { throw 'Veo package activation failed. Verify Developer Mode and WinApp registration permissions.' }
} finally { Pop-Location }
