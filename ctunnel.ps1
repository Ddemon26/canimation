<#
.SYNOPSIS
  ASCII Tunnel — radial UV swirl/spiral with color (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent frame; only rewrites cells that changed (erases with spaces as needed).
  - Modes:
      * Swirl  — banded rings that flow inward/outward; hue varies by angle.
      * Spiral — logarithmic spiral stripes; hue shifts with angle/depth.
  - ASCII ramp maps intensity to glyphs; 24-bit color via ANSI.
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Animation speed multiplier (default: 1.0).

.PARAMETER Mode
  'Swirl' or 'Spiral' (default: Swirl).

.PARAMETER Depth
  Depth/twist factor (affects ring density and spiral tightness). Default: 2.0.

.PARAMETER Ramp
  ASCII glyph ramp (dark→bright). Default: " .:-=+*#%@"

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateSet('Swirl','Spiral')][string]$Mode = 'Swirl',
  [double]$Depth = 2.0,
  [string]$Ramp = " .:-=+*#%@",
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
      $t += ($Speed * 1.0 * $dt)

      # Center / aspect
      $cx = [int]([math]::Floor($bw/2))
      $cy = [int]([math]::Floor($bh/2))
      $aspect = if ($bh -gt 0){ [double]$bw / [double]$bh } else { 1.0 }

      # Precompute factors
      $ringFreq = 10.0 * $Depth
      $spiralFreq = 6.0 * $Depth

      for ($y=0; $y -le $maxY; $y++){
        $row = $y * $bw
        $ny = (([double]$y - $cy) / [double]$bh) * 2.0
        for ($x=0; $x -le $maxX; $x++){
          $nx = (([double]$x - $cx) / [double]$bh) * 2.0 * $aspect

          $r = [math]::Sqrt($nx*$nx + $ny*$ny) + 1e-6
          $theta = [math]::Atan2($ny, $nx)  # [-pi..pi]

          if ($Mode -eq 'Spiral'){
            # classic spiral stripes: f = k*ln(r) + theta + t
            $f = $spiralFreq * [math]::Log($r) + $theta + $t*1.2
            $v = ([math]::Sin($f*2.0) + 1.0) * 0.5   # [0..1]
            # color by angle + depth
            $h = (($theta * 180.0 / [math]::PI) + $t*40.0 + ($Depth*15.0)) % 360
          } else {
            # swirl rings flowing radially
            $f = $ringFreq * $r - $t*4.0
            $v = ([math]::Cos($f) * 0.5 + 0.5)
            # subtle depth shading (dimmer as r grows)
            $v = $v * (1.0 / (1.0 + 0.4*$r*$Depth))
            # color by angle
            $h = (($theta * 180.0 / [math]::PI) + $t*60.0) % 360
          }

          if ($v -lt 0){ $v = 0 } elseif ($v -gt 1){ $v = 1 }

          # ASCII glyph
          $ri = [int]([math]::Floor($v * ($RampLen - 1)))
          $ch = $Ramp[$ri]

          # Color
          $rgb = HSV-To-RGB $h 1.0 1.0
          $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]

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
