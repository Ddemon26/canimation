<#
.SYNOPSIS
  ASCII Fireflies – wandering glow dots with gentle flocking behavior (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent frame and only rewrites cells that changed (including erasing with spaces).
  - Gentle flocking behavior: loose cohesion, soft separation, meandering motion.
  - Fireflies pulse and glow with warm colors and fading trails.
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Global speed multiplier (default: 1.0).

.PARAMETER Count
  Number of fireflies (default: 25).

.PARAMETER Cohesion
  Cohesion strength for flocking (default: 0.3).

.PARAMETER ViewRadius
  Neighbor radius in cells (default: 12).

.PARAMETER Glow
  Enable glow trails (default: on).

.PARAMETER Pulse
  Enable brightness pulsing (default: on).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cfireflies.ps1
  Run with default settings (25 fireflies with glow and pulse).

.EXAMPLE
  .\cfireflies.ps1 -Count 50 -Speed 0.5 -Cohesion 0.1
  More fireflies with slower, more independent movement.

.EXAMPLE
  .\cfireflies.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(5,200)][int]$Count = 25,
  [ValidateRange(0.1,2.0)][double]$Cohesion = 0.3,
  [ValidateRange(4,40)][int]$ViewRadius = 12,
  [switch]$Glow = $true,
  [switch]$Pulse = $true,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Fireflies Simulation
===========================

SYNOPSIS
    Gentle fireflies with warm glow, pulsing, and organic flocking behavior.

USAGE
    .\cfireflies.ps1 [OPTIONS]
    .\cfireflies.ps1 -h

DESCRIPTION
    A peaceful simulation of fireflies dancing through the night. Features 
    gentle flocking behavior with wandering motion, warm pulsing colors, 
    and fading glow trails. Uses soft physics and organic movement patterns 
    to create a relaxing natural atmosphere.

OPTIONS
    -Fps <int>         Target frames per second (5-120, default: 30)
    -Speed <double>    Global movement speed multiplier (default: 1.0)
    -Count <int>       Number of fireflies (5-200, default: 25)
    -Cohesion <double> Flocking cohesion strength (0.1-2.0, default: 0.3)
    -ViewRadius <int>  Neighbor detection radius (4-40, default: 12)
    -Glow             Enable fading glow trails (default: on)
    -Pulse            Enable brightness pulsing (default: on)
    -NoHardClear      Don't clear screen on exit
    -h                Show this help and exit

BEHAVIOR
    - Gentle flocking with loose cohesion and soft separation
    - Random wandering creates organic, unpredictable movement
    - Warm yellow-orange colors simulate realistic firefly bioluminescence
    - Individual pulsing phases create natural variation
    - Soft edge repulsion keeps fireflies in view
    - Glow trails fade gradually for atmospheric effect

EXAMPLES
    .\cfireflies.ps1
        Standard peaceful firefly scene

    .\cfireflies.ps1 -Count 50 -Speed 0.5 -Cohesion 0.1
        More fireflies with slower, independent movement

    .\cfireflies.ps1 -Count 15 -ViewRadius 20 -Cohesion 0.8
        Fewer fireflies with stronger flocking behavior

    .\cfireflies.ps1 -Speed 2.0 -Pulse:$false
        Fast-moving fireflies without pulsing

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - Combines flocking algorithms with random wandering behavior
    - Warm HSV color palette (35-55° hue range) for realistic firefly colors
    - Gentle physics with velocity damping for smooth motion
    - Intensity-based glow trail rendering with exponential decay
    - Soft boundary handling prevents harsh edge collisions
    - Individual phase offsets create natural pulsing variation

ATMOSPHERIC FEATURES
    - Glow trails use diminishing intensity with character gradation
    - Pulsing brightness follows individual sine wave patterns
    - Warm color temperature creates cozy evening ambiance
    - Gentle separation prevents clustering while maintaining flocking
    - Speed limitations ensure contemplative, peaceful movement

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
$script:Intens    = $null  # double[] per-cell intensity for glow trails

# --- Fireflies list -------------------------------------------------------------
$Fireflies = New-Object System.Collections.Generic.List[object]
$rnd = [System.Random]::new()

function Init-Fireflies([int]$n, [int]$bw, [int]$bh){
  $Fireflies.Clear()
  for ($i=0; $i -lt $n; $i++){
    $x = $rnd.NextDouble()*($bw-1)
    $y = $rnd.NextDouble()*($bh-3)  # avoid bottom row
    $ang = $rnd.NextDouble()*6.283185307179586
    $sp = 0.3 + 0.4*$rnd.NextDouble()  # gentler than boids
    $vx = [math]::Cos($ang) * $sp * 8.0 * $Speed  # much slower than boids
    $vy = [math]::Sin($ang) * $sp * 8.0 * $Speed
    $hue = 45.0 + 25.0*($rnd.NextDouble()-0.5)  # warm yellows 35-55°
    $phase = $rnd.NextDouble()*6.283185307179586  # for pulsing
    $wanderAngle = $rnd.NextDouble()*6.283185307179586  # for random steering
    $Fireflies.Add([pscustomobject]@{ 
      x=[double]$x; y=[double]$y; vx=[double]$vx; vy=[double]$vy;
      hue=[double]$hue; phase=[double]$phase; wanderAngle=[double]$wanderAngle;
      brightness=[double](0.7 + 0.3*$rnd.NextDouble())
    })
  }
}

function Clamp([double]$v, [double]$lo, [double]$hi){ if ($v -lt $lo){$lo} elseif ($v -gt $hi){$hi} else {$v} }

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$time = 0.0

# Save console state; hide cursor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Treat Ctrl+C as input (avoid CancelKeyPress runspace handler)
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
      $bufSize = $bw * $bh

      # Resize buffers / reset on size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        $script:Intens    = New-Object 'double[]' ($bufSize)
        Init-Fireflies $Count $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      } elseif ($Fireflies.Count -ne $Count){
        Init-Fireflies $Count $bw $bh
      }

      # Fast clear New buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Decay glow trails
      if ($Glow) {
        for ($i=0; $i -lt $script:Intens.Length; $i++){
          $script:Intens[$i] *= 0.88  # gentle fade
          if ($script:Intens[$i] -lt 0.01){ $script:Intens[$i] = 0.0 }
        }
      }

      # Time step
      $dt = $frameMs / 1000.0
      $time += $dt

      # --- Firefly flocking update ------------------------------------------------
      $vr2 = [double]$ViewRadius * [double]$ViewRadius
      for ($i=0; $i -lt $Fireflies.Count; $i++){
        $f = $Fireflies[$i]
        $sumx = 0.0; $sumy = 0.0; $n = 0
        $sepx = 0.0; $sepy = 0.0

        # Find neighbors for gentle cohesion
        for ($j=0; $j -lt $Fireflies.Count; $j++){
          if ($j -eq $i){ continue }
          $o = $Fireflies[$j]
          $dx = $o.x - $f.x
          $dy = $o.y - $f.y
          $d2 = $dx*$dx + $dy*$dy
          if ($d2 -le $vr2 -and $d2 -gt 0){
            $sumx += $o.x; $sumy += $o.y; $n++
            # Very gentle separation (closer than 3 cells)
            if ($d2 -le 9.0){
              $inv = 1.0 / [math]::Sqrt($d2)
              $sepx -= $dx * $inv * 0.2  # much gentler than boids
              $sepy -= $dy * $inv * 0.2
            }
          }
        }

        $ax = 0.0; $ay = 0.0
        
        # Gentle cohesion toward neighbors
        if ($n -gt 0){
          $invn = 1.0 / $n
          $cx = ($sumx * $invn) - $f.x
          $cy = ($sumy * $invn) - $f.y
          $ax += $Cohesion * $cx * 0.5  # much gentler
          $ay += $Cohesion * $cy * 0.5
        }

        # Gentle separation
        $ax += $sepx
        $ay += $sepy

        # Random wandering (key firefly behavior)
        $f.wanderAngle += ($rnd.NextDouble()-0.5) * 0.6 * $dt
        $wanderStrength = 0.8
        $ax += [math]::Cos($f.wanderAngle) * $wanderStrength
        $ay += [math]::Sin($f.wanderAngle) * $wanderStrength

        # Update velocity with damping
        $f.vx = ($f.vx + $ax * $dt) * 0.95  # gentle damping
        $f.vy = ($f.vy + $ay * $dt) * 0.95

        # Speed clamp (much lower than boids)
        $spd2 = $f.vx*$f.vx + $f.vy*$f.vy
        $maxSpd = 12.0 * $Speed
        if ($spd2 -gt $maxSpd*$maxSpd){
          $scale = $maxSpd / [math]::Sqrt($spd2)
          $f.vx *= $scale; $f.vy *= $scale
        }

        # Position update
        $f.x += $f.vx * $dt
        $f.y += $f.vy * $dt

        # Soft edge handling (gentle repulsion, not bouncing)
        $margin = 3.0
        if ($f.x -lt $margin){ $f.vx += (5.0 * $dt) }
        if ($f.x -gt $maxX - $margin){ $f.vx -= (5.0 * $dt) }
        if ($f.y -lt $margin){ $f.vy += (5.0 * $dt) }
        if ($f.y -gt $maxY - $margin){ $f.vy -= (5.0 * $dt) }

        # Keep in bounds
        $f.x = Clamp $f.x 0.0 ([double]$maxX)
        $f.y = Clamp $f.y 0.0 ([double]$maxY)

        # Update pulse phase
        $f.phase += 2.5 * $dt

        # Render firefly
        $ix = [int]([math]::Round($f.x))
        $iy = [int]([math]::Round($f.y))
        if ($ix -ge 0 -and $ix -le $maxX -and $iy -ge 0 -and $iy -le $maxY){
          # Pulsing brightness
          $brightness = $f.brightness
          if ($Pulse){
            $pulseVal = 0.6 + 0.4*[math]::Sin($f.phase)
            $brightness *= $pulseVal
          }
          
          # Warm firefly colors
          $rgb = HSV-To-RGB $f.hue 0.8 $brightness
          $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
          
          $idx = $ix + $bw*$iy
          $script:NewChars[$idx] = '*'
          $script:NewColor[$idx] = $col

          # Add to glow trail
          if ($Glow){
            $glowVal = $brightness * 0.6
            if ($script:Intens[$idx] -lt $glowVal){
              $script:Intens[$idx] = $glowVal
            }
          }
        }
      }

      # Render glow trails
      if ($Glow){
        for ($y=0; $y -le $maxY; $y++){
          $row = $y * $bw
          for ($x=0; $x -le $maxX; $x++){
            $idx = $row + $x
            $intensity = $script:Intens[$idx]
            if ($intensity -gt 0.02 -and $script:NewChars[$idx] -eq [char]0){
              # Glow character based on intensity
              if ($intensity -gt 0.4) { $ch = '.' }
              elseif ($intensity -gt 0.15) { $ch = ',' }
              else { $ch = ' '; continue }  # too dim
              
              # Dim warm glow color
              $hue = 50.0  # warm yellow-orange
              $rgb = HSV-To-RGB $hue 0.6 ($intensity * 0.8)
              $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
              
              $script:NewChars[$idx] = $ch
              $script:NewColor[$idx] = $col
            }
          }
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
