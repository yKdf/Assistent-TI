param([string]$Iscc, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'Cargo.toml')), '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
if (!$version -or $version -notmatch '^[0-9A-Za-z.-]+$') { throw 'Versão inválida no Cargo.toml.' }
if (!$Iscc) {
    $candidates = @(
        "$root\.toolchain\inno\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe"
    )
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) { $Iscc = $compiler.Source }
    else { $Iscc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }
}
if (!$Iscc -or !(Test-Path -LiteralPath $Iscc)) { throw 'Instale Inno Setup 6/7 ou informe -Iscc com o caminho do ISCC.exe.' }
Push-Location $root
try {
    if (!$SkipBuild) {
        & cargo build --release --locked -p assist-manager -p assist-agent -p assist-server -p assist-support
        if ($LASTEXITCODE -ne 0) { throw 'Compilação dos componentes falhou.' }
    }
    & $Iscc "/DAppVersion=$version" "/DProjectRoot=$root" "$root\scripts\windows\manager-installer.iss"
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível gerar o instalador.' }
    Write-Output "Instalador: $root\dist\AssistenteTI-Setup-$version-windows-x64.exe"
} finally { Pop-Location }
