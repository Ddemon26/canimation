<#
.SYNOPSIS
  ASCII Boids / Swarm simulation in 2D (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent frame and only rewrites cells that changed (including erasing with spaces).
  - Classic boids rules: Separation, Alignment, Cohesion + optional wraparound bounds.
  - ASCII glyphs orient with heading; color can reflect heading (rainbow).
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Global speed multiplier (default: 1.0).

.PARAMETER Count
  Number of boids (default: 120).

.PARAMETER ViewRadius
  Neighbor radius in cells (default: 14).

.PARAMETER SepRadius
  Separation radius in cells (default: 3).

.PARAMETER Cohesion
  Cohesion weight (default: 0.8).

.PARAMETER Alignment
  Alignment weight (default: 1.0).

.PARAMETER Separation
  Separation weight (default: 1.4).

.PARAMETER MaxSpeed
  Speed clamp in cells/sec (default: 18).

.PARAMETER Wrap
  Use wraparound (torus) bounds instead of soft walls (default: on).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cboids.ps1
  Run with default settings.

.EXAMPLE
  .\cboids.ps1 -Count 200 -Speed 1.5 -Fps 60
  Run with 200 boids at 1.5x speed and 60 FPS.

.EXAMPLE
  .\cboids.ps1 -h
  Display help message.

.EXAMPLE
  .\cboids.ps1 --help
  Display help message (alternative syntax).
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(10,1000)][int]$Count = 120,
  [ValidateRange(4,60)][int]$ViewRadius = 14,
  [ValidateRange(1,20)][int]$SepRadius = 3,
  [double]$Cohesion = 0.8,
  [double]$Alignment = 1.0,
  [double]$Separation = 1.4,
  [ValidateRange(2,200)][double]$MaxSpeed = 18.0,
  [switch]$Wrap,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Boids Simulation
======================

SYNOPSIS
    ASCII Boids / Swarm simulation in 2D with differential rendering.

USAGE
    .\cboids.ps1 [OPTIONS]
    .\cboids.ps1 -h

DESCRIPTION
    A flocking simulation using classic boids rules (Separation, Alignment, 
    Cohesion) with colored ASCII characters that orient based on heading.
    Uses differential rendering for smooth performance.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Speed <double>     Global speed multiplier (default: 1.0)
    -Count <int>        Number of boids (10-1000, default: 120)
    -ViewRadius <int>   Neighbor detection radius (4-60, default: 14)
    -SepRadius <int>    Separation radius (1-20, default: 3)
    -Cohesion <double>  Cohesion weight (default: 0.8)
    -Alignment <double> Alignment weight (default: 1.0)
    -Separation <double> Separation weight (default: 1.4)
    -MaxSpeed <double>  Speed limit in cells/sec (2-200, default: 18)
    -Wrap              Use wraparound bounds (torus topology)
    -NoHardClear       Don't clear screen on exit
    -h                 Show this help and exit

EXAMPLES
    .\cboids.ps1
        Run with default settings

    .\cboids.ps1 -Count 200 -Speed 1.5 -Fps 60
        High-performance mode with more boids

    .\cboids.ps1 -Wrap -Count 80 -ViewRadius 20
        Wraparound world with fewer, more social boids

    .\cboids.ps1 -Separation 2.0 -Cohesion 0.5
        More spread out flocking behavior

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Colors represent heading direction (rainbow hue)
    - Glyphs show movement direction: > ^ < v / \
    - Resize terminal window to change world size
    - Performance scales roughly O(N²) with boid count

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

# --- Boids list -----------------------------------------------------------------
$Boids = New-Object System.Collections.Generic.List[object]
$rnd = [System.Random]::new()

function Init-Boids([int]$n, [int]$bw, [int]$bh){
  $Boids.Clear()
  for ($i=0; $i -lt $n; $i++){
    $x = $rnd.NextDouble()*($bw-1)
    $y = $rnd.NextDouble()*($bh-3)  # avoid bottom row
    $ang = $rnd.NextDouble()*6.283185307179586
    $sp = 0.5 + 0.5*$rnd.NextDouble()
    $vx = [math]::Cos($ang) * $sp * $MaxSpeed*0.3
    $vy = [math]::Sin($ang) * $sp * $MaxSpeed*0.3
    $Boids.Add([pscustomobject]@{ x=[double]$x; y=[double]$y; vx=[double]$vx; vy=[double]$vy })
  }
}

function Clamp([double]$v, [double]$lo, [double]$hi){ if ($v -lt $lo){$lo} elseif ($v -gt $hi){$hi} else {$v} }

# Heading → char + color
function Heading-To-Char([double]$vx, [double]$vy){
  if ($vx -eq 0.0 -and $vy -eq 0.0){ return '·' }
  $ang = [math]::Atan2($vy,$vx)  # radians
  $deg = ($ang * 180.0 / [math]::PI)
  if ($deg -lt 0){ $deg += 360.0 }
  $idx = [int]([math]::Floor((($deg + 22.5) % 360) / 45.0))
  switch ($idx){
    0 { return '>' }
    1 { return '\' }
    2 { return 'v' }
    3 { return '/' }
    4 { return '<' }
    5 { return '\' }
    6 { return '^' }
    default { return '/' }
  }
}
function Heading-To-Color([double]$vx, [double]$vy){
  $ang = [math]::Atan2($vy,$vx)  # radians
  $deg = ($ang * 180.0 / [math]::PI)
  if ($deg -lt 0){ $deg += 360.0 }
  $rgb = HSV-To-RGB $deg 1.0 1.0
  return (PackRGB $rgb[0] $rgb[1] $rgb[2])
}

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

      # Resize buffers or (re)init boids on size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        Init-Boids $Count $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      } elseif ($Boids.Count -ne $Count){
        Init-Boids $Count $bw $bh
      }

      # Fast clear New buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time step
      $dt = $frameMs / 1000.0

      # --- Boids update (O(N^2)) ------------------------------------------------
      $vr2 = [double]$ViewRadius * [double]$ViewRadius
      $sr2 = [double]$SepRadius  * [double]$SepRadius
      for ($i=0; $i -lt $Boids.Count; $i++){
        $b = $Boids[$i]
        $sumx = 0.0; $sumy = 0.0; $sumvx = 0.0; $sumvy = 0.0; $sepx = 0.0; $sepy = 0.0; $n = 0

        for ($j=0; $j -lt $Boids.Count; $j++){
          if ($j -eq $i){ continue }
          $o = $Boids[$j]
          $dx = $o.x - $b.x
          $dy = $o.y - $b.y
          if ($Wrap){
            if ($dx -gt  $bw/2){ $dx -= $bw } elseif ($dx -lt -$bw/2){ $dx += $bw }
            if ($dy -gt  $bh/2){ $dy -= $bh } elseif ($dy -lt -$bh/2){ $dy += $bh }
          }
          $d2 = $dx*$dx + $dy*$dy
          if ($d2 -le $vr2){
            $sumx += $o.x; $sumy += $o.y
            $sumvx += $o.vx; $sumvy += $o.vy
            $n++
            if ($d2 -le $sr2 -and $d2 -gt 0){
              $inv = 1.0 / [math]::Sqrt($d2)
              $sepx -= $dx * $inv
              $sepy -= $dy * $inv
            }
          }
        }

        $ax = 0.0; $ay = 0.0
        if ($n -gt 0){
          $invn = 1.0 / $n
          # Cohesion: steer to average position
          $cx = ($sumx * $invn) - $b.x
          $cy = ($sumy * $invn) - $b.y
          if ($Wrap){
            if ($cx -gt  $bw/2){ $cx -= $bw } elseif ($cx -lt -$bw/2){ $cx += $bw }
            if ($cy -gt  $bh/2){ $cy -= $bh } elseif ($cy -lt -$bh/2){ $cy += $bh }
          }
          $ax += $Cohesion * $cx
          $ay += $Cohesion * $cy

          # Alignment: steer to average velocity
          $ax += $Alignment * (($sumvx * $invn) - $b.vx)
          $ay += $Alignment * (($sumvy * $invn) - $b.vy)
        }

        # Separation
        $ax += $Separation * $sepx
        $ay += $Separation * $sepy

        # Integrate velocity
        $b.vx += $ax * $dt
        $b.vy += $ay * $dt

        # Speed clamp
        $spd2 = $b.vx*$b.vx + $b.vy*$b.vy
        $vmax = $MaxSpeed * $Speed
        $vmax2 = $vmax*$vmax
        if ($spd2 -gt $vmax2){
          $scale = $vmax / [math]::Sqrt($spd2)
          $b.vx *= $scale; $b.vy *= $scale
        }

        # Position update + bounds
        $b.x += $b.vx * $dt
        $b.y += $b.vy * $dt
        if ($Wrap){
          if ($b.x -lt 0){ $b.x += $bw } elseif ($b.x -gt $maxX){ $b.x -= $bw }
          if ($b.y -lt 0){ $b.y += $bh } elseif ($b.y -gt $maxY){ $b.y -= $bh }
        } else {
          if ($b.x -lt 0){ $b.x=0; $b.vx = -$b.vx }
          if ($b.x -gt $maxX){ $b.x=$maxX; $b.vx=-$b.vx }
          if ($b.y -lt 0){ $b.y=0; $b.vy=-$b.vy }
          if ($b.y -gt $maxY){ $b.y=$maxY; $b.vy=-$b.vy }
        }

        # Render into New buffers
        $ix = [int]([math]::Round($b.x))
        $iy = [int]([math]::Round($b.y))
        if ($ix -ge 0 -and $ix -le $maxX -and $iy -ge 0 -and $iy -le $maxY){
          $ch = Heading-To-Char $b.vx $b.vy
          $col = Heading-To-Color $b.vx $b.vy
          $idx = $ix + $bw*$iy
          $script:NewChars[$idx] = $ch
          $script:NewColor[$idx] = $col
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
