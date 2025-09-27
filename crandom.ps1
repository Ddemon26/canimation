<#
.SYNOPSIS
  Randomly picks and executes one of the animation scripts in the current directory.

.DESCRIPTION
  - Scans the current directory for PowerShell animation scripts (*.ps1)
  - Excludes itself (crandom.ps1) and non-animation scripts
  - Randomly selects one and executes it with optional parameters
  - Passes through common parameters like -Fps, -Speed, -NoHardClear

.PARAMETER Fps
  Target frames per second to pass to the selected animation (if supported).

.PARAMETER Speed
  Speed multiplier to pass to the selected animation (if supported).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit for the selected animation.

.PARAMETER List
  Just list available animations without running one.

.PARAMETER Exclude
  Animation names to exclude from random selection (without .ps1 extension).

.EXAMPLE
  ./crandom.ps1
  ./crandom.ps1 -Fps 60 -Speed 2
  ./crandom.ps1 -List
  ./crandom.ps1 -Exclude cmatrix,cdonut
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps,
  [ValidateRange(0.1,5.0)][double]$Speed,
  [switch]$NoHardClear,
  [switch]$List,
  [string[]]$Exclude = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Get current script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Get all PowerShell scripts in the directory
$allScripts = Get-ChildItem -Path $scriptDir -Filter "*.ps1" | Where-Object {
  $_.Name -ne "crandom.ps1" -and
  $_.Name -ne "cmatrix-themes.ps1" -and
  $_.Name -notlike "*-themes.ps1"
}

# Filter out excluded scripts
if ($Exclude.Count -gt 0) {
  $excludeWithExt = $Exclude | ForEach-Object { "$_.ps1" }
  $allScripts = $allScripts | Where-Object { $_.Name -notin $excludeWithExt }
}

# List mode
if ($List) {
  Write-Host "Available animations:" -ForegroundColor Cyan
  $allScripts | ForEach-Object {
    Write-Host "  $($_.BaseName)" -ForegroundColor Green
  }
  Write-Host "`nUsage: ./crandom.ps1 [-Fps <fps>] [-Speed <speed>] [-NoHardClear] [-Exclude <names>]" -ForegroundColor Yellow
  exit 0
}

# Check if any scripts found
if ($allScripts.Count -eq 0) {
  Write-Host "No animation scripts found in directory: $scriptDir" -ForegroundColor Red
  exit 1
}

# Randomly select one
$rand = [System.Random]::new()
$selected = $allScripts[$rand.Next($allScripts.Count)]

# Build parameter string
$params = @()
if ($PSBoundParameters.ContainsKey('Fps')) { $params += "-Fps $Fps" }
if ($PSBoundParameters.ContainsKey('Speed')) { $params += "-Speed $Speed" }
if ($NoHardClear) { $params += "-NoHardClear" }

$paramString = $params -join " "

# Display selection and start immediately
Write-Host "Running: " -NoNewline -ForegroundColor Cyan
Write-Host $selected.BaseName -ForegroundColor Yellow

# Execute the selected script
$scriptPath = $selected.FullName
if ($paramString) {
  $command = "& `"$scriptPath`" $paramString"
} else {
  $command = "& `"$scriptPath`""
}

try {
  Invoke-Expression $command
} catch {
  Write-Host "Error executing $($selected.Name): $_" -ForegroundColor Red
  exit 1
}