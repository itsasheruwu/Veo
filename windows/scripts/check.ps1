param([switch]$RealRuntime)
$ErrorActionPreference='Stop'
$windowsRoot=Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $windowsRoot
try {
    $projects = @(Get-ChildItem -LiteralPath (Join-Path $windowsRoot 'tests') -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.Tests.csproj'
    } | Sort-Object BaseName)
    foreach ($project in $projects) {
        $name = $project.BaseName
        $arguments=@('run','--project',$project.FullName)
        if ($name -eq 'Veo.Protocol.Tests') {
            $arguments+=@('--',"--schema=$(Join-Path $windowsRoot 'artifacts\protocol-schema')")
            if ($RealRuntime) { $arguments+=@('--real','--probe-real-schema') }
        }
        & dotnet @arguments
        if ($LASTEXITCODE -ne 0) { throw "$name failed." }
    }
    & python 'docs\validate-manifests.py'
    if ($LASTEXITCODE -ne 0) { throw 'Source inventory verification failed.' }
} finally { Pop-Location }
