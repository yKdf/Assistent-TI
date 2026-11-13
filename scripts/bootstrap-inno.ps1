$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$toolDir = Join-Path $root '.toolchain\inno'
if (Test-Path -LiteralPath "$toolDir\ISCC.exe") { Write-Output "$toolDir\ISCC.exe"; exit 0 }
New-Item -ItemType Directory -Path "$root\.toolchain" -Force | Out-Null
$download = Join-Path $root '.toolchain\innosetup-7.1.1-x64.exe'
Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe' -OutFile $download
$expected = '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $expected) { throw 'SHA-256 do compilador não confere.' }
if ((Get-AuthenticodeSignature -LiteralPath $download).Status -ne 'Valid') { throw 'Assinatura do compilador não validada.' }
$process = Start-Process -FilePath $download -ArgumentList @('/PORTABLE=1','/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOICONS',('/DIR="' + $toolDir + '"')) -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "Falha preparando compilador: $($process.ExitCode)" }
Write-Output "$toolDir\ISCC.exe"
