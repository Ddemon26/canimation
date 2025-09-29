<#
.SYNOPSIS
  Rotating ASCII "Smiley Face" coin that updates only changed cells per frame (no full clears).

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites cells that changed (including erasing with space).
  - Matches the cmatrix-style update loop (no CancelKeyPress handler; any key exits, Ctrl+C treated as input).
  - Themes: Gold/Silver/Rainbow (colors per cell with simple shading).

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Size
  Coin radius in characters (default: 12).

.PARAMETER Speed
  Rotation speed multiplier (default: 1.0).

.PARAMETER Thickness
  Coin thickness (0.2-0.9, default: 0.45).

.PARAMETER Theme
  Coin color theme. Options: Gold, Silver, Rainbow. (Default: Gold)

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.EXAMPLE
  .\csmiley.ps1
  Run with default gold coin.

.EXAMPLE
  .\csmiley.ps1 -Theme Rainbow -Size 20
  Large rainbow smiley coin.

.EXAMPLE
  .\csmiley.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(8,60)][int]$Size = 12,
  [double]$Speed = 1.0,
  [ValidateRange(0.2,0.9)][double]$Thickness = 0.45,
  [ValidateSet('Gold','Silver','Rainbow')][string]$Theme = 'Gold',
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Rotating Smiley Face Coin
=========================

SYNOPSIS
    3D rotating ASCII smiley face coin with shading and color themes.

USAGE
    .\csmiley.ps1 [OPTIONS]
    .\csmiley.ps1 -h

DESCRIPTION
    A spinning coin featuring a classic smiley face (two eyes and a smile).
    The coin rotates in 3D space with proper depth shading and thickness.
    Choose from metallic or rainbow themes. Uses differential rendering
    for smooth animation.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Size <int>         Coin radius in characters (8-60, default: 12)
    -Speed <double>     Rotation speed multiplier (default: 1.0)
    -Thickness <double> Coin thickness (0.2-0.9, default: 0.45)
    -Theme <string>     Color theme (default: Gold)
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

THEMES
    Gold      Golden yellow coin with metallic shading
    Silver    Shiny silver/gray coin
    Rainbow   Multi-colored rainbow gradient

EXAMPLES
    .\csmiley.ps1
        Default gold coin

    .\csmiley.ps1 -Theme Silver
        Silver metallic coin

    .\csmiley.ps1 -Theme Rainbow -Size 20
        Large rainbow smiley

    .\csmiley.ps1 -Speed 2 -Fps 60
        Fast-spinning coin at high framerate

    .\csmiley.ps1 -Size 30 -Thickness 0.7
        Large, thick coin

    .\csmiley.ps1 -Theme Gold -Speed 0.5
        Slow, smooth gold coin rotation

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Features classic smiley face (two eyes and curved smile)
    - 3D rotation with proper depth perspective
    - Thickness parameter affects coin's 3D appearance
    - Larger Size values work best in wide terminals
    - Shading creates realistic metallic appearance
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
$AnsiClearFull   = "$e[3J$e[2J$e[H"
$AnsiScrollUpMax = "$e[9999S"
$RIS             = "$e" + "c"

# Key helpers (non-blocking)
function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

# --- Math helpers ---------------------------------------------------------------
function Clamp01([double]$v){ if ($v -lt 0){ 0.0 } elseif ($v -gt 1){ 1.0 } else { $v } }
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
function Shade-Color([byte[]]$rgb, [double]$shade){
  $s = [double](Clamp01 $shade)
  $r = [byte]([math]::Round([double]$rgb[0] * (0.4 + 0.6*$s)))
  $g = [byte]([math]::Round([double]$rgb[1] * (0.4 + 0.6*$s)))
  $b = [byte]([math]::Round([double]$rgb[2] * (0.4 + 0.6*$s)))
  return ,([byte[]]@($r,$g,$b))
}
function Theme-BaseRGB([double]$hueShift){
  switch ($Theme) {
    'Gold'   { return ,([byte[]]@(255, 200, 0)) }
    'Silver' { return ,([byte[]]@(200, 200, 215)) }
    'Rainbow'{ $rgb = HSV-To-RGB ((($hueShift*360) % 360)) 0.9 1.0; return ,$rgb }
    default  { return ,([byte[]]@(255, 200, 0)) }
  }
}
function PackRGB([byte]$r,[byte]$g,[byte]$b){ return ([int]$r -shl 16) -bor ([int]$g -shl 8) -bor ([int]$b) }

# --- Cached buffers -------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null   # char[]
$script:PrevColor = $null   # int[] packed RGB
$script:NewChars  = $null   # char[]
$script:NewColor  = $null   # int[] packed RGB

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$angle = 0.0

# Save console state; hide cursor
$originalFG  = [Console]::ForegroundColor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Treat Ctrl+C as input (avoid CancelKeyPress runspace issues)
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}

# Do an initial clear so the first diff writes onto a clean screen
try { [Console]::Write($AnsiClearHome) } catch {}

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2   # avoid last row to prevent scroll
      $cx = [int]([math]::Floor($bw/2))
      $cy = [int]([math]::Floor($bh/2))

      # (Re)alloc buffers on size change
      $bufSize = $bw * $bh
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

      # Rotation update
      $dt = $frameMs / 1000.0
      $angle += ($Speed * 1.2 * $dt)
      $cosA = [math]::Cos($angle)
      $sinA = [math]::Sin($angle)
      $sx = $Thickness + (1.0 - $Thickness) * [math]::Abs($cosA)   # horizontal squash 0.25..1.0

      # Theme base color (Rainbow hue shifts with angle)
      $base = Theme-BaseRGB ([math]::Abs($angle / (2*[math]::PI)))

      # Draw ellipse rows into New buffers
      for ($ry = -$Size; $ry -le $Size; $ry++){
        $ny = [double]$ry / [double]$Size
        $rowRadius = [double]$Size * [math]::Sqrt([math]::Max(0.0, 1.0 - ($ny*$ny)))
        $halfWidth = [int]([math]::Round($rowRadius * $sx))
        if ($halfWidth -le 0){ continue }

        $y = $cy + $ry
        if ($y -lt 0 -or $y -gt $maxY){ continue }

        $total = 2*$halfWidth + 1
        # segment-based shading across width (up to 12 segments)
        $segments = [Math]::Max(1, [Math]::Min(12, [int]([double]$total / 2)))
        $segLen = [Math]::Max(1, [int]([math]::Floor([double]$total / [double]$segments)))
        $written = 0

        for ($s = 0; $s -lt $segments; $s++){
          $len = if ($s -eq $segments-1) { $total - $written } else { $segLen }
          $xStart = $cx - $halfWidth + $written
          $written += $len

          # segment center normalized across [-1..1]
          $segCenter = ($xStart + ([double]$len/2.0) - ($cx)) / [double]$halfWidth
          $segCenter = [math]::Max(-1.0, [math]::Min(1.0, $segCenter))

          # brighter at center; dims toward edges; modulate by |cos(angle)|
          $shade = Clamp01 (0.55 + 0.35 * (1.0 - ($segCenter*$segCenter)) * [math]::Abs($cosA))
          $shade = Clamp01 ($shade - 0.15 * (1.0 - [math]::Abs($cosA)))

          $rgb = Shade-Color $base $shade
          $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]

          # fill run
          for ($dx = 0; $dx -lt $len; $dx++){
            $x = $xStart + $dx
            if ($x -lt 0 -or $x -gt $maxX){ continue }
            $idx = $x + $bw*$y
            $script:NewChars[$idx] = '#'
            $script:NewColor[$idx] = $packed
          }
        }
      }

      # Smiley overlay (front face only)
      if ($cosA -ge 0.0){
        $eyeOffsetY = -[int]([math]::Round($Size * 0.25))
        $eyeOffsetX = [int]([math]::Round($Size * 0.4 * $sx))
        $mouthY     =  [int]([math]::Round($Size * 0.25))
        $black = PackRGB 0 0 0

        # Eyes
        $ey1x = $cx - $eyeOffsetX; $ey1y = $cy + $eyeOffsetY
        $ey2x = $cx + $eyeOffsetX; $ey2y = $cy + $eyeOffsetY
        if ($ey1x -ge 0 -and $ey1x -le $maxX -and $ey1y -ge 0 -and $ey1y -le $maxY){
          $idx = $ey1x + $bw*$ey1y; $script:NewChars[$idx] = 'o'; $script:NewColor[$idx] = $black
        }
        if ($ey2x -ge 0 -and $ey2x -le $maxX -and $ey2y -ge 0 -and $ey2y -le $maxY){
          $idx = $ey2x + $bw*$ey2y; $script:NewChars[$idx] = 'o'; $script:NewColor[$idx] = $black
        }

        # Mouth arc
        $mouthHalf = [int]([math]::Round($Size * 0.45 * $sx))
        $mseg = [Math]::Max(6, [int]([double]$mouthHalf))
        for ($i= -$mseg; $i -le $mseg; $i++){
          $t = [double]$i / [double]$mseg   # -1..1
          $mx = [int]([math]::Round($cx + $t * $mouthHalf))
          $my = $cy + $mouthY + [int]([math]::Round((1 - ($t*$t)) * 1))
          if ($mx -ge 0 -and $mx -le $maxX -and $my -ge 0 -and $my -le $maxY){
            $idx = $mx + $bw*$my; $script:NewChars[$idx] = '.'; $script:NewColor[$idx] = $black
          }
        }
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
