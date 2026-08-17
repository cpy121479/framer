#----------------------------------------------------------------------------
# fetch_uvm_core.ps1 - 下载 Accellera 官方 uvm-core（Verilator 平台依赖）
# 从 GitHub 下载 zip 并解压到 tools/uvm-core-main，随后自动打 Verilator 补丁。
#----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $toolsDir 'uvm-core-main'

if (Test-Path (Join-Path $dest 'src\uvm.sv')) {
  Write-Host "uvm-core 已存在：$dest"
  exit 0
}

$zip = Join-Path $env:TEMP 'uvm-core-main.zip'
Write-Host "下载 Accellera uvm-core ..."
Invoke-WebRequest -Uri 'https://github.com/accellera-official/uvm-core/archive/refs/heads/main.zip' -OutFile $zip

Write-Host "解压到 $toolsDir ..."
$extract = Join-Path $env:TEMP ('uvm-core-extract-' + [guid]::NewGuid().ToString('N'))
Expand-Archive -Path $zip -DestinationPath $extract -Force
$srcDir = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
Move-Item -LiteralPath $srcDir.FullName -Destination $dest
Remove-Item -LiteralPath $zip -Force
Remove-Item -LiteralPath $extract -Recurse -Force

Write-Host "完成：$dest"
