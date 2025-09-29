<#
.SYNOPSIS
  Star field warp effect that updates only changed cells per frame (no full clears).

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites cells that changed (including erasing with space).
  - Matches the cmatrix-style update loop (no CancelKeyPress handler; any key exits, Ctrl+C treated as input).
  - Simulates stars streaming past at warp speed with color trails and acceleration effects.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Warp speed multiplier (default: 1.0).

.PARAMETER StarCount
  Number of stars in the field (default: 150).

.PARAMETER Trails
  Enable colorful star trails (default: off).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.EXAMPLE
  .\cstarwarp.ps1
  Run with default settings.

.EXAMPLE
  .\cstarwarp.ps1 -Trails -Speed 2
  Warp speed with colorful trails.

.EXAMPLE
  .\cstarwarp.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(0.1,5.0)][double]$Speed = 1.0,
  [ValidateRange(50,500)][int]$StarCount = 150,
  [switch]$Trails,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Star Field Warp Effect
=======================

SYNOPSIS
    Classic starfield warp speed effect with streaming stars and optional trails.

USAGE
    .\cstarwarp.ps1 [OPTIONS]
    .\cstarwarp.ps1 -h

DESCRIPTION
    Simulates traveling at warp speed through a star field. Stars stream
    from the center outward, accelerating as they approach the edges.
    Optional colorful trails create light-speed streaks. Classic sci-fi
    hyperspace effect with differential rendering.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Speed <double>     Warp speed multiplier (0.1-5.0, default: 1.0)
    -StarCount <int>    Number of stars (50-500, default: 150)
    -Trails             Enable colorful star trails
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

EXAMPLES
    .\cstarwarp.ps1
        Default warp speed effect

    .\cstarwarp.ps1 -Trails
        Enable colorful light-speed trails

    .\cstarwarp.ps1 -Speed 2 -StarCount 300
        Faster warp with more stars

    .\cstarwarp.ps1 -Trails -Speed 3 -Fps 60
        Maximum warp speed with trails at high framerate

    .\cstarwarp.ps1 -StarCount 100 -Speed 0.5
        Fewer stars at slower, more relaxed pace

    .\cstarwarp.ps1 -Trails -StarCount 250
        Dense star field with colorful trails

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Stars accelerate as they move away from center
    - Trails option creates colorful light-speed streaks
    - Higher Speed values create more dramatic warp effect
    - More stars create denser, more impressive field
    - Stars automatically respawn at center when they exit
    - Classic sci-fi hyperspace/warp drive visual effect
    - Uses differential rendering (only updates changed cells)

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
$AnsiClearFull   = "$e[3J$e[H"
$AnsiScrollUpMax = "$e[9999S"
$RIS             = "$e" + "c"

# Key helpers (non-blocking)
function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

# --- Math helpers ---------------------------------------------------------------
function Clamp([double]$val, [double]$min, [double]$max){
  if ($val -lt $min) { $min } elseif ($val -gt $max) { $max } else { $val }
}

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

# --- Star class -----------------------------------------------------------------
class Star {
  [double]$x; [double]$y; [double]$z
  [double]$prevX; [double]$prevY
  [double]$velocity
  [double]$brightness
  [int]$color
  [char]$character

  Star([int]$maxW, [int]$maxH){
    $this.Reset($maxW, $maxH)
  }

  [void]Reset([int]$maxW, [int]$maxH){
    $this.x = ($script:Rand.NextDouble() - 0.5) * 2.0 * $maxW
    $this.y = ($script:Rand.NextDouble() - 0.5) * 2.0 * $maxH
    $this.z = $script:Rand.NextDouble() * 1000.0 + 1.0
    $this.velocity = $script:Rand.NextDouble() * 2.0 + 0.5
    $this.brightness = $script:Rand.NextDouble() * 0.8 + 0.2
    $this.prevX = $this.x / $this.z
    $this.prevY = $this.y / $this.z

    # Random star characters
    $chars = '.', '*', '+', 'o', 'O', '@'
    $this.character = $chars[$script:Rand.Next($chars.Length)]

    # Color based on speed/distance
    if ($script:UseTrails) {
      $hue = ($this.velocity * 60 + $this.z * 0.1) % 360
      $rgb = HSV-To-RGB $hue 0.8 $this.brightness
      $this.color = PackRGB $rgb[0] $rgb[1] $rgb[2]
    } else {
      $intensity = [byte]([math]::Round($this.brightness * 255))
      $this.color = PackRGB $intensity $intensity $intensity
    }
  }

  [void]Update([double]$dt, [int]$maxW, [int]$maxH, [int]$centerX, [int]$centerY){
    $this.prevX = $this.x / $this.z
    $this.prevY = $this.y / $this.z

    $this.z -= $this.velocity * $script:WarpSpeed * $dt * 200.0

    if ($this.z -le 1.0) {
      $this.Reset($maxW, $maxH)
      return
    }

    # Update brightness based on speed
    $speedFactor = [math]::Min(5.0, $script:WarpSpeed * $this.velocity)
    $this.brightness = Clamp ($this.brightness + $speedFactor * 0.1 * $dt) 0.1 1.0

    # Update color for trails
    if ($script:UseTrails) {
      $hue = ($this.velocity * 60 + ($this.z * 0.1) + ($script:WarpSpeed * 30)) % 360
      $rgb = HSV-To-RGB $hue 0.9 $this.brightness
      $this.color = PackRGB $rgb[0] $rgb[1] $rgb[2]
    } else {
      $intensity = [byte]([math]::Round($this.brightness * 255))
      $this.color = PackRGB $intensity $intensity $intensity
    }
  }

  [int[]]GetScreenPos([int]$centerX, [int]$centerY){
    $screenX = [int]([math]::Round($centerX + ($this.x / $this.z)))
    $screenY = [int]([math]::Round($centerY + ($this.y / $this.z)))
    return @($screenX, $screenY)
  }

  [int[]]GetPrevScreenPos([int]$centerX, [int]$centerY){
    $screenX = [int]([math]::Round($centerX + $this.prevX))
    $screenY = [int]([math]::Round($centerY + $this.prevY))
    return @($screenX, $screenY)
  }
}

# --- Cached buffers -------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null   # char[]
$script:PrevColor = $null   # int[] packed RGB
$script:NewChars  = $null   # char[]
$script:NewColor  = $null   # int[] packed RGB

# --- Setup ----------------------------------------------------------------------
$script:Rand = [System.Random]::new()
$script:WarpSpeed = $Speed
$script:UseTrails = $Trails.IsPresent

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)

# Save console state; hide cursor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Treat Ctrl+C as input (avoid CancelKeyPress runspace issues)
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}

# Do an initial clear so the first diff writes onto a clean screen
try { [Console]::Write($AnsiClearHome) } catch {}

# Initialize stars
$stars = @()
for ($i = 0; $i -lt $StarCount; $i++) {
  $stars += [Star]::new(80, 25)  # will be updated on first frame
}

# Plot helper
function Plot([int]$x,[int]$y,[char]$ch,[int]$packed,[int]$bw,[int]$bh){
  $maxX=$bw-1; $maxY=$bh-2
  if ($x -lt 0 -or $y -lt 0 -or $x -gt $maxX -or $y -gt $maxY){ return }
  $idx = $x + $bw*$y
  $script:NewChars[$idx] = $ch
  $script:NewColor[$idx] = $packed
}

# Draw line helper for star trails
function Draw-Line([int]$x0,[int]$y0,[int]$x1,[int]$y1,[char]$ch,[int]$packed,[int]$bw,[int]$bh){
  $dx = [math]::Abs($x1 - $x0)
  $dy = -[math]::Abs($y1 - $y0)
  $sx = ($(if ($x0 -lt $x1) { 1 } else { -1 }))
  $sy = ($(if ($y0 -lt $y1) { 1 } else { -1 }))
  $err = $dx + $dy
  $x = $x0; $y = $y0
  $steps = 0
  $maxSteps = [math]::Max($dx, [math]::Abs($dy)) + 1

  while ($true) {
    # Fade the trail
    $fade = 1.0 - ([double]$steps / [double]$maxSteps * 0.7)
    $r = [byte](([byte](($packed -shr 16) -band 0xFF)) * $fade)
    $g = [byte](([byte](($packed -shr 8)  -band 0xFF)) * $fade)
    $b = [byte](([byte]($packed -band 0xFF)) * $fade)
    $fadedPacked = PackRGB $r $g $b

    Plot $x $y $ch $fadedPacked $bw $bh
    if ($x -eq $x1 -and $y -eq $y1){ break }
    $e2 = 2*$err
    if ($e2 -ge $dy){ $err += $dy; $x += $sx }
    if ($e2 -le $dx){ $err += $dx; $y += $sy }
    $steps++
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
      $maxY = $bh - 2   # avoid last row to prevent scroll
      $centerX = [int]([math]::Floor($bw/2))
      $centerY = [int]([math]::Floor($bh/2))

      # (Re)alloc buffers on size change
      $bufSize = $bw * $bh
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)

        # Reinitialize stars for new screen size
        for ($i = 0; $i -lt $stars.Length; $i++) {
          $stars[$i].Reset($bw, $bh)
        }

        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Update and draw stars
      $dt = $frameMs / 1000.0

      foreach ($star in $stars) {
        # Get previous position for trail
        $prevPos = $star.GetPrevScreenPos($centerX, $centerY)

        # Update star
        $star.Update($dt, $bw, $bh, $centerX, $centerY)

        # Get new position
        $newPos = $star.GetScreenPos($centerX, $centerY)

        # Draw trail if enabled and star moved significantly
        if ($script:UseTrails) {
          $dx = [math]::Abs($newPos[0] - $prevPos[0])
          $dy = [math]::Abs($newPos[1] - $prevPos[1])
          if ($dx -gt 1 -or $dy -gt 1) {
            Draw-Line $prevPos[0] $prevPos[1] $newPos[0] $newPos[1] '.' $star.color $bw $bh
          }
        }

        # Draw star at current position
        Plot $newPos[0] $newPos[1] $star.character $star.color $bw $bh
      }

      # Diff & draw only changed cells (char OR color changed)
      $sb = [System.Text.StringBuilder]::new()
      $lastPacked = -1  # force first color write
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