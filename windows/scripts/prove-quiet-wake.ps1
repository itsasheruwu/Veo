param(
    [switch]$EnableProof,
    [Parameter(Mandatory=$true)][string]$LiveProfileRoot
)
$ErrorActionPreference='Stop'
if (!$EnableProof) { throw 'Pass -EnableProof explicitly to register, run and remove a temporary per-user continuation proof task.' }
$windowsRoot=Split-Path -Parent $PSScriptRoot
$sourceManifest=[xml](Get-Content -LiteralPath (Join-Path $windowsRoot 'src\Veo.Windows\Package.appxmanifest') -Raw)
$identityName=[string]$sourceManifest.Package.Identity.Name
$package=Get-AppxPackage -Name $identityName -ErrorAction Stop | Select-Object -First 1
if (!$package) { throw 'Install the current Veo development package before running the continuation proof.' }
$installedManifest=Get-AppxPackageManifest -Package $package.PackageFullName
$namespaces=New-Object Xml.XmlNamespaceManager($installedManifest.NameTable)
$namespaces.AddNamespace('uap3','http://schemas.microsoft.com/appx/manifest/uap/windows10/3')
$namespaces.AddNamespace('desktop','http://schemas.microsoft.com/appx/manifest/desktop/windows10')
$alias=$installedManifest.SelectSingleNode('//uap3:Extension[@Category="windows.appExecutionAlias"][@Executable="Helper\veo-continuation.exe"]/uap3:AppExecutionAlias/desktop:ExecutionAlias[@Alias="veo-continuation.exe"]',$namespaces)
if (!$alias) { throw 'The installed package does not expose the current continuation helper alias. Rebuild and register the exact artifact first.' }
$aumid=$package.PackageFamilyName+'!App'
$project=Join-Path $windowsRoot 'tests\Veo.Continuation.Tests\Veo.Continuation.Tests.csproj'
& dotnet run --project $project --no-restore -p:BuildInParallel=false -m:1 -- --quiet-wake-proof --enable-proof "--live-profile=$([IO.Path]::GetFullPath($LiveProfileRoot))" "--aumid=$aumid"
if ($LASTEXITCODE -ne 0) { throw 'The controlled quiet-wake proof failed. Inspect its task-cleanup output before rerunning.' }
