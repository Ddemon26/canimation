<#
.SYNOPSIS
  ASCII Ripple/Waves interference that "wobbles" the screen (diff-write, cmatrix-style).

.DESCRIPTION
  - Persistent frame with diff-only updates (erases with spaces when needed).
  - Interference from multiple moving wave sources; intensity -> ASCII ramp + color.
  - Optional horizontal "wobble" displacement for a liquid screen effect.
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Animation speed multiplier (default: 1.0).

.PARAMETER Sources
  Number of wave sources (1..8). Default: 4.

.PARAMETER Palette
  'Ocean', 'Rainbow', or 'Mono' (default: Ocean).

.PARAMETER Ramp
  ASCII glyph ramp (dark→bright). Default: " .:-=+*#%@"

.PARAMETER Amplitude
  Horizontal wobble amplitude in characters (0..10). Default: 3.

.PARAMETER Scale
  Spatial scale of waves (higher = wider ripples). Default: 10.0.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(1,8)][int]$Sources = 4,
  [ValidateSet('Ocean','Rainbow','Mono')][string]$Palette = 'Ocean',
  [string]$Ramp = " .:-=+*#%@",
  [ValidateRange(0,10)][int]$Amplitude = 3,
  [double]$Scale = 10.0,
  [switch]$NoHardClear
)

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
function LerpRGB([int]$c1,[int]$c2,[double]$t){
  if ($t -lt 0){ $t = 0 } elseif ($t -gt 1){ $t = 1 }
  $r1 = ($c1 -shr 16) -band 0xFF; $g1 = ($c1 -shr 8) -band 0xFF; $b1 = $c1 -band 0xFF
  $r2 = ($c2 -shr 16) -band 0xFF; $g2 = ($c2 -shr 8) -band 0xFF; $b2 = $c2 -band 0xFF
  $r = [byte]([math]::Round($r1 + ($r2 - $r1)*$t))
  $g = [byte]([math]::Round($g1 + ($g2 - $g1)*$t))
  $b = [byte]([math]::Round($b1 + ($b2 - $b1)*$t))
  return (PackRGB $r $g $b)
}

# Ocean palette stops
$OceanStops = @(
  @{t=0.00; c=(PackRGB 0  10 40)}    # deep navy
  @{t=0.40; c=(PackRGB 0 100 200)}   # blue
  @{t=0.80; c=(PackRGB 80 230 255)}  # cyan
  @{t=1.00; c=(PackRGB 255 255 255)} # white tip
)
function Palette-Color([double]$v){
  switch ($Palette){
    'Rainbow' {
      $h = ($v*360.0)
      $rgb = HSV-To-RGB $h 1.0 1.0
      return (PackRGB $rgb[0] $rgb[1] $rgb[2])
    }
    'Mono' {
      $g = [byte]([math]::Round(40 + 200*$v))
      return (PackRGB 0 $g 0)
    }
    default {
      # Ocean
      if ($v -le 0){ return $OceanStops[0].c }
      if ($v -ge 1){ return $OceanStops[-1].c }
      for ($i=1; $i -lt $OceanStops.Count; $i++){
        $a = $OceanStops[$i-1]; $b = $OceanStops[$i]
        if ($v -le $b.t){
          $u = ($v - $a.t) / ([double]($b.t - $a.t))
          return (LerpRGB $a.c $b.c $u)
        }
      }
      return $OceanStops[-1].c
    }
  }
}

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# Wave sources
$script:SourcesList = New-Object System.Collections.Generic.List[object]
$rnd = [System.Random]::new()

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

function Reset-Sources([int]$bw,[int]$bh){
  $script:SourcesList = New-Object System.Collections.Generic.List[object]
  for ($i=0; $i -lt $Sources; $i++){
    $x = $rnd.Next(0, [math]::Max(1,$bw-1))
    $y = $rnd.Next(0, [math]::Max(1,$bh-3))
    $ang = $rnd.NextDouble()*6.283185307179586
    $spd = (0.6 + 0.8*$rnd.NextDouble()) * $Speed * 10.0
    $vx = [math]::Cos($ang) * $spd
    $vy = [math]::Sin($ang) * $spd
    $freq = 0.6 + 1.2*$rnd.NextDouble()
    $phase = $rnd.NextDouble()*6.283185307179586
    $script:SourcesList.Add([pscustomobject]@{ x=[double]$x; y=[double]$y; vx=[double]$vx; vy=[double]$vy; freq=[double]$freq; phase=[double]$phase })
  }
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

      # (Re)alloc buffers and sources on size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        Reset-Sources $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time advance
      $dt = $frameMs / 1000.0
      $t += $Speed * $dt

      # Move sources (bounce off edges)
      foreach($s in $script:SourcesList){
        $s.x += $s.vx * $dt
        $s.y += $s.vy * $dt
        $s.phase += 1.6 * $s.freq * $Speed * $dt
        if ($s.x -lt 0){ $s.x = 0; $s.vx = -$s.vx }
        if ($s.x -gt $maxX){ $s.x = $maxX; $s.vx = -$s.vx }
        if ($s.y -lt 0){ $s.y = 0; $s.vy = -$s.vy }
        if ($s.y -gt $maxY){ $s.y = $maxY; $s.vy = -$s.vy }
      }

      $twoPI = 6.283185307179586
      $sc = [double]$Scale

      # Build field + wobble write
      for ($y=0; $y -le $maxY; $y++){
        $row = $y * $bw
        for ($x=0; $x -le $maxX; $x++){
          # Interference sum
          $sum = 0.0
          foreach($s in $script:SourcesList){
            $dx = $x - $s.x; $dy = $y - $s.y
            $r = [math]::Sqrt($dx*$dx + $dy*$dy) / $sc
            $sum += [math]::Sin($r * $twoPI * $s.freq - $s.phase)
          }
          $v = ($sum / [double]$script:SourcesList.Count + 1.0) * 0.5  # 0..1

          # Horizontal wobble displacement (liquid effect)
          $dxw = [int]([math]::Round($Amplitude * [math]::Sin(($y/[double][math]::Max(1,$maxY))*$twoPI + $t*1.7 + $sum*0.2)))
          $wx = $x + $dxw
          if ($wx -lt 0 -or $wx -gt $maxX){ continue }

          # Map to glyph + color and write into New buffers at displaced coord
          $ri = [int]([math]::Floor($v * ([double]$Ramp.Length - 1)))
          $ch = $Ramp[$ri]
          $col = Palette-Color $v

          $idx = $row + $wx
          $script:NewChars[$idx] = $ch
          $script:NewColor[$idx] = $col
        }
      }

      # Diff & draw (char OR color changed)
      $sb = [System.Text.StringBuilder]::new()
      $lastPacked = -1
      for ($yy=0; $yy -le $maxY; $yy++){
        $row = $yy * $bw
        for ($xx=0; $xx -le $maxX; $xx++){
          $idx = $row + $xx
          $nch = $script:NewChars[$idx]; if ($nch -eq [char]0){ $nch = ' ' }
          $ncol = $script:NewColor[$idx]
          $pch = $script:PrevChars[$idx]; if ($pch -eq [char]0){ $pch = ' ' }
          $pcol = $script:PrevColor[$idx]

          if (($nch -ne $pch) -or ($ncol -ne $pcol)){
            [void]$sb.Append("$e[$($yy+1);$($xx+1)H")
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
