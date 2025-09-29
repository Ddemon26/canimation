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
  .\crandom.ps1
  Run a random animation with default settings.

.EXAMPLE
  .\crandom.ps1 -Fps 60 -Speed 2
  Run a random animation at 60 FPS with double speed.

.EXAMPLE
  .\crandom.ps1 -List
  List all available animations without running.

.EXAMPLE
  .\crandom.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps,
  [ValidateRange(0.1,5.0)][double]$Speed,
  [switch]$NoHardClear,
  [switch]$List,
  [string[]]$Exclude = @(),
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Random Animation Launcher
==========================

SYNOPSIS
    Randomly selects and runs one of the available animation scripts.

USAGE
    .\crandom.ps1 [OPTIONS]
    .\crandom.ps1 -h

DESCRIPTION
    Scans the current directory for animation scripts and randomly picks one
    to execute. Useful for variety or when you can't decide which animation
    to watch. Passes through common parameters to the selected animation.

OPTIONS
    -Fps <int>          Target FPS to pass to animation (5-120)
    -Speed <double>     Speed multiplier to pass (0.1-5.0)
    -NoHardClear        Don't clear screen on exit
    -List               List available animations without running
    -Exclude <array>    Animation names to exclude (without .ps1)
    -h                  Show this help and exit

EXAMPLES
    .\crandom.ps1
        Run a random animation with default settings

    .\crandom.ps1 -Fps 60 -Speed 2
        Random animation at high framerate and double speed

    .\crandom.ps1 -List
        Show all available animations

    .\crandom.ps1 -Exclude cmatrix,cdonut
        Run random animation, excluding cmatrix and cdonut

    .\crandom.ps1 -NoHardClear
        Random animation that leaves screen as-is on exit

    .\crandom.ps1 -Fps 30 -Exclude cboids,clife,cwire
        Random animation at 30 FPS, excluding specific ones

BEHAVIOR
    - Automatically excludes crandom.ps1 and theme variants
    - Only selects from animation scripts in current directory
    - Passes Fps, Speed, and NoHardClear to selected animation
    - Not all animations support all parameters
    - Shows which animation was selected before running

CONTROLS
    Depends on the selected animation (typically any key to exit)

NOTES
    - Use -List to see what animations are available
    - Exclude parameter takes script names without .ps1 extension
    - Parameters are passed if the animation supports them
    - Great for screensaver-style random variety

"@
    Write-Host $helpText
    exit 0
}

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