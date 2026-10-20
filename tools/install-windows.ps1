# Installs mymonitor for the current user: the release build into
# %LOCALAPPDATA%\Programs\mymonitor and a Start Menu shortcut. No admin.
#
#     zig build -Doptimize=ReleaseSmall --prefix zig-out/release
#     powershell -ExecutionPolicy Bypass -File tools/install-windows.ps1
#     powershell -ExecutionPolicy Bypass -File tools/install-windows.ps1 -Uninstall
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:LOCALAPPDATA 'Programs\mymonitor'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\mymonitor.lnk'

if ($Uninstall) {
    Get-Process mymonitor -ErrorAction SilentlyContinue | Stop-Process
    Remove-Item $lnk -ErrorAction SilentlyContinue
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'mymonitor uninstalled'
    return
}

$exe = Join-Path $PSScriptRoot '..\zig-out\release\bin\mymonitor.exe'
if (-not (Test-Path $exe)) { throw "No build at ${exe}: run zig build -Doptimize=ReleaseSmall --prefix zig-out/release first" }

Get-Process mymonitor -ErrorAction SilentlyContinue | Stop-Process
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item $exe $dir -Force

$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($lnk)
$s.TargetPath = Join-Path $dir 'mymonitor.exe'
$s.WorkingDirectory = $dir
$s.Description = 'A small activity monitor'
$s.Save()

Write-Host "mymonitor installed in $dir, with a Start Menu shortcut"
