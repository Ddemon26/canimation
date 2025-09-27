<#
.SYNOPSIS
  ASCII Rain/Snow (diff-write, cmatrix-style).

.DESCRIPTION
  - Falling rain or snow with wind drift and density control.
  - Diff-only writes (rewrite changed cells; erase with space).
  - Any key exits; Ctrl+C treated as input. No CancelKeyPress handler.
  - Simple color themes.

.PARAMETER Mode
  Rain or Snow. Default: Rain

.PARAMETER Fps
  Frames per second. Default: 60

.PARAMETER Speed
  Fall speed multiplier. Default: 1.0

.PARAMETER Density
  Drops/flakes per 100 screen cells. Default: 0.8

.PARAMETER Wind
  Horizontal drift in cells/sec (negative = left, positive = right). Default: 0

.PARAMETER Theme
  Default, Blue (rain), White (snow), Rainbow. Default: Default

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit.
#>
[CmdletBinding()]
param(
  [ValidateSet('Rain','Snow')][string]$Mode = 'Rain',
  [ValidateRange(10,240)][int]$Fps = 60,
  [double]$Speed = 1.0,
  [ValidateRange(0.0,50.0)][double]$Density = .0,
  [int]$Count = 0, [double]$Wind = 0.0,
  [ValidateSet('Default','Blue','White','Rainbow')][string]$Theme = 'Default',
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

# --- Particles ------------------------------------------------------------------
$script:Count = 0
$script:Px = $null  # double[] x (float for wind)
$script:Py = $null  # double[] y
$script:Pv = $null  # double[] vertical speed factor
$script:Glyph = $null # char[]

function Ensure-Particles([int]$bw, [int]$bh){
  $target = [int]([math]::Max(10, [math]::Round( ($Count -gt 0) ? $Count : ($Density * ($bw*$bh) / 100.0) )))
  if ($script:Count -ne $target){
    $script:Count = $target
    $script:Px = New-Object 'double[]' $target
    $script:Py = New-Object 'double[]' $target
    $script:Pv = New-Object 'double[]' $target
    $script:Glyph = New-Object 'char[]' $target
    for ($i=0; $i -lt $target; $i++){ Reset-Particle $bw $bh $i $true }
  }
}

function Reset-Particle([int]$bw, [int]$bh, [int]$i, [bool]$randomY){
  $script:Px[$i] = (Get-Random -Minimum 0.0 -Maximum ([double]$bw))
  $script:Py[$i] = if ($randomY) { (Get-Random -Minimum 0.0 -Maximum ([double]$bh)) } else { 0.0 }
  $script:Pv[$i] = ( $Mode -eq 'Rain' ) ? (Get-Random -Minimum 0.8 -Maximum 1.4) : (Get-Random -Minimum 0.3 -Maximum 0.8)
  if ($Mode -eq 'Rain'){
    # pick one of '|', '/', '\' based on wind
    $script:Glyph[$i] = ( ($Wind -gt 0.8) ? '\' : ( ($Wind -lt -0.8) ? '/' : '|' ) )
  } else {
    # snow: '.', '*', 'o' variety
    $r = Get-Random -Minimum 0 -Maximum 3
    $script:Glyph[$i] = ('.','*','o')[$r]
  }
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
        Ensure-Particles $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      $dt = $frameMs / 1000.0

      # Update particles
      for ($i=0; $i -lt $script:Count; $i++){
        # Move
        $gravity = ( $Mode -eq 'Rain' ) ? 30.0 : 8.0
        $script:Py[$i] += $Speed * $script:Pv[$i] * $gravity * $dt
        $script:Px[$i] += $Wind * $dt * ( ($Mode -eq 'Rain') ? 1.0 : 0.5 )

        # Respawn if off-screen
        if ($script:Py[$i] -gt $bh + 1){
          Reset-Particle $bw $bh $i $false
        }
        if ($script:Px[$i] -lt -1){ $script:Px[$i] = $bw-1.0 }
        if ($script:Px[$i] -gt $bw){ $script:Px[$i] = 0.0 }

        # Plot current position (rain can be 2-char streak depending on speed)
        $x = [int]([math]::Round($script:Px[$i]))
        $y = [int]([math]::Round($script:Py[$i]))
        if ($x -ge 0 -and $x -le $maxX -and $y -ge 0 -and $y -le $maxY){
          $idx = $x + $bw*$y
          $script:NewChars[$idx] = $script:Glyph[$i]
          # choose color
          switch ($Theme) {
            'Default' {
              if ($Mode -eq 'Rain'){ $packed = PackRGB 120 160 255 } else { $packed = PackRGB 230 230 230 }
            }
            'Blue'    { $packed = PackRGB 100 150 255 }
            'White'   { $packed = PackRGB 235 235 235 }
            'Rainbow' {
              $h = ($i*13 + ($y*3)) % 360
              $rgb = HSV-To-RGB $h 0.9 1.0
              $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
            }
          }
          $script:NewColor[$idx] = $packed
          # simple 2nd segment for heavy rain
          if ($Mode -eq 'Rain' -and $Speed*$script:Pv[$i] -gt 1.2){
            $y2 = $y-1
            if ($y2 -ge 0){
              $idx2 = $x + $bw*$y2
              $script:NewChars[$idx2] = ( ($Wind -gt 0.8) ? '\' : ( ($Wind -lt -0.8) ? '/' : '|' ) )
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