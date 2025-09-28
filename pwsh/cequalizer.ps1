<#
.SYNOPSIS
  ASCII Equalizer Bars – procedural beats with -Bands, -Beat (BPM), -Falloff (rows/sec).
  Diff-write (cmatrix-style): only changed cells are rewritten; any key exits (Ctrl+C as input).

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Bands
  Number of bars (1..64). Default: 16.

.PARAMETER Beat
  Beat tempo in BPM (30..300). Default: 110.

.PARAMETER Falloff
  Downward speed in rows per second when the target drops (1..100). Default: 24.

.PARAMETER Rainbow
  Use rainbow per-band colors (otherwise Matrix-green gradient).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cequalizer.ps1
  Run with default settings (16 bands, 110 BPM, green gradient).

.EXAMPLE
  .\cequalizer.ps1 -Rainbow -Bands 32 -Beat 140
  Rainbow equalizer with more bands and faster beat.

.EXAMPLE
  .\cequalizer.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(1,64)][int]$Bands = 16,
  [ValidateRange(30,300)][int]$Beat = 110,
  [ValidateRange(1,100)][int]$Falloff = 24,
  [switch]$Rainbow,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Equalizer Bars
====================

SYNOPSIS
    Procedural audio equalizer visualization with animated frequency bars.

USAGE
    .\cequalizer.ps1 [OPTIONS]
    .\cequalizer.ps1 -h

DESCRIPTION
    A dynamic ASCII equalizer that simulates audio frequency bands with 
    procedurally generated beats. Features realistic bar physics with 
    peak caps, configurable beat timing, and color options. Uses 
    differential rendering for smooth performance.

OPTIONS
    -Fps <int>        Target frames per second (5-120, default: 30)
    -Bands <int>      Number of frequency bars (1-64, default: 16)
    -Beat <int>       Beat tempo in BPM (30-300, default: 110)
    -Falloff <int>    Bar fall speed in rows/sec (1-100, default: 24)
    -Rainbow         Use rainbow colors per band (default: green gradient)
    -NoHardClear     Don't clear screen on exit
    -h               Show this help and exit

BEHAVIOR
    - Bars rise instantly on beat peaks, fall at controllable speed
    - Peak caps float above bars and fall slower than main bars
    - Cross-modulation creates realistic variation between bands
    - Bars automatically scale to fill terminal height
    - Band width adjusts proportionally to terminal width

EXAMPLES
    .\cequalizer.ps1
        Standard 16-band green equalizer at 110 BPM

    .\cequalizer.ps1 -Rainbow -Bands 32 -Beat 140
        Rainbow 32-band equalizer with fast electronic beat

    .\cequalizer.ps1 -Bands 8 -Beat 80 -Falloff 12
        Wide 8-band bars with slow beat and gentle falloff

    .\cequalizer.ps1 -Bands 64 -Beat 180 -Fps 60
        High-density visualization with rapid beat

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL NOTES
    - Procedural beat generation using sine wave modulation
    - Each band has randomized phase offset for variation
    - Peak detection with separate cap physics
    - Gradient intensity increases toward bar tops
    - Automatic band spacing with optional gaps for clarity
    - Cross-modulation between bands creates realistic patterns

COLOR MODES
    Green Gradient - Classic audio equipment style with brightness variation
    Rainbow        - Each band cycles through spectrum colors over time

PERFORMANCE
    - Optimized for high band counts with differential rendering
    - Memory-efficient bar state tracking
    - Smooth interpolation for natural motion
    - Scales well from 1 to 64 bands

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
  return ([byte[]]@([byte]([math]::Round($r*255)),[byte]([math]::Round($g*255)),[byte]([math]::Round($b*255))))
}

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# Bar state
$script:Heights = $null    # double[] current heights in rows
$script:Targets = $null    # double[] target heights in rows
$script:Caps    = $null    # double[] peak caps in rows
$script:BandPhase = $null  # double[] random phase per band

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

$rnd = [System.Random]::new()

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 1
      $bufSize = $bw * $bh

      # Resize buffers on console size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        $script:Heights   = New-Object 'double[]' ($Bands)
        $script:Targets   = New-Object 'double[]' ($Bands)
        $script:Caps      = New-Object 'double[]' ($Bands)
        $script:BandPhase = New-Object 'double[]' ($Bands)
        for ($b=0; $b -lt $Bands; $b++){ $script:BandPhase[$b] = $rnd.NextDouble()*6.283185307179586 }
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear New buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time step
      $dt = $frameMs / 1000.0
      $t += $dt
      $beatHz = [double]$Beat / 60.0

      # Bar geometry (cover full width with proportional segments)
      # Each band b owns [floor(b*bw/Bands) .. floor((b+1)*bw/Bands)-1]
      # We'll leave a 1-col gap between bands only if the band's width >= 3 (except the last band).
      $segStarts = New-Object 'int[]' ($Bands)
      $segEnds   = New-Object 'int[]' ($Bands)
      for ($b=0; $b -lt $Bands; $b++){
        $segStarts[$b] = [int]([math]::Floor(($b    * $bw) / [double]$Bands))
        $segEnds[$b]   = [int]([math]::Floor((($b+1)* $bw) / [double]$Bands)) - 1
        if ($segEnds[$b] -lt $segStarts[$b]){ $segEnds[$b] = $segStarts[$b] }
      }      
      
      # Update targets procedurally & integrate heights with falloff

      $maxRows = $maxY + 1
      for ($b=0; $b -lt $Bands; $b++){
        $phase = $script:BandPhase[$b]
        $pulse = [math]::Sin(6.283185307179586 * ($t*$beatHz) + $phase)
        $pulse = [math]::Pow(($pulse*0.5 + 0.5), 1.6)  # sharper beat
        # cross modulation for variation (two slow sines)
        $mod = 0.5 + 0.5 * [math]::Sin($t*0.7 + $b*0.5) * [math]::Sin($t*1.1 + $b*0.3)
        $target01 = [math]::Min(1.0, [math]::Max(0.0, 0.25 + 0.75*$pulse*$mod))
        $script:Targets[$b] = $target01 * $maxRows

        $h = $script:Heights[$b]
        $ht = $script:Targets[$b]
        if ($ht -gt $h){
          # fast rise
          $rise = 120.0 * $dt    # rows/sec
          $h = [math]::Min($ht, $h + $rise)
        } else {
          # controlled fall
          $h = [math]::Max(0.0, $h - $Falloff*$dt)
        }
        $script:Heights[$b] = $h

        # peak cap (falls slower)
        $cap = $script:Caps[$b]
        if ($h -gt $cap){ $cap = $h }
        else { $cap = [math]::Max(0.0, $cap - 12.0*$dt) }
        $script:Caps[$b] = $cap
      }

      # Draw bars into New buffers
      for ($b=0; $b -lt $Bands; $b++){
        $h = [int]([math]::Floor($script:Heights[$b]))
        if ($h -le 0){ continue }
        $x0 = $segStarts[$b]
        $x1 = $segEnds[$b]
        $width = $x1 - $x0 + 1
        if ($width -ge 3 -and $b -lt $Bands-1){ $x1 -= 1 }  # leave 1-col gap except last band

        # color base per band
        if ($Rainbow){
          $hue = ( ($b*360.0/$Bands) + ($t*40.0) ) % 360
          $rgbBand = HSV-To-RGB $hue 1.0 1.0
        } else {
          $rgbBand = ([byte[]]@(0,255,0))
        }
        $r0=[byte]$rgbBand[0]; $g0=[byte]$rgbBand[1]; $b0=[byte]$rgbBand[2]

        for ($yy=0; $yy -lt $h; $yy++){
          $y = $maxY - $yy
          $tint = 0.35 + 0.65 * ([double]$yy / [double][math]::Max(1,$h-1)) # brighter near top
          $r=[byte]([math]::Round($r0 * $tint))
          $g=[byte]([math]::Round($g0 * $tint))
          $b2=[byte]([math]::Round($b0 * $tint))
          $packed = PackRGB $r $g $b2

          for ($x=$x0; $x -le $x1; $x++){
            $idx = $x + $bw*$y
            $script:NewChars[$idx] = '#'
            $script:NewColor[$idx] = $packed
          }
        }

        # draw cap
        $capRow = [int]([math]::Floor($script:Caps[$b]))
        if ($capRow -gt 0){
          $yCap = $maxY - $capRow
          if ($yCap -ge 0 -and $yCap -le $maxY){
            # slightly brighter cap
            $r=[byte]([math]::Min(255, $r0 + 40))
            $g=[byte]([math]::Min(255, $g0 + 40))
            $b2=[byte]([math]::Min(255, $b0 + 40))
            $packedCap = PackRGB $r $g $b2
            for ($x=$x0; $x -le $x1; $x++){
              $idx = $x + $bw*$yCap
              $script:NewChars[$idx] = '#'
              $script:NewColor[$idx] = $packedCap
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
