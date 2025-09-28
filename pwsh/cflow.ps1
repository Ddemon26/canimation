<#
.SYNOPSIS
  Aurora / Flow Field — curl or perlin-like noise driven streams (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent frame; only rewrites cells that changed (erases with spaces as needed).
  - Particles advected by a vector field:
      * -Field Curl   : analytic curl field from summed sines/cosines (fast).
      * -Field Perlin : value-noise field with finite-diff curl (prettier, slower).
  - Per-cell intensity buffer with decay creates smooth aurora-like trails.
  - -HueShift adds a time-based hue drift across the gradient.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Flow speed multiplier (default: 1.0).

.PARAMETER Field
  'Curl' or 'Perlin' (default: Curl).

.PARAMETER Particles
  Number of particles advected by the field (default: 140).

.PARAMETER Decay
  Per-frame intensity decay factor (0.85..0.99). Higher = longer trails. Default: 0.94.

.PARAMETER Ramp
  ASCII glyph ramp (dark→bright). Default: " .:-=+*#%@".

.PARAMETER HueShift
  When set, the hue palette shifts over time.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateSet('Curl','Perlin')][string]$Field = 'Curl',
  [ValidateRange(40,1000)][int]$Particles = 140,
  [ValidateRange(0.85,0.99)][double]$Decay = 0.94,
  [string]$Ramp = " .:-=+*#%@",
  [switch]$HueShift,
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

function Clamp01([double]$v){ if ($v -lt 0){0.0} elseif ($v -gt 1){1.0} else {$v} }

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB
$script:Intens    = $null  # double[] per-cell intensity 0..1
$script:ColorBuf  = $null  # int[] base color per cell

# Particles
$script:ParticlesList = New-Object System.Collections.Generic.List[object]
$rnd = [System.Random]::new()

# Glyph ramp
if ([string]::IsNullOrEmpty($Ramp) -or $Ramp.Length -lt 2){ $Ramp = " .:-=+*#%@" }
$RampLen = $Ramp.Length

# --- Value noise for Perlin-like mode ------------------------------------------
# Hash function for lattice
function Hash2([int]$x, [int]$y, [int]$t){
  $n = $x*374761393 + $y*668265263 + $t*362437
  $n = ($n -bxor ($n -shr 13)) * 1274126177
  $n = $n -bxor ($n -shr 16)
  return [double](($n -band 0x7fffffff)) / 2147483647.0
}
function Smoothstep([double]$x){ return $x*$x*(3.0 - 2.0*$x) }
function ValueNoise([double]$x,[double]$y,[double]$time){
  $xi = [int][math]::Floor($x); $yi = [int][math]::Floor($y)
  $tx = $x - $xi; $ty = $y - $yi
  $tt = [int][math]::Floor($time)
  $n00 = Hash2 ($xi)     ($yi)     $tt
  $n10 = Hash2 ($xi + 1) ($yi)     $tt
  $n01 = Hash2 ($xi)     ($yi + 1) $tt
  $n11 = Hash2 ($xi + 1) ($yi + 1) $tt
  $sx = Smoothstep $tx; $sy = Smoothstep $ty
  $a = $n00 + ($n10 - $n00)*$sx
  $b = $n01 + ($n11 - $n01)*$sx
  return $a + ($b - $a)*$sy
}

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
        # seed particles
        for ($i=0; $i -lt $Particles; $i++){
          $script:ParticlesList.Add([pscustomobject]@{
            x = [double]$rnd.NextDouble()*$maxX;
            y = [double]$rnd.NextDouble()*$maxY;
            hue = [double]($rnd.NextDouble()*360.0);
          }) | Out-Null
        }
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear New buffers (Prev persists for diff)
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time step
      $dt = $frameMs / 1000.0
      $t += $Speed * 0.6 * $dt

      # Decay intensity
      $dec = $Decay
      for ($i=0; $i -lt $script:Intens.Length; $i++){
        $script:Intens[$i] *= $dec
        if ($script:Intens[$i] -lt 0.004){ $script:Intens[$i] = 0.0; $script:ColorBuf[$i] = 0 }
      }

      # Advect particles by the selected field
      $scale = 18.0 * $Speed   # movement scale in chars/sec
      foreach($p in $script:ParticlesList){
        $u = if ($maxX -gt 0){ [double]$p.x / [double]$maxX } else { 0.0 }
        $v = if ($maxY -gt 0){ [double]$p.y / [double]$maxY } else { 0.0 }

        if ($Field -eq 'Curl'){
          # Scalar potential phi = s1 + s2 + s3
          $s1 = [math]::Sin(1.7*$u*6.2831853 + 1.3*$t)
          $s2 = [math]::Cos(1.9*$v*6.2831853 + 1.1*$t)
          $s3 = [math]::Sin(1.2*$u*6.2831853 + 1.3*$v*6.2831853 + 0.7*$t)
          # partials (chain rule). dphi/du, dphi/dv
          $dphidu = 1.7*6.2831853*[math]::Cos(1.7*$u*6.2831853 + 1.3*$t) + 1.2*6.2831853*[math]::Cos(1.2*$u*6.2831853 + 1.3*$v*6.2831853 + 0.7*$t)
          $dphidv = -1.9*6.2831853*[math]::Sin(1.9*$v*6.2831853 + 1.1*$t) + 1.3*6.2831853*[math]::Cos(1.2*$u*6.2831853 + 1.3*$v*6.2831853 + 0.7*$t)
          # curl in 2D = perpendicular to gradient
          $vx =  $dphidv
          $vy = -$dphidu
          # normalize-ish
          $mag = [math]::Sqrt($vx*$vx + $vy*$vy) + 1e-6
          $vx /= $mag; $vy /= $mag
          $h = (($u*360.0) + ($HueShift ? ($t*120.0) : 0.0)) % 360
        } else {
          # Perlin-like value noise curl via finite difference
          $nfreq = 6.0
          $px = $u*$nfreq; $py = $v*$nfreq
          $nt = $t*0.7
          $eps = 0.01
          $n_x1 = ValueNoise ($px - $eps) $py $nt
          $n_x2 = ValueNoise ($px + $eps) $py $nt
          $n_y1 = ValueNoise $px ($py - $eps) $nt
          $n_y2 = ValueNoise $px ($py + $eps) $nt
          $dndx = ($n_x2 - $n_x1) / (2*$eps)
          $dndy = ($n_y2 - $n_y1) / (2*$eps)
          $vx =  $dndy
          $vy = -$dndx
          $mag = [math]::Sqrt($vx*$vx + $vy*$vy) + 1e-6
          $vx /= $mag; $vy /= $mag
          $h = ((($n_x2+$n_y2)*180.0) + ($HueShift ? ($t*160.0) : 0.0)) % 360
        }

        # Move
        $p.x += $vx * $scale * $dt
        $p.y += $vy * $scale * $dt

        # Wrap edges
        if ($p.x -lt 0){ $p.x += $maxX+1 }
        if ($p.x -gt $maxX){ $p.x -= $maxX+1 }
        if ($p.y -lt 0){ $p.y += $maxY+1 }
        if ($p.y -gt $maxY){ $p.y -= $maxY+1 }

        # Deposit intensity
        $ix = [int]([math]::Round($p.x))
        $iy = [int]([math]::Round($p.y))
        if ($ix -ge 0 -and $ix -le $maxX -and $iy -ge 0 -and $iy -le $maxY){
          $idx = $ix + $bw*$iy
          $rgb = HSV-To-RGB $h 1.0 1.0
          $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
          $val = 0.85
          $ni = $script:Intens[$idx] + $val
          if ($ni -gt 1.0){ $ni = 1.0 }
          $script:Intens[$idx] = $ni
          $script:ColorBuf[$idx] = $col
        }
      }

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
