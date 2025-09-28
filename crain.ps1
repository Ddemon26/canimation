<#
.SYNOPSIS
  ASCII Rain simulation with wind effects and themes (diff-write, cmatrix-style).

.DESCRIPTION
  - Realistic falling rain with variable speeds and wind drift.
  - Diff-only writes (rewrite changed cells; erase with space).
  - Heavy rain creates double-length streaks for visual impact.
  - Wind affects both movement and raindrop angle glyphs.
  - Any key exits; Ctrl+C treated as input. No CancelKeyPress handler.

.PARAMETER Fps
  Frames per second. Default: 60

.PARAMETER Speed
  Fall speed multiplier. Default: 1.0

.PARAMETER Density
  Raindrops per 100 screen cells. Default: 1.2

.PARAMETER Wind
  Horizontal drift in cells/sec (negative = left, positive = right). Default: 0

.PARAMETER Theme
  Default, Blue, White, Rainbow. Default: Default

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\crain.ps1
  Standard moderate rainfall.

.EXAMPLE
  .\crain.ps1 -Speed 2.5 -Density 4.0 -Wind 12
  Heavy storm with strong wind.

.EXAMPLE
  .\crain.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(10,240)][int]$Fps = 60,
  [double]$Speed = 1.0,
  [ValidateRange(0.1,50.0)][double]$Density = 1.2,
  [int]$Count = 0,
  [double]$Wind = 0.0,
  [ValidateSet('Default','Blue','White','Rainbow')][string]$Theme = 'Default',
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Rain Simulation
=====================

SYNOPSIS
    Realistic falling rain with wind effects and atmospheric themes.

USAGE
    .\crain.ps1 [OPTIONS]
    .\crain.ps1 -h

DESCRIPTION
    Dynamic rain simulation featuring realistic precipitation with wind drift,
    variable fall speeds, and atmospheric visual effects. Rain droplets respond
    to wind with both movement and angle changes, creating authentic weather
    patterns from light drizzle to heavy downpours.

OPTIONS
    -Fps <int>          Target frames per second (10-240, default: 60)
    -Speed <double>     Fall speed multiplier (default: 1.0)
    -Density <double>   Raindrops per 100 screen cells (0.1-50.0, default: 1.2)
    -Count <int>        Override automatic density with fixed drop count
    -Wind <double>      Horizontal drift speed (negative=left, positive=right, default: 0)
    -Theme <string>     Color scheme: Default, Blue, White, Rainbow (default: Default)
    -NoHardClear       Don't clear screen on exit
    -h                 Show this help and exit

RAIN PHYSICS
    - Fast gravity-driven acceleration for realistic water droplet behavior
    - Individual speed variation creates natural randomness
    - Wind affects both horizontal movement and glyph selection
    - Heavy rain (Speed > 1.2) creates double-length streaks
    - Automatic respawning maintains consistent precipitation

WIND EFFECTS
    No Wind      - Vertical droplets (|) falling straight down
    Light Wind   - Slight diagonal movement with occasional angle changes
    Strong Left  - Left-angled droplets (/) with significant drift
    Strong Right - Right-angled droplets (\) with significant drift

EXAMPLES
    .\crain.ps1
        Moderate rain with no wind

    .\crain.ps1 -Speed 2.5 -Density 4.0 -Wind 12
        Heavy thunderstorm with strong right wind

    .\crain.ps1 -Speed 0.6 -Density 0.5 -Theme Blue
        Light drizzle with blue tinting

    .\crain.ps1 -Wind -8 -Theme Rainbow
        Rainbow rain drifting left

    .\crain.ps1 -Count 300 -Speed 1.8
        Fixed 300 droplets with heavy rain effect

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - Droplet glyphs: | (vertical), / (left wind), \ (right wind)
    - Wind threshold: ±0.8 for glyph angle changes
    - Heavy rain threshold: Speed × individual_factor > 1.2
    - Density automatically scales with terminal dimensions
    - Differential rendering updates only changed screen positions

VISUAL THEMES
    Default - Natural blue-white rain coloring
    Blue    - Cool blue tones for storm effects
    White   - High contrast white precipitation
    Rainbow - Multi-colored artistic effect

WEATHER INTENSITY GUIDE
    Light Rain:    Speed 0.3-0.7, Density 0.2-0.8
    Moderate Rain: Speed 0.8-1.3, Density 0.9-2.0
    Heavy Rain:    Speed 1.4-2.0, Density 2.1-4.0
    Storm:         Speed 2.1+,    Density 4.1+

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
      3 { $r,$g,$b = $p,$v,$t; break }
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

# --- Rain Particles -------------------------------------------------------------
$script:Count = 0
$script:Px = $null  # double[] x (float for wind)
$script:Py = $null  # double[] y
$script:Pv = $null  # double[] vertical speed factor
$script:Glyph = $null # char[]

function Ensure-Raindrops([int]$bw, [int]$bh){
  $target = [int]([math]::Max(15, [math]::Round( ($Count -gt 0) ? $Count : ($Density * ($bw*$bh) / 100.0) )))
  if ($script:Count -ne $target){
    $script:Count = $target
    $script:Px = New-Object 'double[]' $target
    $script:Py = New-Object 'double[]' $target
    $script:Pv = New-Object 'double[]' $target
    $script:Glyph = New-Object 'char[]' $target
    for ($i=0; $i -lt $target; $i++){ Reset-Raindrop $bw $bh $i $true }
  }
}

function Reset-Raindrop([int]$bw, [int]$bh, [int]$i, [bool]$randomY){
  $script:Px[$i] = (Get-Random -Minimum 0.0 -Maximum ([double]$bw))
  $script:Py[$i] = if ($randomY) { (Get-Random -Minimum 0.0 -Maximum ([double]$bh)) } else { 0.0 }
  $script:Pv[$i] = Get-Random -Minimum 0.8 -Maximum 1.4  # Rain speed variation

  # Set glyph based on wind strength
  $script:Glyph[$i] = if ($Wind -gt 0.8) { '\' } elseif ($Wind -lt -0.8) { '/' } else { '|' }
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
        Ensure-Raindrops $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      $dt = $frameMs / 1000.0

      # Update raindrops
      for ($i=0; $i -lt $script:Count; $i++){
        # Rain physics - faster gravity
        $script:Py[$i] += $Speed * $script:Pv[$i] * 30.0 * $dt
        $script:Px[$i] += $Wind * $dt

        # Respawn if off-screen
        if ($script:Py[$i] -gt $bh + 1){
          Reset-Raindrop $bw $bh $i $false
        }
        if ($script:Px[$i] -lt -1){ $script:Px[$i] = $bw-1.0 }
        if ($script:Px[$i] -gt $bw){ $script:Px[$i] = 0.0 }

        # Plot raindrop
        $x = [int]([math]::Round($script:Px[$i]))
        $y = [int]([math]::Round($script:Py[$i]))
        if ($x -ge 0 -and $x -le $maxX -and $y -ge 0 -and $y -le $maxY){
          $idx = $x + $bw*$y
          $script:NewChars[$idx] = $script:Glyph[$i]

          # Rain coloring
          switch ($Theme) {
            'Default' { $packed = PackRGB 120 160 255 }  # Blue-white rain
            'Blue'    { $packed = PackRGB 100 150 255 }
            'White'   { $packed = PackRGB 235 235 235 }
            'Rainbow' {
              $h = ($i*13 + ($y*3)) % 360
              $rgb = HSV-To-RGB $h 0.9 1.0
              $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
            }
          }
          $script:NewColor[$idx] = $packed

          # Heavy rain creates streaks
          if ($Speed * $script:Pv[$i] -gt 1.2){
            $y2 = $y-1
            if ($y2 -ge 0){
              $idx2 = $x + $bw*$y2
              $script:NewChars[$idx2] = $script:Glyph[$i]
              $script:NewColor[$idx2] = $packed
            }
          }
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