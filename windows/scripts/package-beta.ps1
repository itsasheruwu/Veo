param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+-beta\.\d+$')]
    [string]$Version,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'

$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
if (!$OutputDirectory) { $OutputDirectory = Join-Path $windowsRoot 'artifacts\beta' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stage = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'Veo'
$archive = Join-Path $OutputDirectory "Veo-${Version}-Windows-x64.zip"
if (Test-Path -LiteralPath $archive) { throw "Release ZIP already exists at $archive" }
New-Item -ItemType Directory -Path $payload | Out-Null

$project = Join-Path $windowsRoot 'src\Veo.Windows\Veo.Windows.csproj'
$properties = @(
    '-p:Platform=x64'
    '-p:WindowsPackageType=None'
    '-p:WindowsAppSDKSelfContained=true'
    '-p:SelfContained=true'
    '-p:GenerateAppxPackageOnBuild=false'
    '-p:PublishReadyToRun=false'
    "-p:Version=$Version"
)

Push-Location -LiteralPath $windowsRoot
try {
    dotnet restore $project --locked-mode -p:Platform=x64 -m:1
    if ($LASTEXITCODE -ne 0) { throw 'The x64 beta dependencies could not be restored in locked mode.' }
    dotnet publish $project --no-restore -c Release -r win-x64 --self-contained @properties -m:1 -o $payload
    if ($LASTEXITCODE -ne 0) { throw 'The portable x64 beta build failed.' }

    $assets = Join-Path $payload 'Assets'
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $windowsRoot 'src\Veo.Windows\Assets\AppIcon.ico') -Destination $assets
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $payload
    foreach ($required in 'Veo.Windows.exe', 'Veo.Windows.pri', 'Microsoft.UI.Xaml.dll', 'coreclr.dll', 'Assets\AppIcon.ico', 'Assets\TitleBarIcon.png') {
        if (!(Test-Path -LiteralPath (Join-Path $payload $required) -PathType Leaf)) {
            throw "Portable build is missing $required."
        }
    }

    $intro = @'
Veo for Windows beta

Requires Windows 11 24H2 or later (x64) and a locally installed Codex CLI.
The optional in-app browser uses Microsoft Edge WebView2 Runtime.

Extract the entire ZIP, then open Veo.Windows.exe in the Veo folder.
This portable build is unsigned. Package-based quiet wake is unavailable.
Beta updates are downloaded manually from GitHub Releases.
'@
    $intro | Set-Content -LiteralPath (Join-Path $payload 'READ-ME.txt') -Encoding UTF8

    $archiveStage = Join-Path $stage 'beta.zip'
    tar.exe -a -cf $archiveStage -C $stage Veo
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the beta ZIP.' }
    Move-Item -LiteralPath $archiveStage -Destination $archive
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($archive))" |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS-windows.txt') -Encoding ASCII
    Write-Output "BETA_ARCHIVE=$archive"
    Write-Output "BETA_SHA256=$hash"
} finally {
    Pop-Location
}
