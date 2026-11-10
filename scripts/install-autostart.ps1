# Registers RPHelper.exe to start with Windows (invisible, in the user's Startup).
# Run: powershell -ExecutionPolicy Bypass -File scripts\install-autostart.ps1
param(
  [string]$ExePath = ""
)

if (-not $ExePath) {
  $ExePath = Join-Path $PSScriptRoot "..\dist\RPHelper.exe"
}
$ExePath = (Resolve-Path $ExePath -ErrorAction SilentlyContinue).Path
if (-not $ExePath) {
  Write-Host "RPHelper.exe not found - build it first: node scripts/build-exe.mjs" -ForegroundColor Yellow
  exit 1
}

$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup "RPHelper.lnk"

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath = $ExePath
$lnk.WorkingDirectory = Split-Path $ExePath
$lnk.WindowStyle = 7  # minimized
$lnk.Description = "RPHelper AI watcher (WoW RP co-pilot)"
$lnk.Save()

Write-Host "Autostart registered: $lnkPath" -ForegroundColor Green
Write-Host "RPHelper.exe will now start with Windows (minimized). Remove it anytime by deleting that .lnk file."