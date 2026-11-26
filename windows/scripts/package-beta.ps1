param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+-beta\.\d+$')]
    [string]$Version,
    [string]$OutputDirectory,
    [switch]$Installer,
    [string]$Vpk = 'vpk'
)
$ErrorActionPreference = 'Stop'

$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
if (!$OutputDirectory) { $OutputDirectory = Join-Path $windowsRoot 'artifacts\beta' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stage = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'Veo'
$archive = Join-Path $OutputDirectory "Veo-${Version}-Windows-x64.zip"
$setup = Join-Path $OutputDirectory "Veo-${Version}-Windows-x64-Setup.exe"
if (Test-Path -LiteralPath $archive) { throw "Release ZIP already exists at $archive" }
if ($Installer) {
    if (Test-Path -LiteralPath $setup) { throw "Release installer already exists at $setup" }
    if (!(Get-Command $Vpk -ErrorAction SilentlyContinue)) { throw 'Install vpk version 1.2.161 or supply it with -Vpk.' }
}
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
Download future portable builds from GitHub Releases, or use the installer to receive in-app updates.
'@
    $intro | Set-Content -LiteralPath (Join-Path $payload 'READ-ME.txt') -Encoding UTF8

    $archiveStage = Join-Path $stage 'beta.zip'
    tar.exe -a -cf $archiveStage -C $stage Veo
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the beta ZIP.' }
    $releaseFiles = @($archive)
    if ($Installer) {
        $channel = 'win-x64-beta'
        $installerStage = Join-Path $stage 'Installer'
        $icon = Join-Path $assets 'AppIcon.ico'
        & $Vpk pack --packId Veo.Windows --packVersion $Version --channel $channel --packDir $payload `
            --mainExe Veo.Windows.exe --packTitle Veo --packAuthors Veo --runtime win-x64 --icon $icon `
            --shortcuts StartMenuRoot --delta None --noPortable --outputDir $installerStage
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the Windows installer and update assets.' }
        $generatedSetup = @(Get-ChildItem -LiteralPath $installerStage -Filter '*-Setup.exe' -File)
        $updatePackage = @(Get-ChildItem -LiteralPath $installerStage -Filter '*-full.nupkg' -File)
        $feed = Join-Path $installerStage "releases.$channel.json"
        if ($generatedSetup.Count -ne 1 -or $updatePackage.Count -ne 1 -or !(Test-Path -LiteralPath $feed -PathType Leaf)) {
            throw 'The Windows installer, update package, or channel manifest is missing.'
        }
        Move-Item -LiteralPath $generatedSetup[0].FullName -Destination $setup
        $releaseFiles += $setup
        foreach ($asset in @($updatePackage[0].FullName, $feed)) {
            $destination = Join-Path $OutputDirectory ([IO.Path]::GetFileName($asset))
            Move-Item -LiteralPath $asset -Destination $destination -Force
            $releaseFiles += $destination
        }
        Write-Output "BETA_SETUP=$setup"
    }
    Move-Item -LiteralPath $archiveStage -Destination $archive

    $checksums = foreach ($file in $releaseFiles) {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($file))"
    }
    $checksums |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS-windows.txt') -Encoding ASCII
    Write-Output "BETA_ARCHIVE=$archive"
    Write-Output "BETA_SHA256=$($checksums[0].Split(' ')[0])"
} finally {
    Pop-Location
}
