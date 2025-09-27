<#
.SYNOPSIS
  ASCII Fireworks / Confetti with per-cell intensity fade (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent frame; only rewrites cells that changed (erases with spaces as needed).
  - Per-cell intensity buffer decays each frame to create fading trails/glow.
  - Modes:
      * Fireworks – radial explosions, gravity, drag, colorful sparks.
      * Confetti  – falling colored pieces with lateral wobble.
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Global speed multiplier for motion (default: 1.0).

.PARAMETER Mode
  'Fireworks' or 'Confetti' (default: Fireworks).

.PARAMETER Ramp
  ASCII glyph ramp (dark→bright). Default: " .:-=+*#%@"

.PARAMETER Decay
  Per-frame intensity decay factor (0.80..0.99). Higher = longer trails. Default: 0.90.

.PARAMETER BurstRate
  Average fireworks bursts per second (Mode=Fireworks). Default: 1.5.

.PARAMETER Particles
  Number of particles per burst (Mode=Fireworks). Default: 80.

.PARAMETER ConfettiRate
  Pieces spawned per second (Mode=Confetti). Default: 60.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cfireworks.ps1
  Run with default fireworks mode.

.EXAMPLE
  .\cfireworks.ps1 -Mode Confetti -ConfettiRate 120
  Confetti mode with lots of falling pieces.

.EXAMPLE
  .\cfireworks.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateSet('Fireworks','Confetti')][string]$Mode = 'Fireworks',
  [string]$Ramp = " .:-=+*#%@",
  [ValidateRange(0.80,0.99)][double]$Decay = 0.90,
  [double]$BurstRate = 1.5,
  [ValidateRange(10,500)][int]$Particles = 80,
  [ValidateRange(1,500)][int]$ConfettiRate = 60,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Fireworks & Confetti
===========================

SYNOPSIS
    Spectacular particle effects with fireworks explosions and confetti falls.

USAGE
    .\cfireworks.ps1 [OPTIONS]
    .\cfireworks.ps1 -h

DESCRIPTION
    Dynamic particle simulation featuring two celebration modes: explosive 
    fireworks with realistic physics (gravity, drag, trails) and colorful 
    confetti with wobbling motion. Uses intensity-based fading trails and 
    customizable ASCII glyphs for visual effects.

OPTIONS
    -Fps <int>            Target frames per second (5-120, default: 30)
    -Speed <double>       Global motion speed multiplier (default: 1.0)
    -Mode <string>        'Fireworks' or 'Confetti' (default: Fireworks)
    -Ramp <string>        ASCII brightness ramp (default: " .:-=+*#%@")
    -Decay <double>       Trail fade rate (0.80-0.99, default: 0.90)
    -BurstRate <double>   Fireworks per second (default: 1.5)
    -Particles <int>      Particles per firework (10-500, default: 80)
    -ConfettiRate <int>   Confetti pieces per second (1-500, default: 60)
    -NoHardClear         Don't clear screen on exit
    -h                   Show this help and exit

MODES
    Fireworks - Radial explosive bursts with realistic physics
        • Random colors per burst (full HSV spectrum)
        • Gravity pulls particles downward over time
        • Drag reduces velocity for natural deceleration
        • Particles fade as they age and lose energy
        
    Confetti - Falling celebratory pieces with wobble motion
        • Spawns from top of screen in random colors
        • Lateral wobble creates realistic falling motion
        • Longer lifetime for extended celebration effect

EXAMPLES
    .\cfireworks.ps1
        Standard fireworks show at moderate pace

    .\cfireworks.ps1 -BurstRate 3.0 -Particles 150
        Intense fireworks with large bursts

    .\cfireworks.ps1 -Mode Confetti -ConfettiRate 120
        Heavy confetti fall celebration

    .\cfireworks.ps1 -Decay 0.95 -Ramp " .,oO*#@"
        Long trails with custom brightness characters

    .\cfireworks.ps1 -Speed 0.5 -Fps 60
        Slow motion effect at high framerate

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - Per-pixel intensity accumulation for overlapping particles
    - Exponential decay creates natural fading trails
    - Physics simulation with gravity and air resistance
    - Random color generation using HSV color space
    - Differential rendering updates only changed screen areas
    - Custom ASCII ramp maps intensity to visual brightness

CUSTOMIZATION
    - Ramp parameter accepts any ASCII string (dark to bright)
    - Decay values closer to 1.0 create longer, more visible trails
    - Higher particle counts create denser, more spectacular effects
    - Speed multiplier affects all motion without changing physics ratios

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
$script:Intens    = $null  # double[] per-cell intensity 0..1
$script:ColorBuf  = $null  # int[] base color for cell (used when intensity>0)

# Particles
$script:ParticlesList = New-Object System.Collections.Generic.List[object]
$rnd = [System.Random]::new()

# Glyph ramp
if ([string]::IsNullOrEmpty($Ramp) -or $Ramp.Length -lt 2){ $Ramp = " .:-=+*#%@" }
$RampLen = $Ramp.Length

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)

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

# Helpers ------------------------------------------------------------------------
function Clamp01([double]$v){ if ($v -lt 0){0.0} elseif ($v -gt 1){1.0} else {$v} }

function Spawn-Firework([int]$bw,[int]$bh){
  $cx = [int]($rnd.Next([int]([double]$bw*0.2), [int]([double]$bw*0.8)))
  $cy = [int]($rnd.Next([int]([double]$bh*0.2), [int]([double]$bh*0.6)))
  $h  = $rnd.NextDouble()*360.0
  $rgb = HSV-To-RGB $h 1.0 1.0
  $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
  $speed = 8.0 * $Speed
  for ($i=0; $i -lt $Particles; $i++){
    $ang = $rnd.NextDouble()*6.283185307179586
    $mag = $speed * (0.6 + 0.4*$rnd.NextDouble())
    $vx = [math]::Cos($ang) * $mag
    $vy = [math]::Sin($ang) * $mag - 1.0  # slight upward bias
    $life = 0.8 + 0.8*$rnd.NextDouble()
    $script:ParticlesList.Add([pscustomobject]@{
      x=[double]$cx; y=[double]$cy; vx=[double]$vx; vy=[double]$vy;
      life=[double]$life; maxlife=[double]$life; col=[int]$col;
    })
  }
}

function Spawn-Confetti([int]$bw){
  $x = [double]$rnd.Next(0, [math]::Max(1,$bw-1))
  $y = -1.0
  $h = $rnd.NextDouble()*360.0
  $rgb = HSV-To-RGB $h 0.8 1.0
  $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
  $vy = (2.5 + 1.5*$rnd.NextDouble()) * $Speed
  $vx = ( ($rnd.NextDouble()-0.5) * 1.5 ) * $Speed
  $phase = $rnd.NextDouble()*6.283185307179586
  $script:ParticlesList.Add([pscustomobject]@{
    x=[double]$x; y=[double]$y; vx=[double]$vx; vy=[double]$vy;
    phase=[double]$phase; col=[int]$col; life=[double]3.0; maxlife=[double]3.0;
  })
}

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
        $script:Intens    = New-Object 'double[]' ($bufSize)
        $script:ColorBuf  = New-Object 'int[]'  ($bufSize)
        $script:ParticlesList.Clear() | Out-Null
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear New buffers (Prev persists for diff)
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time step
      $dt = $frameMs / 1000.0

      # Decay intensity
      $dec = $Decay
      for ($i=0; $i -lt $script:Intens.Length; $i++){
        $script:Intens[$i] *= $dec
        if ($script:Intens[$i] -lt 0.005){ $script:Intens[$i] = 0.0; $script:ColorBuf[$i] = 0 }
      }

      # Spawns
      if ($Mode -eq 'Fireworks'){
        $p = $BurstRate * $dt
        if ($rnd.NextDouble() -lt $p){ Spawn-Firework $bw $bh }
      } else {
        $count = [int]([math]::Round($ConfettiRate * $dt))
        for ($c=0; $c -lt $count; $c++){ Spawn-Confetti $bw }
      }

      # Physics update + deposit energy
      $g = 9.8 * 0.8 * $Speed  # gravity-ish chars/s^2
      $drag = 0.98
      $newList = New-Object System.Collections.Generic.List[object]
      foreach($pobj in $script:ParticlesList){
        if ($Mode -eq 'Fireworks'){
          # update velocities
          $pobj.vx *= $drag
          $pobj.vy = $pobj.vy * $drag + $g * $dt
          # update positions
          $pobj.x += $pobj.vx * $dt
          $pobj.y += $pobj.vy * $dt
          $pobj.life -= $dt
          if ($pobj.life -gt 0 -and $pobj.x -ge 0 -and $pobj.x -le $maxX -and $pobj.y -ge 0 -and $pobj.y -le $maxY){
            $idx = [int]([math]::Round($pobj.x)) + $bw * [int]([math]::Round($pobj.y))
            $b = [double]($pobj.life / $pobj.maxlife)
            $val = 0.25 + 0.75*$b
            # accumulate intensity
            $ni = $script:Intens[$idx] + $val
            if ($ni -gt 1.0){ $ni = 1.0 }
            $script:Intens[$idx] = $ni
            $script:ColorBuf[$idx] = $pobj.col
            $newList.Add($pobj) | Out-Null
          }
        } else {
          # Confetti
          $pobj.phase += 2.4 * $dt
          $pobj.x += ($pobj.vx + [math]::Sin($pobj.phase)*0.8) * $dt
          $pobj.y += $pobj.vy * $dt
          $pobj.life -= $dt
          if ($pobj.y -le $maxY + 1 -and $pobj.life -gt 0){
            if ($pobj.x -ge 0 -and $pobj.x -le $maxX -and $pobj.y -ge 0){
              $idx = [int]([math]::Round($pobj.x)) + $bw * [int]([math]::Round($pobj.y))
              $ni = $script:Intens[$idx] + 1.0
              if ($ni -gt 1.0){ $ni = 1.0 }
              $script:Intens[$idx] = $ni
              $script:ColorBuf[$idx] = $pobj.col
            }
            $newList.Add($pobj) | Out-Null
          }
        }
      }
      $script:ParticlesList = $newList

      # Build New buffers from intensity/color
      for ($y=0; $y -le $maxY; $y++){
        $row = $y * $bw
        for ($x=0; $x -le $maxX; $x++){
          $idx = $row + $x
          $v = $script:Intens[$idx]
          if ($v -gt 0){
            if ($v -gt 1.0){ $v = 1.0 }
            $ri = [int]([math]::Floor($v * ($RampLen - 1)))
            $ch = $Ramp[$ri]
            $script:NewChars[$idx] = $ch
            $script:NewColor[$idx] = $script:ColorBuf[$idx]
          } else {
            # leave as zero -> renders as space
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
