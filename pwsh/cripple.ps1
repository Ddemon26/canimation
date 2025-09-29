<#
.SYNOPSIS
  ASCII water ripple simulation with interactive raindrop spawning (diff-write, cmatrix-style).

.DESCRIPTION
  - Simulates water surface with realistic wave propagation physics
  - Automatic raindrop generation at configurable intervals
  - Multiple ripple modes: Classic, Rainbow, Monochrome, Heat
  - Keeps a persistent frame and only rewrites cells that changed
  - Uses 2D wave equation with damping for realistic water physics
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Wave propagation speed multiplier (default: 1.0).

.PARAMETER Damping
  Wave damping factor (0.90-0.99). Higher = longer lasting ripples (default: 0.96).

.PARAMETER DropRate
  Raindrops spawned per second (default: 2.0).

.PARAMETER Mode
  Ripple visualization mode: Classic, Rainbow, Monochrome, Heat (default: Classic).

.PARAMETER Amplitude
  Initial ripple strength (1-10, default: 5).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cripple.ps1
  Run with default classic blue water ripples.

.EXAMPLE
  .\cripple.ps1 -Mode Rainbow -DropRate 5.0
  Rainbow ripples with frequent raindrops.

.EXAMPLE
  .\cripple.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(0.90,0.99)][double]$Damping = 0.96,
  [double]$DropRate = 2.0,
  [ValidateSet('Classic','Rainbow','Monochrome','Heat')][string]$Mode = 'Classic',
  [ValidateRange(1,10)][int]$Amplitude = 5,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Water Ripple Simulation
==============================

SYNOPSIS
    Realistic water surface simulation with raindrop physics and wave propagation.

USAGE
    .\cripple.ps1 [OPTIONS]
    .\cripple.ps1 -h

DESCRIPTION
    Beautiful water ripple effect using 2D wave equation physics. Raindrops
    create expanding circular waves that interact and interfere with each other.
    Features multiple visualization modes and realistic wave damping.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Speed <double>     Wave propagation speed (default: 1.0)
    -Damping <double>   Wave persistence (0.90-0.99, default: 0.96)
    -DropRate <double>  Raindrops per second (default: 2.0)
    -Mode <string>      Visualization mode (default: Classic)
    -Amplitude <int>    Ripple strength (1-10, default: 5)
    -NoHardClear       Don't clear screen on exit
    -h                 Show this help and exit

MODES
    Classic     Deep blue water with intensity-based shading
    Rainbow     Colored ripples based on wave phase
    Monochrome  Black and white ASCII art waves
    Heat        Thermal visualization (cool to hot)

PHYSICS
    - Uses 2D wave equation for realistic propagation
    - Damping factor creates natural energy dissipation
    - Wave interference creates complex patterns
    - Circular wavefronts expand from drop points

EXAMPLES
    .\cripple.ps1
        Classic blue water with moderate raindrop rate

    .\cripple.ps1 -Mode Rainbow -DropRate 5.0 -Amplitude 8
        Frequent, strong rainbow ripples

    .\cripple.ps1 -Mode Heat -Damping 0.98 -Speed 0.5
        Slow, persistent heat-map style ripples

    .\cripple.ps1 -Mode Monochrome -DropRate 1.0 -Fps 60
        Minimal high-framerate black and white waves

    .\cripple.ps1 -Speed 2.0 -Amplitude 3
        Fast, subtle ripples

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Higher damping values create longer-lasting ripples
    - Wave speed affects how quickly ripples expand
    - Multiple drops create interference patterns
    - Terminal size affects simulation resolution
    - Uses differential rendering for smooth performance

"@
    Write-Host $helpText
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- ANSI helpers ---------------------------------------------------------------
$e = "`e"
function Set-FG([byte]$r,[byte]$g,[byte]$b){ "$e[38;2;${r};${g};${b}m" }
$AnsiReset       = "$e[0m"
$AnsiClearHome   = "$e[2J$e[H"
$AnsiClearFull   = "$e[3J$e[2J$e[H"
$AnsiScrollUpMax = "$e[9999S"
$RIS             = "$e" + "c"

# Key helpers (non-blocking)
function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

# --- Color helpers --------------------------------------------------------------
function PackRGB([byte]$r,[byte]$g,[byte]$b){ return ([int]$r -shl 16) -bor ([int]$g -shl 8) -bor ([int]$b) }
function HSV-To-RGB([double]$h, [double]$s, [double]$v){
  if ($s -le 0){ $r=$v; $g=$v; $b=$v }
  else {
    $hh = ($h % 360) / 60.0
    $i  = [int][math]::Floor($hh)
    $ff = $hh - $i
    $p = $v * (1.0 - $s)
    $q = $v * (1.0 - ($s * $ff))
    $t = $v * (1.0 - ($s * (1.0 - $ff)))
    switch ($i) {
      0 { $r,$g,$b = $v,$t,$p; break }
      1 { $r,$g,$b = $q,$v,$p; break }
      2 { $r,$g,$b = $p,$v,$t; break }
      3 { $r,$g,$b = $p,$q,$v; break }
      4 { $r,$g,$b = $t,$p,$v; break }
      default { $r,$g,$b = $v,$p,$q }
    }
  }
  return ,([byte[]]@([byte]([math]::Round($r*255)),[byte]([math]::Round($g*255)),[byte]([math]::Round($b*255))))
}

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# Wave simulation buffers (2D wave equation needs current and previous state)
$script:Wave      = $null  # double[] current wave height
$script:WavePrev  = $null  # double[] previous wave height
$script:WaveVel   = $null  # double[] wave velocity for damping

$rnd = [System.Random]::new()

# ASCII ramps for different modes
$RampClassic = " ·:~-=+*#@"
$RampMono    = " .:-=+*#%@"
$RampHeat    = " .:-=+*#%@"

# --- Wave physics ---------------------------------------------------------------
function Clamp([double]$v, [double]$lo, [double]$hi){
  if ($v -lt $lo){$lo} elseif ($v -gt $hi){$hi} else {$v}
}

function Spawn-Raindrop([int]$bw, [int]$bh){
  $x = $rnd.Next(2, $bw - 2)
  $y = $rnd.Next(2, $bh - 2)
  $idx = $x + $bw * $y
  $script:Wave[$idx] = [double]$Amplitude * 10.0
}

function Update-WavePhysics([int]$bw, [int]$bh){
  $waveSpeed = 0.5 * $Speed

  # 2D wave equation: acceleration = c^2 * laplacian
  for ($y = 1; $y -lt ($bh - 1); $y++){
    for ($x = 1; $x -lt ($bw - 1); $x++){
      $idx = $x + $bw * $y
      $center = $script:Wave[$idx]

      # Laplacian (4-neighbor stencil)
      $left   = $script:Wave[($x-1) + $bw * $y]
      $right  = $script:Wave[($x+1) + $bw * $y]
      $up     = $script:Wave[$x + $bw * ($y-1)]
      $down   = $script:Wave[$x + $bw * ($y+1)]

      $laplacian = ($left + $right + $up + $down - 4.0 * $center)

      # Wave equation with damping
      $accel = $waveSpeed * $laplacian
      $script:WaveVel[$idx] += $accel
      $script:WaveVel[$idx] *= $Damping  # Apply damping
    }
  }

  # Update positions
  for ($y = 0; $y -lt $bh; $y++){
    for ($x = 0; $x -lt $bw; $x++){
      $idx = $x + $bw * $y
      $script:Wave[$idx] += $script:WaveVel[$idx]

      # Clamp to prevent overflow
      if ($script:Wave[$idx] -gt 100.0){ $script:Wave[$idx] = 100.0 }
      if ($script:Wave[$idx] -lt -100.0){ $script:Wave[$idx] = -100.0 }
    }
  }
}

function Wave-To-CharColor([double]$waveVal, [int]$x, [int]$y){
  # Normalize wave value to 0..1 range
  $normalized = Clamp (($waveVal / 40.0) + 0.5) 0.0 1.0

  switch ($Mode) {
    'Classic' {
      # Blue water shading
      $intensity = $normalized
      $rampIdx = [int]([math]::Floor($intensity * ($RampClassic.Length - 1)))
      $ch = $RampClassic[$rampIdx]

      $blueness = [byte]([math]::Round(100 + $intensity * 155))
      $col = PackRGB 20 ([byte]([math]::Round(50 + $intensity * 100))) $blueness
      return @($ch, $col)
    }
    'Rainbow' {
      # Color based on wave phase
      $hue = (($waveVal * 20.0 + $x * 5 + $y * 5) % 360 + 360) % 360
      $rgb = HSV-To-RGB $hue 0.8 (0.5 + $normalized * 0.5)

      $rampIdx = [int]([math]::Floor($normalized * ($RampClassic.Length - 1)))
      $ch = $RampClassic[$rampIdx]
      $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
      return @($ch, $col)
    }
    'Monochrome' {
      # Black and white
      $rampIdx = [int]([math]::Floor($normalized * ($RampMono.Length - 1)))
      $ch = $RampMono[$rampIdx]

      $gray = [byte]([math]::Round($normalized * 255))
      $col = PackRGB $gray $gray $gray
      return @($ch, $col)
    }
    'Heat' {
      # Heat map coloring
      $rampIdx = [int]([math]::Floor($normalized * ($RampHeat.Length - 1)))
      $ch = $RampHeat[$rampIdx]

      if ($normalized -lt 0.5){
        $t = $normalized * 2.0
        $r = [byte]0
        $g = [byte]([math]::Round($t * 255))
        $b = [byte]([math]::Round((1.0 - $t) * 255))
      } else {
        $t = ($normalized - 0.5) * 2.0
        $r = [byte]([math]::Round($t * 255))
        $g = [byte]([math]::Round((1.0 - $t) * 255))
        $b = [byte]0
      }
      $col = PackRGB $r $g $b
      return @($ch, $col)
    }
    default {
      return @(' ', (PackRGB 0 100 200))
    }
  }
}

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$dropTimer = 0.0

# Save console state; hide cursor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Treat Ctrl+C as input
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}

# Initial clear
try { [Console]::Write($AnsiClearHome) } catch {}

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $dt = $frameMs / 1000.0
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2  # avoid last row

      # (Re)alloc buffers on size change
      $bufSize = $bw * $bh
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        $script:Wave      = New-Object 'double[]' ($bufSize)
        $script:WavePrev  = New-Object 'double[]' ($bufSize)
        $script:WaveVel   = New-Object 'double[]' ($bufSize)

        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Spawn raindrops
      $dropTimer += $dt
      $dropInterval = 1.0 / $DropRate
      while ($dropTimer -ge $dropInterval){
        Spawn-Raindrop $bw $bh
        $dropTimer -= $dropInterval
      }

      # Update wave physics
      Update-WavePhysics $bw $bh

      # Render wave to buffers
      for ($y = 0; $y -le $maxY; $y++){
        for ($x = 0; $x -le $maxX; $x++){
          $idx = $x + $bw * $y
          $waveVal = $script:Wave[$idx]

          $result = Wave-To-CharColor $waveVal $x $y
          $script:NewChars[$idx] = $result[0]
          $script:NewColor[$idx] = $result[1]
        }
      }

      # Diff & draw only changed cells
      $sb = [System.Text.StringBuilder]::new()
      $lastPacked = -1
      for ($y=0; $y -le $maxY; $y++){
        $row = $y * $bw
        for ($x=0; $x -le $maxX; $x++){
          $idx = $row + $x
          $nch = $script:NewChars[$idx]; if ($nch -eq [char]0){ $nch = ' ' }
          $ncol = $script:NewColor[$idx]
          $pch = $script:PrevChars[$idx]; if ($pch -eq [char]0){ $pch = ' ' }
          $pcol = $script:PrevColor[$idx]

          if (($nch -ne $pch) -or ($ncol -ne $pcol)){
            [void]$sb.Append("$e[$($y+1);$($x+1)H")
            if ($nch -eq ' '){
              [void]$sb.Append(' ')
              $script:PrevChars[$idx] = ' '
              $script:PrevColor[$idx] = 0
            } else {
              if ($ncol -ne $lastPacked){
                $r = [byte](($ncol -shr 16) -band 0xFF)
                $g = [byte](($ncol -shr 8)  -band 0xFF)
                $b = [byte]($ncol -band 0xFF)
                [void]$sb.Append( (Set-FG $r $g $b) )
                $lastPacked = $ncol
              }
              [void]$sb.Append($nch)
              $script:PrevChars[$idx] = $nch
              $script:PrevColor[$idx] = $ncol
            }
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