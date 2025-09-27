<#
.SYNOPSIS
  ASCII spinning donut (torus) that updates only changed cells per frame (no full clears).

.DESCRIPTION
  - Matches the update pattern of your cmatrix scripts: keeps a single screen "frame" and
    only rewrites spots that change, including erasing previous chars with spaces.
  - Uses precomputed trig tables and buffer reuse for speed.
  - Ctrl+C treated as input; ANY key exits. cmatrix-style shutdown (-NoHardClear supported).

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Size
  Visual scale of the donut (default: 24).

.PARAMETER Speed
  Rotation speed multiplier (default: 1.0).

.PARAMETER Quality
  Sampling quality for the torus ('Low','Medium','High','Ultra'). Default: Medium.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cdonut.ps1
  Run with default settings (medium quality donut).

.EXAMPLE
  .\cdonut.ps1 -Quality Ultra -Size 32 -Speed 0.5
  High quality large donut with slow rotation.

.EXAMPLE
  .\cdonut.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(8,80)][int]$Size = 24,
  [double]$Speed = 1.0,
  [ValidateSet('Low','Medium','High','Ultra')][string]$Quality = 'Medium',
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Spinning Donut (Torus)
=============================

SYNOPSIS
    3D spinning torus rendered in ASCII with differential updates and lighting.

USAGE
    .\cdonut.ps1 [OPTIONS]
    .\cdonut.ps1 -h

DESCRIPTION
    A mathematically accurate 3D torus (donut) that spins continuously with 
    realistic lighting effects. Uses differential rendering to update only 
    changed pixels for smooth performance. Features adjustable quality levels 
    and precomputed trigonometry tables for optimization.

OPTIONS
    -Fps <int>         Target frames per second (5-120, default: 30)
    -Size <int>        Visual scale of the donut (8-80, default: 24)
    -Speed <double>    Rotation speed multiplier (default: 1.0)
    -Quality <string>  Sampling quality: Low, Medium, High, Ultra (default: Medium)
    -NoHardClear      Don't clear screen on exit
    -h                Show this help and exit

QUALITY LEVELS
    Low     - Fast rendering, lower detail
    Medium  - Balanced performance and quality (default)
    High    - Higher detail, more computation
    Ultra   - Maximum quality, highest CPU usage

EXAMPLES
    .\cdonut.ps1
        Standard medium quality spinning donut

    .\cdonut.ps1 -Quality Ultra -Size 32 -Speed 0.5
        Large, high-quality donut with slow rotation

    .\cdonut.ps1 -Quality Low -Fps 60 -Speed 2.0
        Fast, low-detail donut at high framerate

    .\cdonut.ps1 -Size 16 -NoHardClear
        Small donut, leave screen unchanged on exit

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - Uses parametric torus equations with 3D rotation matrices
    - Implements Z-buffer depth testing for proper occlusion
    - ASCII luminance ramp: " .:-=+*#%@" (dark to bright)
    - Differential rendering updates only changed screen positions
    - Precomputed trigonometry tables for performance optimization
    - Realistic lighting with configurable light direction

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

# Key helpers (non-blocking)
function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

# --- Math / util ----------------------------------------------------------------
$Ramp = " .:-=+*#%@"
$RampLen = $Ramp.Length
$R1 = 1.0   # tube radius
$R2 = 2.0   # ring radius
$K2 = 5.0   # camera distance

# Cached buffers and trig tables
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null   # char[]
$script:NewChars  = $null   # char[]
$script:ZBuf      = $null   # double[]
$script:ThetaSin = $null
$script:ThetaCos = $null
$script:PhiSin   = $null
$script:PhiCos   = $null
$script:ThetaCount = 0
$script:PhiCount   = 0

function Init-DonutTables(){
  switch ($Quality) {
    'Low'    { $thetaStep = 0.12; $phiStep = 0.06 }
    'Medium' { $thetaStep = 0.09; $phiStep = 0.04 }
    'High'   { $thetaStep = 0.07; $phiStep = 0.03 }
    'Ultra'  { $thetaStep = 0.05; $phiStep = 0.02 }
    default  { $thetaStep = 0.09; $phiStep = 0.04 }
  }
  $script:ThetaCount = [int]([math]::Ceiling(6.283185307179586 / $thetaStep))
  $script:PhiCount   = [int]([math]::Ceiling(6.283185307179586 / $phiStep))

  $script:ThetaSin = New-Object 'double[]' ($script:ThetaCount)
  $script:ThetaCos = New-Object 'double[]' ($script:ThetaCount)
  for ($i=0; $i -lt $script:ThetaCount; $i++){
    $t = $i * (6.283185307179586 / $script:ThetaCount)
    $script:ThetaSin[$i] = [math]::Sin($t)
    $script:ThetaCos[$i] = [math]::Cos($t)
  }
  $script:PhiSin = New-Object 'double[]' ($script:PhiCount)
  $script:PhiCos = New-Object 'double[]' ($script:PhiCount)
  for ($j=0; $j -lt $script:PhiCount; $j++){
    $p = $j * (6.283185307179586 / $script:PhiCount)
    $script:PhiSin[$j] = [math]::Sin($p)
    $script:PhiCos[$j] = [math]::Cos($p)
  }
}

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$A = 0.0; $B = 0.0  # rotation angles

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
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2     # avoid last row to prevent scroll
      $cx = [int]([math]::Floor($bw/2))
      $cy = [int]([math]::Floor($bh/2))
      $aspect = if ($bh -gt 0){ [double]$bw / [double]$bh } else { 1.0 }
      $K1 = [double]$Size

      # Resize buffers on console size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bw * $bh)
        $script:NewChars  = New-Object 'char[]' ($bw * $bh)
        $script:ZBuf      = New-Object 'double[]' ($bw * $bh)
        Init-DonutTables
        # clear screen once on resize
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:ZBuf, 0, $script:ZBuf.Length)

      # Update rotation
      $dt = $frameMs / 1000.0
      $A += ($Speed * 0.9 * $dt)
      $B += ($Speed * 0.6 * $dt)
      $cosA=[math]::Cos($A); $sinA=[math]::Sin($A)
      $cosB=[math]::Cos($B); $sinB=[math]::Sin($B)

      # Light direction (normalized)
      $Lx = 0.0; $Ly = 1.0; $Lz = -1.0
      $invL = [math]::Sqrt($Lx*$Lx + $Ly*$Ly + $Lz*$Lz)
      $Lx /= $invL; $Ly /= $invL; $Lz /= $invL

      # Sweep torus using precomputed tables
      for ($j=0; $j -lt $script:PhiCount; $j++){
        $cosPhi = $script:PhiCos[$j]; $sinPhi = $script:PhiSin[$j]
        for ($i=0; $i -lt $script:ThetaCount; $i++){
          $cosTheta = $script:ThetaCos[$i]; $sinTheta = $script:ThetaSin[$i]

          $circlex = $R2 + $R1 * $cosTheta
          $circley = $R1 * $sinTheta
          $x = $circlex * $cosPhi
          $y = $circlex * $sinPhi
          $z = $circley

          # Rotate around X by A, then Z by B (Rx(A) * Rz(B))
          $y1 = $y*$cosA - $z*$sinA
          $z1 = $y*$sinA + $z*$cosA
          $x1 = $x
          $x2 = $x1*$cosB - $y1*$sinB
          $y2 = $x1*$sinB + $y1*$cosB
          $z2 = $z1

          # Project
          $zCam = $z2 + $K2
          if ($zCam -le 0.001){ $zCam = 0.001 }
          $ooz = 1.0 / $zCam
          $xp = [int]([math]::Round($cx + $K1 * $aspect * $x2 * $ooz))
          $yp = [int]([math]::Round($cy - $K1 * $y2 * $ooz))

          if ($xp -ge 0 -and $xp -le $maxX -and $yp -ge 0 -and $yp -le $maxY){
            $idx = $xp + $bw * $yp
            if ($ooz -gt $script:ZBuf[$idx]){
              $script:ZBuf[$idx] = $ooz

              # Normal (pre-rotation)
              $nx = $cosTheta * $cosPhi
              $ny = $cosTheta * $sinPhi
              $nz = $sinTheta
              # Rotate normal by same Rx(A) then Rz(B)
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
      }

      # Diff & draw: only rewrite changed cells (including erasing to space)
      $sb = [System.Text.StringBuilder]::new()
      for ($y=0; $y -le $maxY; $y++){
        $row = $y * $bw
        for ($x=0; $x -le $maxX; $x++){
          $idx = $row + $x
          $n = $script:NewChars[$idx]; if ($n -eq [char]0){ $n = ' ' }
          $p = $script:PrevChars[$idx]; if ($p -eq [char]0){ $p = ' ' }
          if ($n -ne $p){
            [void]$sb.Append("$e[$($y+1);$($x+1)H")
            [void]$sb.Append($n)
            $script:PrevChars[$idx] = $n
          }
        }
      }
      if ($sb.Length -gt 0){ [Console]::Write($sb.ToString()) }
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
