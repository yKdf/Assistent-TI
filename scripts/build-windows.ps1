$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    & cargo build --release --locked -p assist-agent -p assist-manager -p assist-release -p assist-server -p assist-support
    if ($LASTEXITCODE -ne 0) { throw 'Compilação falhou.' }
    $dest = Join-Path $root 'dist\windows'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($name in @('assist-agent','assist-manager','assist-release','assist-server','assist-support')) { Copy-Item "target\release\$name.exe" $dest -Force }
    Write-Host "Binários prontos em $dest"
} finally { Pop-Location }
