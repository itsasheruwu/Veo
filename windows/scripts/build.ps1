param([ValidateSet('x64','ARM64')][string]$Architecture='x64',[ValidateSet('Debug','Release')][string]$Configuration='Debug',[switch]$Locked)
$ErrorActionPreference='Stop'
$windowsRoot=Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $windowsRoot
try {
    $project=Join-Path $windowsRoot 'src\Veo.Windows\Veo.Windows.csproj'
    $selectedCodex=if ($env:CODEX_EXECUTABLE) { $env:CODEX_EXECUTABLE } else { (Get-Command codex -ErrorAction Stop).Source }
    $schema=Join-Path $windowsRoot 'artifacts\protocol-schema'
    & $selectedCodex app-server generate-json-schema --experimental --out $schema
    if ($LASTEXITCODE -ne 0) { throw 'The selected Codex CLI could not export its protocol schema.' }
    $restore=@('restore',$project,"-p:Platform=$Architecture")
    if ($Locked) { $restore+='--locked-mode' }
    & dotnet @restore
    if ($LASTEXITCODE -ne 0) { throw 'NuGet restore failed.' }
    & dotnet build $project --no-restore -m:1 "-p:Platform=$Architecture" "-p:Configuration=$Configuration"
    if ($LASTEXITCODE -ne 0) { throw 'Veo build failed.' }
    $rid='win-'+$Architecture.ToLowerInvariant()
    $artifact=Join-Path $windowsRoot "src\Veo.Windows\bin\$Architecture\$Configuration\net10.0-windows10.0.26100.0\$rid\Veo.Windows.exe"
    if (!(Test-Path -LiteralPath $artifact)) { throw 'The expected executable was not produced.' }
    $assembly=[IO.Path]::ChangeExtension($artifact,'.dll')
    Get-FileHash -Algorithm SHA256 -LiteralPath $artifact,$assembly
    Write-Output "Development artifact: $artifact"
} finally { Pop-Location }
