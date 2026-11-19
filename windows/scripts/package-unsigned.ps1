param(
    [ValidateSet('x64','ARM64')][string]$Architecture='x64',
    [string]$WindowsSdkVersion='10.0.26100.0'
)
$ErrorActionPreference='Stop'
$windowsRoot=Split-Path -Parent $PSScriptRoot
$repositoryRoot=Split-Path -Parent $windowsRoot
$rid='win-'+$Architecture.ToLowerInvariant()
$kit=Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin\$WindowsSdkVersion\x64"
$makeappx=Join-Path $kit 'makeappx.exe'
if (!(Test-Path -LiteralPath $makeappx -PathType Leaf)) { throw "Install Windows SDK $WindowsSdkVersion x64 packaging tools, or select an installed -WindowsSdkVersion." }
$parent=Join-Path $windowsRoot 'artifacts\unsigned-release'
[IO.Directory]::CreateDirectory($parent) | Out-Null
$run=Join-Path $parent ($Architecture.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N').Substring(0,12))
if (Test-Path -LiteralPath $run) { throw 'The new owned staging directory already exists.' }
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
$packageOutput=Join-Path $run 'packages'
$packageOutputWithSlash=$packageOutput+[IO.Path]::DirectorySeparatorChar
[IO.Directory]::CreateDirectory($packageOutput) | Out-Null
function Invoke-Checked([string]$Executable,[string[]]$Arguments,[string]$Failure,[string]$OutputLog='') {
    if ($OutputLog) { & $Executable @Arguments *> $OutputLog } else { & $Executable @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "$Failure (exit $LASTEXITCODE). Staging was preserved at $run" }
}
function Source-Inputs {
    $paths=@(& git -C $repositoryRoot ls-files --cached --others --exclude-standard -- windows)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate source inputs from this checkout.' }
    @(foreach ($path in $paths | Sort-Object -Unique) {
        if ($path -match '^windows/(src/|scripts/|Directory\.|global\.json)' -and $path -notmatch '/(bin|obj|AppPackages)/') {
            $absolute=Join-Path $repositoryRoot $path
            if (Test-Path -LiteralPath $absolute -PathType Leaf) { [pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash} }
        }
    })
}
Push-Location -LiteralPath $windowsRoot
try {
    $snapshotCommit=(& git -C $repositoryRoot rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source checkout commit.' }
    $before=Source-Inputs
    $sourceRoot=Join-Path $run 'source'
    [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    foreach ($input in $before) {
        $destination=[IO.Path]::GetFullPath((Join-Path $sourceRoot $input.Path))
        if (!$destination.StartsWith($sourceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'A source snapshot path escaped owned staging.' }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::Copy((Join-Path $repositoryRoot $input.Path),$destination,$false)
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $input.Sha256) { throw "A source file changed while being copied: $($input.Path). Rerun once that edit finishes; staging was preserved." }
    }
    $buildWindowsRoot=Join-Path $sourceRoot 'windows'
    $project=Join-Path $buildWindowsRoot 'src\Veo.Windows\Veo.Windows.csproj'
    $codex=if ($env:CODEX_EXECUTABLE) { $env:CODEX_EXECUTABLE } else { (Get-Command codex -ErrorAction Stop).Source }
    $dotnetVersion=(& dotnet --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The pinned .NET SDK could not be resolved.' }
    $codexVersion=(& $codex --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The selected Codex CLI could not be resolved.' }
    Invoke-Checked $codex @('app-server','generate-json-schema','--experimental','--out',(Join-Path $windowsRoot 'artifacts\protocol-schema')) 'Selected Codex schema export failed'
    $evaluatedRid=(& dotnet msbuild $project "-p:Platform=$Architecture" '-getProperty:RuntimeIdentifier' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $evaluatedRid -ne $rid) { throw "The selected platform evaluates to '$evaluatedRid', expected '$rid'. No lockfiles were changed." }
    Invoke-Checked 'dotnet' @('restore',$project,'--locked-mode',"-p:Platform=$Architecture",'-m:1') 'Locked release restore failed'
    Invoke-Checked 'dotnet' @('build',$project,'--no-restore','-m:1','-c','Release',"-p:Platform=$Architecture","-p:RuntimeIdentifier=$rid",'-p:SelfContained=true','-p:GenerateAppxPackageOnBuild=true','-p:AppxPackageSigningEnabled=false','-p:AppxSymbolPackageEnabled=false','-p:UapAppxPackageBuildMode=SideloadOnly','-p:AppxBundle=Never',"-p:AppxPackageDir=$packageOutputWithSlash") 'Unsigned Release MSIX build failed'
    foreach ($input in $before) { if ((Get-FileHash -LiteralPath (Join-Path $sourceRoot $input.Path) -Algorithm SHA256).Hash -ne $input.Sha256) { throw "A staged source input changed during compilation: $($input.Path). Staging was preserved." } }
    $live=Source-Inputs
    $liveMatches=($before | ConvertTo-Json -Depth 4 -Compress) -eq ($live | ConvertTo-Json -Depth 4 -Compress)
    $source=[xml](Get-Content -LiteralPath (Join-Path $buildWindowsRoot 'src\Veo.Windows\Package.appxmanifest') -Raw)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $packages=@(Get-ChildItem -LiteralPath $packageOutput -Recurse -File | Where-Object { $_.Extension -in '.msix','.appx' } | Where-Object {
        $zip=[IO.Compression.ZipFile]::OpenRead($_.FullName)
        try { $entry=$zip.GetEntry('AppxManifest.xml'); if (!$entry) { return $false }; $reader=New-Object IO.StreamReader($entry.Open()); try { $manifest=[xml]$reader.ReadToEnd(); return [string]$manifest.Package.Identity.Name -eq [string]$source.Package.Identity.Name } finally { $reader.Dispose() } }
        finally { $zip.Dispose() }
    })
    if ($packages.Count -ne 1) { throw "Expected one main unsigned MSIX, found $($packages.Count). Staging: $run" }
    $verified=& (Join-Path $buildWindowsRoot 'scripts\verify-unsigned-msix.ps1') -PackagePath $packages[0].FullName -Architecture $Architecture
    $unpacked=Join-Path $run 'sdk-validated-unpack'
    $sdkLog=Join-Path $run 'sdk-validation.log'
    Invoke-Checked $makeappx @('unpack','/p',$packages[0].FullName,'/d',$unpacked,'/no') 'SDK MSIX semantic validation failed' $sdkLog
    $liveCommit=(& git -C $repositoryRoot rev-parse HEAD | Out-String).Trim()
    $evidence=[pscustomobject]@{CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Configuration='Release';Architecture=$Architecture;RuntimeIdentifier=$rid;Dotnet=$dotnetVersion;Codex=$codexVersion;GitCommit=$snapshotCommit;LiveGitCommitAtCompletion=$liveCommit;SourceSnapshot=$sourceRoot;SourceInputs=$before;LiveSourceMatchesSnapshot=$liveMatches;MakeAppxVersion=(Get-Item -LiteralPath $makeappx).VersionInfo.FileVersion;SdkSemanticValidation=$true;SdkValidationLog=$sdkLog;Package=$verified;Limitations=@('Unsigned inspection artifact; not signed distribution.','Does not prove clean standard-user installation, upgrade, uninstall, or physical ARM64 support.','No certificate or trust-store changes, package registration, or app launch was performed.','The command workflow and locked inputs are repeatable; bit-for-bit MSIX equality across builds is not asserted.')}
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding utf8
    $before | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'source-inputs.json') -Encoding utf8
    Write-Output "Unsigned Release MSIX: $($packages[0].FullName)"
    Write-Output "SHA256: $($verified.PackageSha256)"
    Write-Output "Structural and SDK semantic verification: $(Join-Path $run 'verification.json')"
    Write-Output "Live source still matches the verified snapshot: $liveMatches"
    Write-Output 'No package was registered, installed, signed, or launched.'
} finally { Pop-Location }
