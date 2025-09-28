<#
.SYNOPSIS
  ASCII Snow simulation with gentle drift and varied flake types (diff-write, cmatrix-style).

.DESCRIPTION
  - Peaceful falling snow with graceful movement and wind drift.
  - Diff-only writes (rewrite changed cells; erase with space).
  - Multiple snowflake types for visual variety and natural appearance.
  - Gentle physics with reduced wind sensitivity for realistic snow behavior.
  - Any key exits; Ctrl+C treated as input. No CancelKeyPress handler.

.PARAMETER Fps
  Frames per second. Default: 30

.PARAMETER Speed
  Fall speed multiplier. Default: 1.0

.PARAMETER Density
  Snowflakes per 100 screen cells. Default: 0.6

.PARAMETER Wind
  Horizontal drift in cells/sec (negative = left, positive = right). Default: 0

.PARAMETER Theme
  Default, Blue, White, Rainbow. Default: Default

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\csnow.ps1
  Gentle snowfall with no wind.

.EXAMPLE
  .\csnow.ps1 -Wind -3 -Theme White -Speed 0.7
  Slow snow drifting left with pure white theme.

.EXAMPLE
  .\csnow.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(10,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(0.1,20.0)][double]$Density = 0.6,
  [int]$Count = 0,
  [double]$Wind = 0.0,
  [ValidateSet('Default','Blue','White','Rainbow')][string]$Theme = 'Default',
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Snow Simulation
=====================

SYNOPSIS
    Peaceful falling snow with gentle drift and varied snowflake types.

USAGE
    .\csnow.ps1 [OPTIONS]
    .\csnow.ps1 -h

DESCRIPTION
    Serene snow simulation featuring gentle snowflakes with graceful descent
    patterns, natural wind drift, and multiple flake types for visual variety.
    Snow physics create a peaceful, contemplative atmosphere with slower fall
    speeds and reduced wind sensitivity compared to rain.

OPTIONS
    -Fps <int>          Target frames per second (10-120, default: 30)
    -Speed <double>     Fall speed multiplier (default: 1.0)
    -Density <double>   Snowflakes per 100 screen cells (0.1-20.0, default: 0.6)
    -Count <int>        Override automatic density with fixed flake count
    -Wind <double>      Horizontal drift speed (negative=left, positive=right, default: 0)
    -Theme <string>     Color scheme: Default, Blue, White, Rainbow (default: Default)
    -NoHardClear       Don't clear screen on exit
    -h                 Show this help and exit

SNOW PHYSICS
    - Gentle gravity with slower terminal velocity than rain
    - Individual speed variation creates natural randomness
    - Reduced wind sensitivity (50% of rain response) for realistic drift
    - Multiple flake types: . (small), * (medium), o (large)
    - Graceful movement patterns suitable for meditation

SNOWFLAKE TYPES
    Small Flakes (.)  - Light, subtle snowfall particles
    Medium Flakes (*) - Classic star-shaped snow crystals
    Large Flakes (o)  - Heavy, prominent snow pieces
    Random distribution creates natural variety

EXAMPLES
    .\csnow.ps1
        Gentle snowfall with mixed flake types

    .\csnow.ps1 -Wind -3 -Theme White -Speed 0.7
        Slow snow drifting left with pure white coloring

    .\csnow.ps1 -Density 1.5 -Speed 0.4
        Dense, very slow snowfall for peaceful effect

    .\csnow.ps1 -Theme Blue -Wind 2
        Cool blue snow with light right drift

    .\csnow.ps1 -Count 150 -Theme Rainbow
        Fixed 150 rainbow snowflakes (fantasy effect)

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - Snowflake selection: random choice between . * o characters
    - Gentle gravity: 8.0 cells/sec² (vs 30.0 for rain)
    - Wind response: 50% sensitivity compared to rain droplets
    - Speed variation: 0.3-0.8 multiplier for natural variation
    - Lower default framerate (30 FPS) for contemplative pace

VISUAL THEMES
    Default - Natural white/gray snow coloring
    Blue    - Cool winter blue tones
    White   - Pure white snowfall for high contrast
    Rainbow - Multi-colored artistic snow effect

WEATHER INTENSITY GUIDE
    Light Snow:     Speed 0.3-0.6, Density 0.2-0.5
    Moderate Snow:  Speed 0.7-1.0, Density 0.6-1.2
    Heavy Snow:     Speed 1.1-1.5, Density 1.3-3.0
    Blizzard:       Speed 1.6+,    Density 3.1+, Wind ±5+

PEACEFUL SETTINGS
    Meditation:     Speed 0.3, Density 0.3, Wind 0, Theme White
    Winter Evening: Speed 0.5, Density 0.8, Wind -1, Theme Default
    Cozy Indoor:    Speed 0.4, Density 0.4, Wind 1, Theme Blue

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

# Key helpers
function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

# Color helpers
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
function PackRGB([byte]$r,[byte]$g,[byte]$b){ return ([int]$r -shl 16) -bor ([int]$g -shl 8) -bor ([int]$b) }

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[]
$script:NewChars  = $null
$script:NewColor  = $null

# --- Snow Particles -------------------------------------------------------------
$script:Count = 0
$script:Px = $null  # double[] x (float for wind)
$script:Py = $null  # double[] y
$script:Pv = $null  # double[] vertical speed factor
$script:Glyph = $null # char[]

function Ensure-Snowflakes([int]$bw, [int]$bh){
  $target = [int]([math]::Max(8, [math]::Round( ($Count -gt 0) ? $Count : ($Density * ($bw*$bh) / 100.0) )))
  if ($script:Count -ne $target){
    $script:Count = $target
    $script:Px = New-Object 'double[]' $target
    $script:Py = New-Object 'double[]' $target
    $script:Pv = New-Object 'double[]' $target
    $script:Glyph = New-Object 'char[]' $target
    for ($i=0; $i -lt $target; $i++){ Reset-Snowflake $bw $bh $i $true }
  }
}

function Reset-Snowflake([int]$bw, [int]$bh, [int]$i, [bool]$randomY){
  $script:Px[$i] = (Get-Random -Minimum 0.0 -Maximum ([double]$bw))
  $script:Py[$i] = if ($randomY) { (Get-Random -Minimum 0.0 -Maximum ([double]$bh)) } else { 0.0 }
  $script:Pv[$i] = Get-Random -Minimum 0.3 -Maximum 0.8  # Snow speed variation (gentler)

  # Snowflake variety
  $r = Get-Random -Minimum 0 -Maximum 3
  $script:Glyph[$i] = ('.','*','o')[$r]
}

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)

# Save console state; hide cursor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Ctrl+C as input
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}

# Initial clear
try { [Console]::Write($AnsiClearHome) } catch {}

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }
    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2

      # Resize buffers on console size change
      $bufSize = $bw * $bh
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        Ensure-Snowflakes $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      $dt = $frameMs / 1000.0

      # Update snowflakes
      for ($i=0; $i -lt $script:Count; $i++){
        # Snow physics - gentler gravity
        $script:Py[$i] += $Speed * $script:Pv[$i] * 8.0 * $dt
        $script:Px[$i] += $Wind * $dt * 0.5  # Reduced wind sensitivity for snow

        # Respawn if off-screen
        if ($script:Py[$i] -gt $bh + 1){
          Reset-Snowflake $bw $bh $i $false
        }
        if ($script:Px[$i] -lt -1){ $script:Px[$i] = $bw-1.0 }
        if ($script:Px[$i] -gt $bw){ $script:Px[$i] = 0.0 }

        # Plot snowflake
        $x = [int]([math]::Round($script:Px[$i]))
        $y = [int]([math]::Round($script:Py[$i]))
        if ($x -ge 0 -and $x -le $maxX -and $y -ge 0 -and $y -le $maxY){
          $idx = $x + $bw*$y
          $script:NewChars[$idx] = $script:Glyph[$i]

          # Snow coloring
          switch ($Theme) {
            'Default' { $packed = PackRGB 230 230 230 }  # White-gray snow
            'Blue'    { $packed = PackRGB 180 200 255 }
            'White'   { $packed = PackRGB 245 245 245 }
            'Rainbow' {
              $h = ($i*17 + ($y*5)) % 360
              $rgb = HSV-To-RGB $h 0.7 0.9
              $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
            }
          }
          $script:NewColor[$idx] = $packed
        }
      }

      # Diff & draw
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