param([string]$Installer)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (!$Installer) {
    $version = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'Cargo.toml')), '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
    $Installer = "$root\dist\AssistenteTI-Manager-Setup-$version-windows-x64.exe"
}
$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E62CCB6B-5410-4839-BAA0-35C93C2259EE}_is1'
if (Test-Path $registryPath) { throw 'Já existe uma instalação registrada do Manager. Execute o teste em uma conta/VM separada.' }
$testDir = Join-Path $root ('test-output\installer-' + [guid]::NewGuid().ToString('N'))
$appDir = Join-Path $testDir 'app'
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
function Setup([string]$url, [string]$logName) {
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOICONS','/TASKS=""',('/DIR="' + $appDir + '"'),('/LOG="' + "$testDir\$logName.log" + '"'))
    if ($url) { $arguments += ('/SERVERURL="' + $url + '"') }
    $process = Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    return $process.ExitCode
}
function Assert([bool]$value, [string]$message) { if (!$value) { throw $message } }
function Uninstall {
    $uninstaller = Join-Path $appDir 'unins000.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="' + "$testDir\uninstall.log" + '"')) -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw "Desinstalação falhou: $($process.ExitCode)" }
    }
}
try {
    Assert ((Setup 'http://external.example.com' 'invalid') -ne 0) 'Instalador aceitou HTTP externo.'
    Assert (!(Test-Path "$appDir\assist-manager.exe")) 'Instalação inválida gravou o executável.'
    Assert ((Setup 'https://ti.example.com' 'install') -eq 0) 'Instalação silenciosa falhou.'
    Assert (Test-Path "$appDir\assist-manager.exe") 'Executável não instalado.'
    Assert (Test-Path $registryPath) 'Registro de desinstalação ausente.'
    Assert (([IO.File]::ReadAllText("$appDir\server-url.txt")) -eq 'https://ti.example.com/') 'URL não foi salva corretamente.'
    Assert ((Setup '' 'preserve') -eq 0) 'Reinstalação falhou.'
    Assert (([IO.File]::ReadAllText("$appDir\server-url.txt")) -eq 'https://ti.example.com/') 'Reinstalação perdeu a configuração.'
    Assert ((Setup 'https://new.example.com' 'change') -eq 0) 'Alteração de servidor falhou.'
    Assert (([IO.File]::ReadAllText("$appDir\server-url.txt")) -eq 'https://new.example.com/') 'Alteração não persistiu.'
    Uninstall
    Assert (!(Test-Path "$appDir\assist-manager.exe")) 'Desinstalação não removeu o executável.'
    Assert (!(Test-Path "$appDir\server-url.txt")) 'Desinstalação não removeu a configuração.'
    Assert (!(Test-Path $registryPath)) 'Desinstalação não removeu o registro.'
    [IO.File]::WriteAllText("$testDir\result.json", (@{passed=$true;checks=@('invalid-url','install','config','registry','reinstall','change-url','uninstall');time=(Get-Date -Format o)} | ConvertTo-Json))
    Write-Output "INSTALLER OK: instalação, URL, reinstalação e desinstalação. Logs: $testDir"
} finally { Uninstall }
