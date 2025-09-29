<#
.SYNOPSIS
  Matrix-ish console rain for modern PowerShell (7+), overlays on existing text.

.DESCRIPTION
  - No background painting while running; respects your terminal theme.
  - Does NOT wipe on start (overlays and trickles over your existing text).
  - On EXIT: hard clear by default (RIS) to eliminate any leftover frames; opt-out via -NoHardClear.
  - Clamps drawing to buffer bounds; avoids ONLY the last row to prevent wrap/scroll (rightmost column is allowed).
  - Preserves trail intensity across resets to avoid bottom-row artifacts.
  - Wraps console calls to avoid unhandled exceptions and always restores state.
  - Optional lettered glyph set, adjustable FPS and speed.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Speed
  Base vertical speed for glyphs (default: 1).

.PARAMETER Letters
  Include letters (more "human" looking). Default is symbols-only.

.PARAMETER WhiteLeader
  Use white for the leading glyph instead of neon green.

.PARAMETER NoHardClear
  Skip the hard terminal reset on exit. (Default is to hard-clear.)

.PARAMETER Theme
  Color theme for the matrix rain (default: Rainbow).

.EXAMPLE
  .\cmatrix-themes.ps1
  Run with default Rainbow theme.

.EXAMPLE
  .\cmatrix-themes.ps1 -Theme Matrix -Letters
  Classic Matrix green with letter glyphs.

.EXAMPLE
  .\cmatrix-themes.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(1,5)][int]$Speed = 1,
  [switch]$Letters,
  [switch]$WhiteLeader,
  [switch]$NoHardClear,
  [ValidateSet('Matrix','Rainbow','Aurora','Cyberpunk','Fire','Ice','Grayscale','Amber','Pride','Christmas','Sunset','RandomGlyph')]
  [string]$Theme = 'Rainbow',
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Matrix Rain with Themes
=======================

SYNOPSIS
    Matrix-style falling characters with multiple color themes and effects.

USAGE
    .\cmatrix-themes.ps1 [OPTIONS]
    .\cmatrix-themes.ps1 -h

DESCRIPTION
    Classic Matrix-style digital rain overlaid on your existing terminal content.
    Features multiple color themes, optional letter glyphs, and configurable speed.
    Respects your terminal theme and doesn't clear on start.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Speed <int>        Vertical glyph speed (1-5, default: 1)
    -Letters            Include letter characters (more readable)
    -WhiteLeader        White leading glyph instead of bright green
    -Theme <string>     Color theme (default: Rainbow)
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

THEMES
    Matrix        Classic neon green (the original)
    Rainbow       Each column has a different rainbow color
    Aurora        Shifting aurora-like colors
    Cyberpunk     Cyan/blue cyberpunk aesthetic
    Fire          Orange/red flame colors
    Ice           Cool blue/white icy tones
    Grayscale     Black and white only
    Amber         Warm amber/orange (retro terminal)
    Pride         Rainbow pride colors
    Christmas     Red and green festive colors
    Sunset        Orange to purple sunset gradient
    RandomGlyph   Random colors per glyph

EXAMPLES
    .\cmatrix-themes.ps1
        Default rainbow theme

    .\cmatrix-themes.ps1 -Theme Matrix -Letters
        Classic Matrix look with readable letters

    .\cmatrix-themes.ps1 -Theme Fire -Speed 3 -Fps 60
        Fast-moving fire theme at high framerate

    .\cmatrix-themes.ps1 -Theme Cyberpunk -WhiteLeader
        Cyberpunk theme with white leading characters

    .\cmatrix-themes.ps1 -Theme Aurora -Letters -Speed 2
        Shifting aurora colors with letters at medium speed

    .\cmatrix-themes.ps1 -Theme Ice -NoHardClear
        Icy theme, leaves screen as-is on exit

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Overlays on existing terminal content (doesn't clear on start)
    - By default, performs hard clear on exit to remove all trails
    - Letters switch makes glyphs more readable/recognizable
    - Speed affects how fast columns fall (1=slow, 5=very fast)
    - Each theme has unique color characteristics and feels

"@
    Write-Host $helpText
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- ANSI helpers -------------------------------------------------------------
$e = "`e"  # ESC
function Set-FG([byte]$r,[byte]$g,[byte]$b){ "$e[38;2;${r};${g};${b}m" }
$AnsiReset       = "$e[0m"
$AnsiClearFull   = "$e[3J$e[2J$e[H"   # clear scrollback + screen + home
$AnsiScrollUpMax = "$e[9999S"         # aggressive viewport scroll
$RIS             = "$e" + "c"         # HARD reset (Reset to Initial State)
# Rainbow helpers
function HSV-To-RGB([double]$h, [double]$s, [double]$v){
  # $h in [0,360), $s,$v in [0,1]
  if ($s -le 0){ $r = $v; $g = $v; $b = $v }
  else {
    $hh = ($h % 360) / 60.0
    $i = [int][math]::Floor($hh)
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


# --- Safe console helpers -----------------------------------------------------
function Get-DrawBounds {
  try {
    $ui  = $Host.UI.RawUI
    $win = $ui.WindowSize
    try {
      $buf = $ui.BufferSize
      if ($buf.Width -ne $win.Width -or $buf.Height -ne $win.Height) {
        $ui.BufferSize = $win
      }
    } catch { }
    $bufW = [Console]::BufferWidth
    $bufH = [Console]::BufferHeight
    if ($bufW -le 0) { $bufW = 1 }
    if ($bufH -le 0) { $bufH = 1 }
    [pscustomobject]@{
      Width  = [Math]::Max(1,[Math]::Min($win.Width,  $bufW))
      Height = [Math]::Max(1,[Math]::Min($win.Height, $bufH))
    }
  } catch {
    [pscustomobject]@{ Width = 80; Height = 25 }
  }
}

function Test-KeyAvailable { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key         { try { return [Console]::ReadKey($true) } catch { return $null } }

function Write-Glyph([int]$x, [int]$y, [string]$s) {
  try {
    $bw = [Console]::BufferWidth
    $bh = [Console]::BufferHeight
    $maxX = $bw - 1   # allow last column
    $maxY = $bh - 2   # still avoid the last row
    if ($maxX -lt 0 -or $maxY -lt 0) { return }
    if ($x -lt 0 -or $y -lt 0 -or $x -gt $maxX -or $y -gt $maxY) { return }
    [Console]::SetCursorPosition($x,$y)
    [Console]::Write($s)
  } catch { }
}

# --- Glyph class --------------------------------------------------------------
class Glyph {
  [int]$LastPosition
  [int]$CurrentPosition
  [int]$Velocity
  [int]$Intensity
  [int]$LastIntensity
  [double]$IntensityChange
  [char]$Current
  [char]$Last

  Glyph(){
    $this.Setup()
  }

  [void]Setup(){
    $this.CurrentPosition = $script:Rand.Next(-$script:ScreenHeight, [int]([double]$script:ScreenHeight * 0.6))
    $this.Velocity       = $script:BaseSpeed
    $this.Intensity      = 0
    $this.IntensityChange = ($script:Rand.Next(1,20) / 100.0)
    $this.Current        = $script:PossibleGlyphs[$script:Rand.Next($script:GlyphCount)]
    $this.Last           = $script:PossibleGlyphs[$script:Rand.Next($script:GlyphCount)]
  }

  [void]Move(){
    $this.LastPosition  = $this.CurrentPosition
    $this.LastIntensity = $this.Intensity
    $this.Last          = $this.Current

    $this.Intensity += [Math]::Floor(255 * $this.IntensityChange)
    if ($this.Intensity -gt 255){ $this.Intensity = 255 }

    $this.CurrentPosition += $this.Velocity

    if ($this.Current -ne ' '){
      $this.Current = $script:PossibleGlyphs[$script:Rand.Next($script:GlyphCount)]
    }

    if ($this.CurrentPosition -gt ($script:ScreenHeight - 1)){
      $this.Setup()
    }
  }
}
# --- Theme helpers --------------------------------------------------------------
# Returns a [byte[]] RGB for the base color of a glyph at ($x,$y)
function Get-ThemeBaseRGB([int]$x, [int]$y){
  switch ($Theme) {
    'Matrix'      { return ,([byte[]]@(0,255,0)) }
    'Rainbow'     { return ,$script:ColumnRGB[$x] }
    'Aurora'      { $h = (($x * 12) + $script:Frame * 2) % 360; return ,(HSV-To-RGB $h 1.0 1.0) }
    'Cyberpunk'   { if (-not $script:ColumnRGB){ $script:ColumnRGB = @(); for($i=0;$i -lt $script:ScreenWidth;$i++){ $script:ColumnRGB += ,([byte[]]@(0,255,255)); $script:ColumnRGB[$i] = ([byte[]]@((@(0,255,255), @(255,0,255))[$script:Rand.Next(0,2)])) } }; return ,$script:ColumnRGB[$x] }
    'Fire'        { return ,([byte[]]@(255,140,0)) }  # orange base, head brightens
    'Ice'         { return ,([byte[]]@(0,180,255)) }
    'Grayscale'   { return ,([byte[]]@(255,255,255)) }
    'Amber'       { return ,([byte[]]@(255,191,0)) }
    'Pride'       { $bands = @(@(228,3,3), @(255,140,0), @(255,238,0), @(0,128,38), @(36,64,142), @(115,41,130));
                    $bandH = [Math]::Max(1, [int]([double]$script:ScreenHeight / $bands.Count));
                    $idx = [Math]::Min($bands.Count-1, [int]([math]::Floor($y / $bandH)));
                    return ,([byte[]]@($bands[$idx])) }
    'Christmas'   { if (($x % 2) -eq 0) { return ,([byte[]]@(200,0,0)) } else { return ,([byte[]]@(0,150,0)) } }
    'Sunset'      { $t = 0; if ($script:ScreenHeight -gt 0){ $t = [double]$y / [double]$script:ScreenHeight }
                    $r = [byte]([math]::Round(255 * (0.6 + 0.4 * (1-$t))))
                    $g = [byte]([math]::Round(90  + 130 * (1-$t)))
                    $b = [byte]([math]::Round(0   + 50  * (1-$t)))
                    return ,([byte[]]@($r,$g,$b)) }
    'RandomGlyph' { return ,([byte[]]@([byte]$script:Rand.Next(0,256), [byte]$script:Rand.Next(0,256), [byte]$script:Rand.Next(0,256))) }
    default       { return ,([byte[]]@(0,255,0)) }
  }
}

# Initialize per-column colors for themes that need it
function Init-Theme(){
  $script:ColumnRGB = @()
  switch ($Theme) {
    'Rainbow' {
      for ($i = 0; $i -lt $script:ScreenWidth; $i++){
        $h = $script:Rand.NextDouble() * 360.0
        $script:ColumnRGB += ,(HSV-To-RGB $h 1.0 1.0)
      }
    }
    'Cyberpunk' {
      for ($i = 0; $i -lt $script:ScreenWidth; $i++){
        if ($script:Rand.Next(0,2) -eq 0){
          $script:ColumnRGB += ,([byte[]]@(0,255,255))  # cyan
        } else {
          $script:ColumnRGB += ,([byte[]]@(255,0,255))  # magenta
        }
      }
    }
    default { } # no per-column init needed
  }
}


# --- Setup shared state -------------------------------------------------------
$script:Rand = [System.Random]::new()
$script:BaseSpeed = [Math]::Max(1,$Speed)

# Glyph set
if ($Letters){
  [char[]]$script:PossibleGlyphs = "   ACBDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()<>?{}[]<>~".ToCharArray()
} else {
  [char[]]$script:PossibleGlyphs = "   +=1234567890!@#$%^&*()<>?{}[]<>~".ToCharArray()
}
$script:GlyphCount = $script:PossibleGlyphs.Count

# Bounds
$bounds = Get-DrawBounds
$script:ScreenWidth  = $bounds.Width
$script:ScreenHeight = $bounds.Height



$script:Frame = 0
Init-Theme
$script:Frame = 0
# One glyph per column
function New-GlyphArray([int]$width){
  [Glyph[]]$arr = [Glyph[]]::new($width)
  # Generate a random rainbow base color for each column
  $script:ColumnRGB = @()
  for ($i = 0; $i -lt $width; $i++){
    $h = $script:Rand.NextDouble() * 360.0
    $rgb = HSV-To-RGB $h 1.0 1.0
    $script:ColumnRGB += ,$rgb
  }
  for ($i = 0; $i -lt $arr.Count; $i++){ $arr[$i] = [Glyph]::new() }
  return $arr
}
$AllGlyphs = New-GlyphArray -width $script:ScreenWidth

# Save console state
$originalFG  = [Console]::ForegroundColor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}


# Ctrl+C as input (avoid runspace issues with CancelKeyPress)
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}
# Colors
$WhiteHeadFG = Set-FG 240 240 240

# Main loop
$frameMs = [int](1000 / $Fps)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$global:__matrix_stop = $false

try {
  while (-not $global:__matrix_stop){
    if (Test-KeyAvailable){
      $null = Read-Key
      break
    }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bounds = Get-DrawBounds
      if ($bounds.Width -ne $script:ScreenWidth -or $bounds.Height -ne $script:ScreenHeight){
        $script:ScreenWidth  = $bounds.Width
        $script:ScreenHeight = $bounds.Height
        
$script:Frame = 0
$AllGlyphs = New-GlyphArray -width $script:ScreenWidth
      }

      $bufW = [Console]::BufferWidth
      $bufH = [Console]::BufferHeight
      if ($bufW -le 0) { $bufW = 1 }
      if ($bufH -le 0) { $bufH = 1 }
      # Allow last column, still avoid last row
      $limitX = [Math]::Max(0, [Math]::Min($script:ScreenWidth,  $bufW) - 1)
      $limitY = [Math]::Max(0, [Math]::Min($script:ScreenHeight, $bufH) - 2)

      for ($x = 0; $x -le $limitX; $x++){
        $g = $AllGlyphs[$x]
        $g.Move()

        if ($g.CurrentPosition -ge 0 -and $g.CurrentPosition -le $limitY){
          Write-Glyph -x $x -y ([int][Math]::Floor($g.CurrentPosition)) -s ($( if ($WhiteLeader) { $WhiteHeadFG } else { $c = (Get-ThemeBaseRGB $x ([int][Math]::Floor($g.CurrentPosition))); Set-FG ([byte]$c[0]) ([byte]$c[1]) ([byte]$c[2]) } ) + $g.Current)
        }

        if ($g.LastPosition -ge 0 -and $g.LastPosition -le $limitY -and $g.Last -ne ' ' -and $g.LastIntensity -gt 0){
          Write-Glyph -x $x -y ([int][Math]::Floor($g.LastPosition)) -s ($( $c = (Get-ThemeBaseRGB $x ([int][Math]::Floor($g.LastPosition))); $ir=[byte]([math]::Floor($c[0]*$g.LastIntensity/255)); $ig=[byte]([math]::Floor($c[1]*$g.LastIntensity/255)); $ib=[byte]([math]::Floor($c[2]*$g.LastIntensity/255)); Set-FG $ir $ig $ib ) + $g.Last)
        }
      }

      $script:Frame++
      $sw.Restart()
    } else {
      Start-Sleep -Milliseconds 1
    }
  }
}
catch {
  $global:__matrix_stop = $true
}
finally {
  try { [Console]::TreatControlCAsInput = $origTreatCtrlC } catch {}
[Console]::Write($AnsiReset)
  try { [Console]::CursorVisible = $originalVis } catch {}
  if (Get-Variable -Name __matrix_stop -Scope Global -ErrorAction SilentlyContinue) {
    Remove-Variable -Name __matrix_stop -Scope Global -Force
  }

  if ($NoHardClear) {
    try { [Console]::SetCursorPosition(0,0) } catch {}
    [Console]::ForegroundColor = $originalFG
  } else {
    try {
      $ui = $Host.UI.RawUI
      $ui.BufferSize = $ui.WindowSize
    } catch {}

    try { [Console]::Write($AnsiClearFull) } catch {}
    try { [Console]::Write($AnsiScrollUpMax) } catch {}

    try {
      [Console]::Write($RIS)  # final write
    } catch {}
  }
}