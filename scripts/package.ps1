$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root 'dist'
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'Cargo.toml')), '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
if (!$version -or $version -notmatch '^[0-9A-Za-z.-]+$') { throw 'Versão inválida no Cargo.toml.' }
New-Item -ItemType Directory -Path "$dest\windows" -Force | Out-Null
foreach ($name in @('assist-agent','assist-manager','assist-release')) {
    Copy-Item -LiteralPath "$root\target\release\$name.exe" -Destination "$dest\windows\$name.exe" -Force
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-Package([string]$name, [IO.FileInfo[]]$files) {
    $path = Join-Path $dest $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($root.Length + 1).Replace('\','/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$relative,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    Write-Output $path
}
$windowsFiles = @(Get-ChildItem "$dest\windows" -File) + @(Get-ChildItem "$root\scripts\windows" -File) + @(Get-Item "$root\README.md","$root\VALIDATION.md")
New-Package "AssistenteTI-windows-$version.zip" $windowsFiles
$sourceFiles = @()
foreach ($directory in @('crates','web','scripts','docs','.github')) { $sourceFiles += @(Get-ChildItem (Join-Path $root $directory) -File -Recurse) }
foreach ($file in @('Cargo.toml','Cargo.lock','README.md','VALIDATION.md','.gitignore')) { $sourceFiles += Get-Item (Join-Path $root $file) -Force }
New-Package "AssistenteTI-source-$version.zip" $sourceFiles
$artifactNames = @("AssistenteTI-windows-$version.zip", "AssistenteTI-source-$version.zip")
$installerName = "AssistenteTI-Manager-Setup-$version-windows-x64.exe"
if (Test-Path -LiteralPath (Join-Path $dest $installerName)) { $artifactNames += $installerName }
$checksums = foreach ($artifact in $artifactNames) {
    (Get-FileHash -LiteralPath (Join-Path $dest $artifact) -Algorithm SHA256).Hash.ToLower() + '  ' + $artifact
}
[IO.File]::WriteAllLines((Join-Path $dest 'SHA256SUMS.txt'), $checksums, (New-Object Text.UTF8Encoding($false)))
