<#
.SYNOPSIS
  Text ring / rotating marquee around a circle (diff-write, cmatrix-style).

.DESCRIPTION
  - Wraps a word/phrase around a circle and rotates it smoothly.
  - Only rewrites changed cells per frame (diff-write), like your cmatrix scripts.
  - Any key exits (Ctrl+C treated as input). cmatrix-style shutdown with -NoHardClear.

.PARAMETER Text
  Word or phrase to wrap (default: "HELLO WORLD").

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Size
  Radius in characters (default: 14).

.PARAMETER Speed
  Rotation speed multiplier (default: 1.0).

.PARAMETER Spacing
  Character spacing factor around ring (0.5 .. 2.0). 1.0 ≈ one char per step. Default: 1.0.

.PARAMETER Rainbow
  Rainbow colors around the ring (default: off). If off, uses -Color.

.PARAMETER Color
  Base color name if not using rainbow. One of: Green, Cyan, Magenta, Yellow, White, Red, Blue. Default: Green.

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.EXAMPLE
  .\ctextring.ps1
  Display "HELLO WORLD" in green.

.EXAMPLE
  .\ctextring.ps1 -Text "AWESOME" -Rainbow
  Display custom text with rainbow colors.

.EXAMPLE
  .\ctextring.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [string]$Text = "HELLO WORLD",
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(6,80)][int]$Size = 14,
  [double]$Speed = 1.0,
  [ValidateRange(0.5,2.0)][double]$Spacing = 1.0,
  [switch]$Rainbow,
  [ValidateSet('Green','Cyan','Magenta','Yellow','White','Red','Blue')][string]$Color = 'Green',
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Rotating Text Ring
==================

SYNOPSIS
    Text arranged in a circle that rotates smoothly like a marquee.

USAGE
    .\ctextring.ps1 [OPTIONS]
    .\ctextring.ps1 -h

DESCRIPTION
    Wraps your text around a circular path and rotates it continuously.
    Characters are positioned along the circle's edge and spin smoothly.
    Choose solid colors or rainbow gradients. Perfect for displaying
    messages, names, or decorative text in a rotating loop.

OPTIONS
    -Text <string>      Text to display (default: "HELLO WORLD")
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Size <int>         Circle radius in characters (6-80, default: 14)
    -Speed <double>     Rotation speed multiplier (default: 1.0)
    -Spacing <double>   Character spacing (0.5-2.0, default: 1.0)
                        1.0 = normal, <1.0 = tight, >1.0 = loose
    -Rainbow            Use rainbow gradient colors
    -Color <string>     Solid color (default: Green)
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

COLOR OPTIONS
    Green, Cyan, Magenta, Yellow, White, Red, Blue
    (Only used when -Rainbow is not specified)

EXAMPLES
    .\ctextring.ps1
        Default "HELLO WORLD" in green

    .\ctextring.ps1 -Text "AWESOME" -Rainbow
        Custom text with rainbow colors

    .\ctextring.ps1 -Text "*** PARTY TIME ***" -Size 20 -Color Magenta
        Large magenta ring

    .\ctextring.ps1 -Text "SPINNING" -Speed 2 -Rainbow -Fps 60
        Fast rainbow spin at high framerate

    .\ctextring.ps1 -Text "COOL" -Spacing 1.5 -Color Cyan
        Looser character spacing in cyan

    .\ctextring.ps1 -Text "HAPPY BIRTHDAY!" -Size 25 -Rainbow -Speed 0.5
        Large, slow rainbow birthday message

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Text repeats around the circle if needed
    - Larger Size values need wider terminals
    - Spacing affects how tight/loose characters are arranged
    - Rainbow mode creates smooth color gradients
    - Speed can be fractional for slower rotation (e.g., 0.5)
    - Uses differential rendering (only updates changed cells)

"@
    Write-Host $helpText
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Text)){ $Text = "HELLO" }

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
function BaseColor(){
  switch ($Color) {
    'Green'   { return (PackRGB 0 255 0) }
    'Cyan'    { return (PackRGB 0 220 255) }
    'Magenta' { return (PackRGB 255 100 255) }
    'Yellow'  { return (PackRGB 255 220 0) }
    'White'   { return (PackRGB 255 255 255) }
    'Red'     { return (PackRGB 255 60 60) }
    'Blue'    { return (PackRGB 100 140 255) }
    default   { return (PackRGB 0 255 0) }
  }
}

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
$angle = 0.0    # rotation (radians)

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
      $cx = [int]([math]::Floor($bw/2))
      $cy = [int]([math]::Floor($bh/2))
      $aspect = if ($bh -gt 0){ [double]$bw / [double]$bh } else { 1.0 }

      # Resize buffers on console size change
      $bufSize = $bw * $bh
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Clear New buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Update rotation
      $dt = $frameMs / 1000.0
      $angle += ($Speed * 1.8 * $dt)   # radians per frame

      $n = [math]::Max(1, $Text.Length)
      $step = (6.283185307179586) / ($n * $Spacing)
      $rx = [double]$Size * $aspect
      $ry = [double]$Size

      $baseCol = (BaseColor)

      for ($i=0; $i -lt $n; $i++){
        $ch = $Text[$i]
        $a  = $angle + $i * $step
        $x  = [int]([math]::Round($cx + $rx * [math]::Cos($a)))
        $y  = [int]([math]::Round($cy + $ry * [math]::Sin($a)))
        if ($x -ge 0 -and $x -le $maxX -and $y -ge 0 -and $y -le $maxY){
          if ($Rainbow){
            $h = (($i / [double]$n) * 360.0 + ($angle*180.0/[math]::PI)*0.8) % 360
            $rgb = HSV-To-RGB $h 1.0 1.0
            $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
          } else {
            $packed = $baseCol
          }
          $idx = $x + $bw*$y
          $script:NewChars[$idx] = $ch
          $script:NewColor[$idx] = $packed
        }
      }

      # Diff & draw: only rewrite changed cells (char OR color changed)
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
