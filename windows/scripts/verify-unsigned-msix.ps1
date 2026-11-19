param(
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [ValidateSet('x64','ARM64')][string]$Architecture='x64'
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$windowsRoot=Split-Path -Parent $PSScriptRoot
$package=[IO.Path]::GetFullPath($PackagePath)
if (!(Test-Path -LiteralPath $package -PathType Leaf)) { throw 'The unsigned MSIX was not found.' }
$sourcePath=Join-Path $windowsRoot 'src\Veo.Windows\Package.appxmanifest'
function Read-SafeXml([string]$Text) {
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $input=New-Object IO.StringReader($Text)
    $reader=[Xml.XmlReader]::Create($input,$settings)
    try { $document=New-Object Xml.XmlDocument; $document.XmlResolver=$null; $document.Load($reader); return ,$document }
    finally { $reader.Dispose(); $input.Dispose() }
}
$source=Read-SafeXml (Get-Content -LiteralPath $sourcePath -Raw)
$archive=[IO.Compression.ZipFile]::OpenRead($package)
try {
    $entries=New-Object 'Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
        $name=$entry.FullName.Replace('\','/')
        if ($name.EndsWith('/')) { continue }
        if ($name.StartsWith('/') -or $name.Contains(':') -or $name.Split('/').Contains('..') -or $name.Split('/').Contains('.') -or $name.Contains([char]0)) { throw "Unsafe package entry: $name" }
        if ($entries.ContainsKey($name)) { throw "Duplicate Windows package path: $name" }
        if ($name -match '(?i)\.(pfx|p12)$') { throw 'A private signing-certificate file must not be included in this unsigned package.' }
        $entries.Add($name,$entry)
    }
    if ($entries.ContainsKey('AppxSignature.p7x')) { throw 'This workflow expects an unsigned package; a signature was present.' }
    $required=@('AppxManifest.xml','AppxBlockMap.xml','[Content_Types].xml','resources.pri','Veo.Windows.exe','Veo.Windows.dll',
        'Veo.Windows.runtimeconfig.json','Veo.Core.dll','Veo.Infrastructure.dll','Veo.Protocol.dll','Veo.Platform.Windows.dll',
        'e_sqlite3.dll','WebView2Loader.dll','Helper/veo-continuation.exe','Helper/veo-continuation.dll',
        'Helper/veo-continuation.runtimeconfig.json','Helper/hostfxr.dll','Helper/coreclr.dll')
    foreach ($name in $required) { if (!$entries.ContainsKey($name) -or $entries[$name].Length -eq 0) { throw "Missing or empty package payload: $name" } }
    function Read-EntryText([string]$Name) {
        $stream=$entries[$Name].Open(); $reader=New-Object IO.StreamReader($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
    }
    $manifest=Read-SafeXml (Read-EntryText 'AppxManifest.xml')
    $ns=New-Object Xml.XmlNamespaceManager($manifest.NameTable)
    $ns.AddNamespace('f','http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $ns.AddNamespace('uap','http://schemas.microsoft.com/appx/manifest/uap/windows10')
    $ns.AddNamespace('uap3','http://schemas.microsoft.com/appx/manifest/uap/windows10/3')
    $ns.AddNamespace('desktop','http://schemas.microsoft.com/appx/manifest/desktop/windows10')
    $ns.AddNamespace('com','http://schemas.microsoft.com/appx/manifest/com/windows10')
    $identity=$manifest.SelectSingleNode('/f:Package/f:Identity',$ns)
    if (!$identity -or $identity.Name -ne [string]$source.Package.Identity.Name -or $identity.Publisher -ne [string]$source.Package.Identity.Publisher -or $identity.Version -ne [string]$source.Package.Identity.Version -or $identity.ProcessorArchitecture -ne $Architecture.ToLowerInvariant()) { throw 'Packaged identity/version/architecture does not match the source manifest and requested architecture.' }
    $app=$manifest.SelectSingleNode('/f:Package/f:Applications/f:Application[@Id="App"]',$ns)
    if (!$app -or $app.Executable -ne 'Veo.Windows.exe' -or $app.EntryPoint -ne 'Windows.FullTrustApplication') { throw 'The native full-trust app entry point is incorrect.' }
    $family=$manifest.SelectSingleNode('/f:Package/f:Dependencies/f:TargetDeviceFamily',$ns)
    if (!$family -or $family.Name -ne 'Windows.Desktop' -or $family.MinVersion -ne [string]$source.Package.Dependencies.TargetDeviceFamily.MinVersion) { throw 'The Windows desktop minimum version differs from the source manifest.' }
    $runtime=$manifest.SelectSingleNode('/f:Package/f:Dependencies/f:PackageDependency[starts-with(@Name,"Microsoft.WindowsAppRuntime.")]',$ns)
    if (!$runtime -or [version]$runtime.MinVersion -lt [version]'2.6.5.0') { throw 'The expected Windows App Runtime dependency is missing or older than the pinned SDK.' }
    $alias=$manifest.SelectSingleNode('//uap3:Extension[@Category="windows.appExecutionAlias"][@Executable="Helper\veo-continuation.exe"]/uap3:AppExecutionAlias/desktop:ExecutionAlias[@Alias="veo-continuation.exe"]',$ns)
    if (!$alias) { throw 'The continuation helper alias does not reference its packaged executable.' }
    $toast=$manifest.SelectSingleNode('//desktop:ToastNotificationActivation',$ns)
    $server=$manifest.SelectSingleNode('//com:ExeServer[@Executable="Veo.Windows.exe"]',$ns)
    $class=$manifest.SelectSingleNode('//com:ExeServer[@Executable="Veo.Windows.exe"]/com:Class',$ns)
    if (!$toast -or !$server -or !$class -or $class.Id -ne $toast.ToastActivatorCLSID) { throw 'Toast COM activation is missing or does not match its packaged app server.' }
    function Assert-Resource([string]$Path) {
        $resource=$Path.Replace('\','/')
        if ($entries.ContainsKey($resource)) { return }
        $extension=[IO.Path]::GetExtension($resource); $stem=$resource.Substring(0,$resource.Length-$extension.Length)
        if (!@($entries.Keys | Where-Object { $_.StartsWith($stem+'.',[StringComparison]::OrdinalIgnoreCase) -and $_.EndsWith($extension,[StringComparison]::OrdinalIgnoreCase) }).Count) { throw "Manifest resource has no packaged qualified asset: $resource" }
    }
    $visual=$app.SelectSingleNode('uap:VisualElements',$ns)
    foreach ($resource in @([string]$manifest.Package.Properties.Logo,[string]$visual.Square150x150Logo,[string]$visual.Square44x44Logo,[string]$visual.DefaultTile.Wide310x150Logo,[string]$visual.SplashScreen.Image)) { if ($resource) { Assert-Resource $resource } }
    foreach ($name in @('Veo.Windows.runtimeconfig.json','Helper/veo-continuation.runtimeconfig.json')) {
        $config=Read-EntryText $name | ConvertFrom-Json
        if (!@($config.runtimeOptions.includedFrameworks).Count) { throw "Expected self-contained .NET runtime payload for $name" }
    }
    $machine=if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
    foreach ($name in @('Veo.Windows.exe','Helper/veo-continuation.exe','e_sqlite3.dll','WebView2Loader.dll')) {
        $memory=New-Object IO.MemoryStream; $stream=$entries[$name].Open()
        try {
            $stream.CopyTo($memory); $memory.Position=0; $binary=New-Object IO.BinaryReader($memory)
            if ($binary.ReadUInt16() -ne 0x5A4D) { throw "Missing PE image header: $name" }
            $memory.Position=0x3c; $offset=$binary.ReadInt32(); if ($offset -lt 0 -or $offset+6 -gt $memory.Length) { throw "Invalid PE header offset: $name" }
            $memory.Position=$offset; if ($binary.ReadUInt32() -ne 0x00004550 -or $binary.ReadUInt16() -ne $machine) { throw "Incorrect native PE architecture: $name" }
        } finally { $stream.Dispose(); $memory.Dispose() }
    }
    $hashes=@(foreach ($name in @($entries.Keys | Sort-Object)) {
        $stream=$entries[$name].Open(); $algorithm=[Security.Cryptography.SHA256]::Create()
        try { [pscustomobject]@{Path=$name;Bytes=$entries[$name].Length;Sha256=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','')} }
        finally { $algorithm.Dispose(); $stream.Dispose() }
    })
    [pscustomobject]@{
        PackagePath=$package;Unsigned=$true;Architecture=$Architecture;Identity=[string]$identity.Name;Publisher=[string]$identity.Publisher;Version=[string]$identity.Version
        MinWindows=[string]$family.MinVersion;WindowsAppRuntime=[string]$runtime.MinVersion;FileCount=$entries.Count
        PackageSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash;Files=$hashes
        Verified=@('safe unique ZIP paths','unsigned package','source identity/version','native app entry','continuation helper and alias','toast COM identity','manifest resources','self-contained .NET payload','native PE architecture','all payload hashes')
    }
} finally { $archive.Dispose() }
