# Copies this project into REAPER's Scripts folder so it's loadable from
# REAPER's Action list. Source of truth stays in this GitHub folder; this is
# a one-way sync (GitHub -> REAPER), run after every change you want to test.

$ErrorActionPreference = "Stop"

$SourceDir = $PSScriptRoot
$DestDir = Join-Path $env:APPDATA "REAPER\Scripts\reaper-tab-notation"

if (-not (Test-Path $DestDir)) {
  New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
}

robocopy $SourceDir $DestDir /MIR /XD ".git" /XF "deploy.ps1" ".gitignore" | Out-Null

# robocopy's exit codes 0-7 all mean success (see /? for the bitmask); only
# 8+ indicates a real failure.
if ($LASTEXITCODE -ge 8) {
  Write-Error "robocopy failed with exit code $LASTEXITCODE"
  exit 1
}

Write-Host "Deployed to $DestDir"
exit 0
