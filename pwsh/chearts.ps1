<#
.SYNOPSIS
  Hearts Field — drifting ASCII "<3" hearts (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites changed cells (erasing with spaces as needed).
  - Hearts drift upward with gentle sideways wobble. Any key exits (Ctrl+C treated as input).
  - Optional pulsing brightness. Density scales with terminal size for similar fill across sizes.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Global speed multiplier (default: 1.0).

.PARAMETER Density
  Hearts per 10,000 console cells (scaled to your terminal). Default: 40.

.PARAMETER Pulse
  Enable per-heart pulsing brightness.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(1,200)][int]$Density = 40,
  [switch]$Pulse,
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

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# --- Hearts list ----------------------------------------------------------------
$script:Hearts = New-Object System.Collections.Generic.List[object]
$rnd = [System.Random]::new()

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

# Initial clear once so we start clean
try { [Console]::Write($AnsiClearHome) } catch {}

function Clamp01([double]$v){ if ($v -lt 0){0.0} elseif ($v -gt 1){1.0} else {$v} }

# Spawner picks a base pink/red hue near 340° with slight variance
function Spawn-Heart([int]$bw,[int]$bh){
  $x = [double]$rnd.Next(0, [math]::Max(1,$bw-3))
  $y = [double]($bh - 2)  # spawn near bottom
  $h = 330.0 + 20.0*($rnd.NextDouble()-0.5)  # 320..340
  $sat = 0.75 + 0.2*($rnd.NextDouble()-0.5)
  $val = 0.85
  $rgb = HSV-To-RGB $h $sat $val
  $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
  $vy = (-0.8 - 0.7*$rnd.NextDouble()) * $Speed   # drift upward
  $vx = ( ($rnd.NextDouble()-0.5) * 0.6 ) * $Speed
  $phase = $rnd.NextDouble()*6.283185307179586
  $life = 6.0 + 3.0*$rnd.NextDouble()
  $script:Hearts.Add([pscustomobject]@{
    x=[double]$x; y=[double]$y; vx=[double]$vx; vy=[double]$vy;
    phase=[double]$phase; hue=[double]$h; sat=[double]$sat; basev=[double]$val;
    life=[double]$life; maxlife=[double]$life; col=[int]$col
  }) | Out-Null
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
        $script:Hearts.Clear() | Out-Null
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear New buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time & target population
      $dt = $frameMs / 1000.0
      $time += $dt
      $target = [int]([math]::Round($Density * ([double]$bw * [double]$bh) / 10000.0))
      if ($target -lt 4){ $target = 4 }

      # Spawn up to reach target; also trickle spawns for liveliness
      $spawnCount = [math]::Max(0, $target - $script:Hearts.Count)
      if ($spawnCount -gt 0){ for($i=0;$i -lt [math]::Min($spawnCount, 6);$i++){ Spawn-Heart $bw $bh } }
      if ($rnd.NextDouble() -lt 0.15){ Spawn-Heart $bw $bh }

      # Update hearts & draw into New buffers
      $newList = New-Object System.Collections.Generic.List[object]
      foreach($h in $script:Hearts){
        # motion
        $h.phase += (1.5 * $dt)
        $h.x += ($h.vx + [math]::Sin($h.phase)*0.3) * $dt * 60.0/60.0  # lateral wobble
        $h.y += $h.vy * $dt * 60.0/60.0
        $h.life -= $dt

        if ($h.life -gt 0 -and $h.y -ge 0 -and $h.x -le $maxX){
          # pulse brightness
          $v = $h.basev
          if ($Pulse){
            $p = 0.75 + 0.25*[math]::Sin($time*3.0 + $h.phase*2.0)
            $v = [math]::Min(1.0, $v * $p)
          }
          $rgb = HSV-To-RGB $h.hue ([math]::Min(1.0, $h.sat)) $v
          $col = PackRGB $rgb[0] $rgb[1] $rgb[2]

          # draw "<3" (two cells)
          $ix = [int]([math]::Round($h.x))
          $iy = [int]([math]::Round($h.y))
          if ($ix -ge 0 -and $ix -le $maxX -and $iy -ge 0 -and $iy -le $maxY){
            $idx = $ix + $bw*$iy
            $script:NewChars[$idx] = '<'
            $script:NewColor[$idx] = $col
          }
          if ($ix+1 -ge 0 -and $ix+1 -le $maxX -and $iy -ge 0 -and $iy -le $maxY){
            $idx2 = ($ix+1) + $bw*$iy
            $script:NewChars[$idx2] = '3'
            $script:NewColor[$idx2] = $col
          }

          # keep
          if ($iy -ge -1){ $newList.Add($h) | Out-Null }
        }
      }
      $script:Hearts = $newList

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
