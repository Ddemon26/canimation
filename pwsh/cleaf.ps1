<#
.SYNOPSIS
  3D spinning marijuana leaf rendered in ASCII with lighting and differential updates.

.DESCRIPTION
  - Renders a simplified iconic marijuana leaf (7 leaflets) spinning in 3D space
  - Uses z-buffer depth testing and differential rendering for smooth performance
  - Green ANSI coloring with ASCII luminance characters for realistic shading
  - Same update pattern as cdonut: only rewrites changed cells per frame
  - Precomputed geometry and optimized rendering pipeline

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Size
  Visual scale of the leaf (default: 20).

.PARAMETER Speed
  Rotation speed multiplier (default: 1.0).

.PARAMETER Quality
  Surface sampling quality ('Low','Medium','High','Ultra'). Default: Medium.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cleaf.ps1
  Run with default settings (medium quality green leaf).

.EXAMPLE
  .\cleaf.ps1 -Quality High -Size 28 -Speed 0.5
  Large, high-quality leaf with slow rotation.

.EXAMPLE
  .\cleaf.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(8,80)][int]$Size = 20,
  [double]$Speed = 1.0,
  [ValidateSet('Low','Medium','High','Ultra')][string]$Quality = 'Medium',
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

3D Spinning Marijuana Leaf
===========================

SYNOPSIS
    ASCII art 3D marijuana leaf with realistic lighting and rotation.

USAGE
    .\cleaf.ps1 [OPTIONS]
    .\cleaf.ps1 -h

DESCRIPTION
    A simplified iconic marijuana leaf (7 leaflets) that spins in 3D space
    with realistic lighting effects and green ANSI coloring. Uses differential
    rendering to update only changed pixels for smooth performance.

OPTIONS
    -Fps <int>         Target frames per second (5-120, default: 30)
    -Size <int>        Visual scale of the leaf (8-80, default: 20)
    -Speed <double>    Rotation speed multiplier (default: 1.0)
    -Quality <string>  Surface sampling: Low, Medium, High, Ultra (default: Medium)
    -NoHardClear      Don't clear screen on exit
    -h                Show this help and exit

QUALITY LEVELS
    Low     - Fast rendering, lower detail
    Medium  - Balanced performance and quality (default)
    High    - Higher detail, more computation
    Ultra   - Maximum quality, highest CPU usage

EXAMPLES
    .\cleaf.ps1
        Standard medium quality spinning green leaf

    .\cleaf.ps1 -Quality Ultra -Size 28 -Speed 0.5
        Large, high-quality leaf with slow rotation

    .\cleaf.ps1 -Quality Low -Fps 60 -Speed 2.0
        Fast, low-detail leaf at high framerate

    .\cleaf.ps1 -Size 16 -NoHardClear
        Small leaf, leave screen unchanged on exit

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - 7-leaflet simplified marijuana leaf geometry
    - 3D rotation matrices (Rx and Rz) for tumbling motion
    - Z-buffer depth testing for proper occlusion
    - ASCII luminance ramp with ANSI green coloring
    - Differential rendering updates only changed screen positions
    - Optimized surface sampling based on quality setting

"@
    Write-Host $helpText
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- ANSI helpers ---------------------------------------------------------------
$e = "`e"
$AnsiReset       = "$e[0m"
$AnsiClearHome   = "$e[2J$e[H"
$AnsiClearFull   = "$e[3J$e[2J$e[H"
$AnsiScrollUpMax = "$e[9999S"
$RIS             = "$e" + "c"
$AnsiGreen       = "$e[32m"      # Green color for the leaf

# Key helpers (non-blocking)
function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

# --- Math / util ----------------------------------------------------------------
$Ramp = " .:-=+*#%@"
$RampLen = $Ramp.Length

# Leaf geometry cached data
$script:LeafPoints = $null    # array of [x, y, z, nx, ny, nz] points
$script:LeafCount = 0

# Cached buffers
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null   # char[]
$script:NewChars  = $null   # char[]
$script:ZBuf      = $null   # double[]

function Init-LeafGeometry() {
    # Generate marijuana leaf geometry: 7 leaflets arranged as simplified iconic shape
    # Quality determines sampling density

    switch ($Quality) {
        'Low'    { $sampleDensity = 15 }
        'Medium' { $sampleDensity = 25 }
        'High'   { $sampleDensity = 40 }
        'Ultra'  { $sampleDensity = 60 }
        default  { $sampleDensity = 25 }
    }

    $points = [System.Collections.ArrayList]::new()

    # Define 7 leaflets with angles, lengths, and widths
    # Center: 0°, then ±25°, ±50°, ±75° for the 6 side leaflets
    $leaflets = @(
        @{angle = 0;   length = 1.0;  width = 0.22; },   # Center (largest)
        @{angle = 25;  length = 0.85; width = 0.18; },   # Right upper
        @{angle = -25; length = 0.85; width = 0.18; },   # Left upper
        @{angle = 50;  length = 0.65; width = 0.14; },   # Right middle
        @{angle = -50; length = 0.65; width = 0.14; },   # Left middle
        @{angle = 75;  length = 0.45; width = 0.10; },   # Right lower
        @{angle = -75; length = 0.45; width = 0.10; }    # Left lower
    )

    foreach ($leaflet in $leaflets) {
        $angleRad = $leaflet.angle * [Math]::PI / 180.0
        $baseX = 0.0
        $baseY = 0.0

        # Direction vector for this leaflet
        $dirX = [Math]::Sin($angleRad)
        $dirY = [Math]::Cos($angleRad)

        # Sample along the length and width of each leaflet
        for ($i = 0; $i -lt $sampleDensity; $i++) {
            # t from 0 (base) to 1 (tip)
            $t = $i / ($sampleDensity - 1.0)

            # Width tapers to point at tip (parabolic taper for natural shape)
            $widthAtT = $leaflet.width * (1.0 - $t * $t)

            # Sample across width
            $widthSamples = [Math]::Max(3, [int]($sampleDensity * $widthAtT * 2))

            for ($j = 0; $j -lt $widthSamples; $j++) {
                # s from -1 to 1 across width
                $s = -1.0 + 2.0 * $j / ($widthSamples - 1.0)

                # Elliptical cross-section
                $widthFactor = [Math]::Sqrt(1.0 - $s * $s)

                # Position along leaflet
                $dist = $t * $leaflet.length
                $x = $baseX + $dirX * $dist
                $y = $baseY + $dirY * $dist

                # Add width offset perpendicular to direction
                $perpX = -$dirY
                $perpY = $dirX
                $x += $perpX * $s * $widthAtT * $widthFactor
                $y += $perpY * $s * $widthAtT * $widthFactor

                # Slight curvature in z for 3D effect (leaf curves slightly)
                $z = -0.08 * $t * (1.0 - $t * $t) + 0.02 * $s * $widthAtT

                # Normal vector (simplified: mostly pointing up/out with slight variation)
                $nx = $perpX * $s * 0.3
                $ny = $perpY * $s * 0.3
                $nz = 1.0
                $nlen = [Math]::Sqrt($nx*$nx + $ny*$ny + $nz*$nz)
                if ($nlen -gt 0.001) {
                    $nx /= $nlen
                    $ny /= $nlen
                    $nz /= $nlen
                }

                [void]$points.Add(@($x, $y, $z, $nx, $ny, $nz))
            }
        }
    }

    # Add stem at base
    $stemLength = 0.4
    $stemSamples = [int]($sampleDensity * 0.3)
    for ($i = 0; $i -lt $stemSamples; $i++) {
        $t = $i / ($stemSamples - 1.0)
        $y = -$t * $stemLength
        $stemWidth = 0.03 * (1.0 - $t * 0.5)

        for ($j = 0; $j -lt 5; $j++) {
            $angle = $j * 2.0 * [Math]::PI / 5.0
            $x = [Math]::Cos($angle) * $stemWidth
            $z = [Math]::Sin($angle) * $stemWidth

            $nx = [Math]::Cos($angle)
            $ny = 0.0
            $nz = [Math]::Sin($angle)

            [void]$points.Add(@($x, $y, $z, $nx, $ny, $nz))
        }
    }

    $script:LeafPoints = $points.ToArray()
    $script:LeafCount = $script:LeafPoints.Length
}

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$A = 0.0; $B = 0.0  # rotation angles
$K2 = 3.5  # camera distance

# Save console state; hide cursor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Treat Ctrl+C as input (avoid CancelKeyPress runspace handler)
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}

# Initial clear once so we start clean
try { [Console]::Write($AnsiClearHome) } catch {}

try {
  while ($true) {
    if (Test-KeyAvailable) { $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs) {
      $bw = [Console]::BufferWidth; $bh = [Console]::BufferHeight
      if ($bw -le 0) { $bw = 1 }
      if ($bh -le 0) { $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2     # avoid last row to prevent scroll
      $cx = [int]([math]::Floor($bw/2))
      $cy = [int]([math]::Floor($bh/2))
      $aspect = if ($bh -gt 0) { [double]$bw / [double]$bh } else { 1.0 }
      $K1 = [double]$Size

      # Resize buffers on console size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH) {
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bw * $bh)
        $script:NewChars  = New-Object 'char[]' ($bw * $bh)
        $script:ZBuf      = New-Object 'double[]' ($bw * $bh)
        Init-LeafGeometry
        # clear screen once on resize
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:ZBuf, 0, $script:ZBuf.Length)

      # Update rotation
      $dt = $frameMs / 1000.0
      $A += ($Speed * 1.2 * $dt)
      $B += ($Speed * 0.8 * $dt)
      $cosA = [math]::Cos($A); $sinA = [math]::Sin($A)
      $cosB = [math]::Cos($B); $sinB = [math]::Sin($B)

      # Light direction (normalized)
      $Lx = 0.0; $Ly = 1.0; $Lz = -1.0
      $invL = [math]::Sqrt($Lx*$Lx + $Ly*$Ly + $Lz*$Lz)
      $Lx /= $invL; $Ly /= $invL; $Lz /= $invL

      # Render all leaf points
      for ($i = 0; $i -lt $script:LeafCount; $i++) {
        $pt = $script:LeafPoints[$i]
        $x = $pt[0]; $y = $pt[1]; $z = $pt[2]
        $nx = $pt[3]; $ny = $pt[4]; $nz = $pt[5]

        # Rotate around X by A, then Z by B (Rx(A) * Rz(B))
        $y1 = $y*$cosA - $z*$sinA
        $z1 = $y*$sinA + $z*$cosA
        $x1 = $x
        $x2 = $x1*$cosB - $y1*$sinB
        $y2 = $x1*$sinB + $y1*$cosB
        $z2 = $z1

        # Project
        $zCam = $z2 + $K2
        if ($zCam -le 0.001) { $zCam = 0.001 }
        $ooz = 1.0 / $zCam
        $xp = [int]([math]::Round($cx + $K1 * $aspect * $x2 * $ooz))
        $yp = [int]([math]::Round($cy - $K1 * $y2 * $ooz))

        if ($xp -ge 0 -and $xp -le $maxX -and $yp -ge 0 -and $yp -le $maxY) {
          $idx = $xp + $bw * $yp
          if ($ooz -gt $script:ZBuf[$idx]) {
            $script:ZBuf[$idx] = $ooz

            # Rotate normal by same transformation
            $ny1 = $ny*$cosA - $nz*$sinA
            $nz1 = $ny*$sinA + $nz*$cosA
            $nx1 = $nx
            $nx2 = $nx1*$cosB - $ny1*$sinB
            $ny2 = $nx1*$sinB + $ny1*$cosB
            $nz2 = $nz1

            # Luminance -> ramp char
            $Lum = $nx2*$Lx + $ny2*$Ly + $nz2*$Lz
            $Lum = [math]::Max(-1.0, [math]::Min(1.0, $Lum))
            $t = ($Lum + 1.0) / 2.0
            $ri = [int]([math]::Floor($t * ($RampLen - 1)))
            $c = $Ramp[$ri]
            $script:NewChars[$idx] = $c
          }
        }
      }

      # Diff & draw: only rewrite changed cells (including erasing to space)
      $sb = [System.Text.StringBuilder]::new()
      [void]$sb.Append($AnsiGreen)  # Set green color once at start
      for ($y = 0; $y -le $maxY; $y++) {
        $row = $y * $bw
        for ($x = 0; $x -le $maxX; $x++) {
          $idx = $row + $x
          $n = $script:NewChars[$idx]; if ($n -eq [char]0) { $n = ' ' }
          $p = $script:PrevChars[$idx]; if ($p -eq [char]0) { $p = ' ' }
          if ($n -ne $p) {
            [void]$sb.Append("$e[$($y+1);$($x+1)H")
            [void]$sb.Append($n)
            $script:PrevChars[$idx] = $n
          }
        }
      }
      if ($sb.Length -gt 0) { [Console]::Write($sb.ToString()) }
      [Console]::Write($AnsiReset)
      $sw.Restart()
    } else {
      Start-Sleep -Milliseconds 1
    }
  }
}
finally {
  try { [Console]::TreatControlCAsInput = $origTreatCtrlC } catch {}
  [Console]::Write($AnsiReset)
  try { [Console]::CursorVisible = $originalVis } catch {}

  if ($NoHardClear) {
    try { [Console]::SetCursorPosition(0,0) } catch {}
  } else {
    try {
      $ui = $Host.UI.RawUI
      $ui.BufferSize = $ui.WindowSize
    } catch {}
    try { [Console]::Write($AnsiClearFull) } catch {}
    try { [Console]::Write($AnsiScrollUpMax) } catch {}
    try { [Console]::Write($RIS) } catch {}
  }
}
