<#
.SYNOPSIS
  Meteor Shower — diagonal streaks with decay trails (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent frame; only rewrites cells that changed (erases with spaces as needed).
  - Meteors streak diagonally across the screen leaving fading trails.
  - Per-cell intensity buffer decays each frame to create smooth trails.
  - Configurable meteor spawn rate, trail length, and fall angle.
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Global speed multiplier for meteor movement (default: 1.0).

.PARAMETER Rate
  Meteors spawned per second (default: 3.0).

.PARAMETER Trail
  Trail decay factor (0.80..0.98). Higher = longer trails. Default: 0.91.

.PARAMETER Angle
  Fall angle in degrees (0-180). 45 = diagonal, 90 = straight down. Default: 65.

.PARAMETER Ramp
  ASCII glyph ramp (dark→bright). Default: " .:-=+*#%@"

.PARAMETER Rainbow
  Use rainbow colors instead of white/yellow meteors.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [double]$Speed = 1.0,
  [ValidateRange(0.1,20.0)][double]$Rate = 3.0,
  [ValidateRange(0.80,0.98)][double]$Trail = 0.91,
  [ValidateRange(0,180)][int]$Angle = 65,
  [string]$Ramp = " .:-=+*#%@",
  [switch]$Rainbow,
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
$script:Intens    = $null  # double[] per-cell intensity 0..1
$script:ColorBuf  = $null  # int[] base color for cell (used when intensity>0)

# Meteors
$script:MeteorsList = New-Object System.Collections.Generic.List[object]
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

function Spawn-Meteor([int]$bw,[int]$bh){
  # Convert angle to radians and calculate velocity components
  $radians = [math]::PI * [double]$Angle / 180.0
  $vx = [math]::Sin($radians) * 40.0 * $Speed   # horizontal component
  $vy = [math]::Cos($radians) * 40.0 * $Speed   # vertical component
  
  # Spawn from top edge, offset horizontally based on angle
  $spawnOffset = [int]([math]::Round($bh * [math]::Tan([math]::PI/2 - $radians)))
  $x = [double]($rnd.Next(-$spawnOffset, $bw + $spawnOffset))
  $y = -2.0
  
  # Meteor characteristics
  $size = $rnd.Next(1, 4)  # 1=small, 2=medium, 3=large
  $brightness = 0.7 + 0.3*$rnd.NextDouble()
  $life = 3.0 + 2.0*$rnd.NextDouble()
  
  # Color selection
  if ($Rainbow) {
    $h = $rnd.NextDouble() * 360.0
    $rgb = HSV-To-RGB $h 0.9 1.0
    $col = PackRGB $rgb[0] $rgb[1] $rgb[2]
  } else {
    # White to yellow meteor colors
    $temp = $rnd.NextDouble()
    if ($temp -lt 0.3) {
      $col = PackRGB 255 255 255  # white
    } elseif ($temp -lt 0.7) {
      $col = PackRGB 255 255 180  # warm white
    } else {
      $col = PackRGB 255 220 100  # yellow
    }
  }
  
  # Add slight speed variation
  $speedVar = 0.8 + 0.4*$rnd.NextDouble()
  $vx *= $speedVar
  $vy *= $speedVar
  
  $script:MeteorsList.Add([pscustomobject]@{
    x=[double]$x; y=[double]$y; vx=[double]$vx; vy=[double]$vy;
    size=[int]$size; brightness=[double]$brightness; life=[double]$life; 
    maxlife=[double]$life; col=[int]$col;
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
        $script:Intens    = New-Object 'double[]' ($bufSize)
        $script:ColorBuf  = New-Object 'int[]'  ($bufSize)
        $script:MeteorsList.Clear() | Out-Null
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear New buffers (Prev persists for diff)
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time step
      $dt = $frameMs / 1000.0

      # Decay intensity (trail effect)
      for ($i=0; $i -lt $script:Intens.Length; $i++){
        $script:Intens[$i] *= $Trail
        if ($script:Intens[$i] -lt 0.005){ $script:Intens[$i] = 0.0; $script:ColorBuf[$i] = 0 }
      }

      # Spawn meteors
      $spawnChance = $Rate * $dt
      if ($rnd.NextDouble() -lt $spawnChance){ Spawn-Meteor $bw $bh }

      # Update meteors and deposit energy
      $newList = New-Object System.Collections.Generic.List[object]
      foreach($meteor in $script:MeteorsList){
        # Update position
        $meteor.x += $meteor.vx * $dt
        $meteor.y += $meteor.vy * $dt
        $meteor.life -= $dt
        
        # Check if meteor is still alive and on screen
        if ($meteor.life -gt 0 -and $meteor.x -ge -5 -and $meteor.x -le $maxX+5 -and $meteor.y -le $maxY+5){
          # Deposit intensity based on meteor size and life
          $lifeFactor = $meteor.life / $meteor.maxlife
          $baseIntensity = $meteor.brightness * (0.3 + 0.7 * $lifeFactor)
          
          # Draw meteor head and body based on size
          for ($dy = 0; $dy -lt $meteor.size; $dy++){
            for ($dx = 0; $dx -lt $meteor.size; $dx++){
              $px = [int]([math]::Round($meteor.x + $dx))
              $py = [int]([math]::Round($meteor.y + $dy))
              if ($px -ge 0 -and $px -le $maxX -and $py -ge 0 -and $py -le $maxY){
                $idx = $px + $bw * $py
                
                # Intensity falls off from center of meteor
                $centerDist = [math]::Sqrt($dx*$dx + $dy*$dy)
                $intensity = $baseIntensity * [math]::Max(0.1, 1.0 - $centerDist/($meteor.size*1.5))
                
                # Accumulate intensity
                $ni = $script:Intens[$idx] + $intensity
                if ($ni -gt 1.0){ $ni = 1.0 }
                $script:Intens[$idx] = $ni
                $script:ColorBuf[$idx] = $meteor.col
              }
            }
          }
          
          # Add to new list to keep alive
          $newList.Add($meteor) | Out-Null
        }
      }
      $script:MeteorsList = $newList

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
