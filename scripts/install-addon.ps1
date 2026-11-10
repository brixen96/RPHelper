# Copies the RPHelper addon into the WoW _retail_ AddOns folder.
# Run from repo root: npm run install:addon  (or right-click → Run with PowerShell)

$addonName = "RPHelper"
$repoAddon = Join-Path $PSScriptRoot "..\Addon"

$candidates = @(
  "${env:ProgramFiles(x86)}\World of Warcraft\_retail_\Interface\AddOns",
  "$env:ProgramFiles\World of Warcraft\_retail_\Interface\AddOns",
  "C:\Program Files (x86)\Steam\steamapps\common\World of Warcraft\_retail_\Interface\AddOns",
  "D:\World of Warcraft\_retail_\Interface\AddOns",
  "E:\World of Warcraft\_retail_\Interface\AddOns",
  "F:\World of Warcraft\_retail_\Interface\AddOns",
  "G:\World of Warcraft\_retail_\Interface\AddOns"
)

$addonsDir = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $addonsDir) {
  Write-Host "Could not find your WoW AddOns folder. Pass it manually:" -ForegroundColor Yellow
  Write-Host "  .\scripts\install-addon.ps1 -Target 'D:\...\_retail_\Interface\AddOns'" -ForegroundColor Yellow
  exit 1
}

$dest = Join-Path $addonsDir $addonName
Write-Host "Installing addon to: $dest" -ForegroundColor Cyan

if (Test-Path $dest) {
  # Preserve the handoff file if the app already wrote suggestions into it
  $existingHandoff = Join-Path $dest "RPHelperHandoff.lua"
  $backup = $null
  if (Test-Path $existingHandoff) {
    $backup = Get-Content $existingHandoff -Raw
  }
  Copy-Item -Path (Join-Path $repoAddon "*") -Destination $dest -Recurse -Force
  if ($backup) {
    Set-Content -Path $existingHandoff -Value $backup -NoNewline
  }
} else {
  New-Item -ItemType Directory -Path $dest | Out-Null
  Copy-Item -Path (Join-Path $repoAddon "*") -Destination $dest -Recurse -Force
}

Write-Host "Done! Restart WoW (or /reload at the character screen) and type /rph in game." -ForegroundColor Green