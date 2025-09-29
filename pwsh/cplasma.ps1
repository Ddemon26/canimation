<#
.SYNOPSIS
  ASCII Fire / Plasma effect with gradient ramps (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites changed cells (erasing with spaces as needed).
  - Two modes:
      * Fire   — vertical heat bias + flicker, black→red→orange→yellow→white ramp.
      * Plasma — classic 2D sine-plasma with rainbow ramp.
  - ASCII-only glyph ramp maps intensity to characters.
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Animation speed multiplier (default: 1.0).

.PARAMETER Mode
  'Fire' or 'Plasma' (default: Fire).

.PARAMETER Ramp
  ASCII glyph ramp (dark→bright). Default: " .:-=+*#%@"

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.EXAMPLE
  .\cplasma.ps1
  Run with default Fire mode.

.EXAMPLE
  .\cplasma.ps1 -Mode Plasma
  Classic sine-wave plasma effect.

.EXAMPLE
  .\cplasma.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateSet('Fire','Plasma')][string]$Mode = 'Fire',
  [string]$Ramp = " .:-=+*#%@",
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Fire / Plasma Effect
===========================

SYNOPSIS
    Animated fire or plasma effects with ASCII characters and color gradients.

USAGE
    .\cplasma.ps1 [OPTIONS]
    .\cplasma.ps1 -h

DESCRIPTION
    Creates dynamic visual effects using ASCII characters and color gradients.
    Fire mode simulates flickering flames rising upward, while Plasma mode
    creates classic demoscene-style sine wave patterns. Uses differential
    rendering for smooth performance.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Speed <double>     Animation speed multiplier (default: 1.0)
    -Mode <string>      Effect mode: Fire or Plasma (default: Fire)
    -Ramp <string>      ASCII brightness ramp (default: " .:-=+*#%@")
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

MODES
    Fire
        Simulates rising flames with flickering effect
        Color gradient: black → red → orange → yellow → white
        Heat rises from bottom with natural flicker
        Vertical bias creates realistic fire movement

    Plasma
        Classic 2D sine-wave plasma effect
        Rainbow color gradient with smooth transitions
        Multiple sine waves interfere to create patterns
        Psychedelic, mesmerizing visual effect

EXAMPLES
    .\cplasma.ps1
        Default fire effect

    .\cplasma.ps1 -Mode Plasma
        Rainbow plasma effect

    .\cplasma.ps1 -Mode Fire -Speed 1.5 -Fps 60
        Fast, high-framerate fire

    .\cplasma.ps1 -Mode Plasma -Speed 0.5
        Slow, dreamy plasma waves

    .\cplasma.ps1 -Ramp " .-+*%@#"
        Custom ASCII gradient ramp

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Fire mode uses realistic heat simulation with upward bias
    - Plasma mode creates classic demoscene-style effects
    - Ramp parameter controls ASCII character progression
    - Higher Speed values create faster, more energetic animations
    - Uses differential rendering (only updates changed cells)

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

# Fire palette (stops)
$FireStops = @(
  @{t=0.00; r=0;   g=0;   b=0  }
  @{t=0.20; r=120; g=0;   b=0  }
  @{t=0.40; r=200; g=40;  b=0  }
  @{t=0.60; r=255; g=100; b=0  }
  @{t=0.80; r=255; g=170; b=0  }
  @{t=1.00; r=255; g=255; b=230}
)
function Fire-Color([double]$t){
  if ($t -le 0){ return (PackRGB 0 0 0) }
  if ($t -ge 1){ return (PackRGB 255 255 230) }
  for ($i=1; $i -lt $FireStops.Count; $i++){
    $a = $FireStops[$i-1]; $b = $FireStops[$i]
    if ($t -le $b.t){
      $u = ($t - $a.t) / ([double]($b.t - $a.t))
      $r = [byte]([math]::Round($a.r + ($b.r - $a.r)*$u))
      $g = [byte]([math]::Round($a.g + ($b.g - $a.g)*$u))
      $b2= [byte]([math]::Round($a.b + ($b.b - $a.b)*$u))
      return (PackRGB $r $g $b2)
    }
  }
  return (PackRGB 255 255 230)
}

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$t = 0.0

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

# Validate ramp
if ([string]::IsNullOrEmpty($Ramp) -or $Ramp.Length -lt 2){ $Ramp = " .:-=+*#%@" }
$RampLen = $Ramp.Length

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2
      $bufSize = $bw * $bh

      # Resize buffers on console size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time advance
      $dt = $frameMs / 1000.0
      $t += ($Speed * 2.0 * $dt)

      # Precompute constants
      $fx = 9.0; $fy = 5.0
      $ux = 12.0; $uy = 7.0

      for ($y=0; $y -le $maxY; $y++){
        $row = $y * $bw
        $vn = [double]$y / [double][math]::Max(1,$maxY)   # 0 at top ... 1 at bottom
        for ($x=0; $x -le $maxX; $x++){
          $un = [double]$x / [double][math]::Max(1,$maxX)

          if ($Mode -eq 'Plasma'){
            # Sine plasma
            $v =
              [math]::Sin(($un*$fx + $t)) +
              [math]::Sin(($vn*$fy + $t*1.31)) +
              [math]::Sin(($un*$ux + $vn*$uy + $t*0.71))
            $v = ($v / 3.0 + 1.0) * 0.5  # -> [0..1]
            $h = ($v*360.0 + ($t*40.0)) % 360
            $rgb = HSV-To-RGB $h 1.0 1.0
            $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
          } else {
            # Fire: bias by depth from bottom, add flicker
            $base = 1.0 - $vn
            $wav = 0.6*[math]::Sin($un*12.0 + $t*2.2) + 0.4*[math]::Sin($un*28.0 + $t*1.7)
            # row flicker pseudo-noise
            $flick = 0.25*[math]::Sin(($y*0.21 + $t*3.3)) * [math]::Sin(($x*0.17 + $t*2.7))
            $v = [math]::Max(0.0, [math]::Min(1.0, $base*0.7 + 0.3*($wav*0.5+0.5) + $flick))
            # slight vertical blur effect (brighten near bottom few rows)
            if ($y -gt $maxY - 3){ $v = [math]::Min(1.0, $v + 0.15) }
            $packed = Fire-Color $v
          }

          # ASCII glyph from intensity
          $ri = [int]([math]::Floor($v * ($RampLen - 1)))
          $ch = $Ramp[$ri]

          $idx = $row + $x
          $script:NewChars[$idx] = $ch
          $script:NewColor[$idx] = $packed
        }
      }

      # Diff & draw (char OR color changed)
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
