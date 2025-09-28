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

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cmatrix.ps1
  Classic Matrix effect with default settings.

.EXAMPLE
  .\cmatrix.ps1 -Letters -WhiteLeader -Fps 45
  Human-readable Matrix with white leaders at high framerate.

.EXAMPLE
  .\cmatrix.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(1,5)][int]$Speed = 1,
  [switch]$Letters,
  [switch]$WhiteLeader,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Classic Matrix Digital Rain
===========================

SYNOPSIS
    The iconic Matrix digital rain effect for your terminal.

USAGE
    .\cmatrix.ps1 [OPTIONS]
    .\cmatrix.ps1 -h

DESCRIPTION
    Authentic Matrix-style "digital rain" that overlays on your existing
    terminal content without clearing the background. Features cascading
    green characters with trailing effects, customizable glyph sets, and
    proper terminal behavior with safe cleanup on exit.

OPTIONS
    -Fps <int>         Target frames per second (5-120, default: 30)
    -Speed <int>       Base vertical speed for glyphs (1-5, default: 1)
    -Letters          Include letters for more "human" readable rain
    -WhiteLeader      Use white leading glyphs instead of neon green
    -NoHardClear      Skip full terminal reset on exit
    -h                Show this help and exit

VISUAL MODES
    Standard Mode (default)
        • Symbols and numbers: +=1234567890!@#$%^&*()<>?{}[]~
        • Classic green-on-black Matrix aesthetic
        • Neon green leading characters with fading green trails

    Letters Mode (-Letters)
        • Includes alphabet: ABCDEFGHIJKLMNOPQRSTUVWXYZ
        • More "human" readable appearance
        • Maintains same trailing and color effects

LEADER STYLES
    Green Leaders (default) - Classic neon green Matrix look
    White Leaders (-WhiteLeader) - High contrast white leading characters

EXAMPLES
    .\cmatrix.ps1
        Classic Matrix rain with symbols only

    .\cmatrix.ps1 -Letters -WhiteLeader -Fps 45
        Human-readable rain with white leaders at high speed

    .\cmatrix.ps1 -Speed 3 -Letters
        Fast-moving Matrix with readable characters

    .\cmatrix.ps1 -NoHardClear -Speed 2
        Persistent Matrix overlay (no cleanup on exit)

CONTROLS
    Any key or Ctrl+C to exit

TECHNICAL FEATURES
    - Overlay Mode: Preserves existing terminal content underneath
    - Safe Rendering: Avoids last row to prevent unwanted scrolling
    - Smooth Trails: Intensity-based fading for authentic digital rain
    - Terminal Respect: Adapts to terminal size and theme
    - Clean Exit: Full terminal reset unless -NoHardClear specified

MATRIX AUTHENTICITY
    - One glyph stream per terminal column
    - Variable speed randomization for organic movement
    - Intensity-based trail fading (bright to dim green)
    - Random character cycling for digital chaos effect
    - Proper edge handling and screen bounds respect

PERFORMANCE NOTES
    - Optimized for smooth animation at various framerates
    - Memory efficient with single glyph per column
    - Differential rendering for minimal terminal updates
    - Exception-safe console operations

DIGITAL RAIN PHYSICS
    - Each column maintains independent glyph stream
    - Leading character brightness: full intensity (green/white)
    - Trail characters: graduated green intensity fade
    - Stream reset when reaching bottom of terminal
    - Random starting positions create staggered effect

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

# One glyph per column
function New-GlyphArray([int]$width){
  [Glyph[]]$arr = [Glyph[]]::new($width)
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
$HeadFG = if ($WhiteLeader) { Set-FG 240 240 240 } else { Set-FG 0 255 0 }

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
          Write-Glyph -x $x -y ([int][Math]::Floor($g.CurrentPosition)) -s ($HeadFG + $g.Current)
        }

        if ($g.LastPosition -ge 0 -and $g.LastPosition -le $limitY -and $g.Last -ne ' ' -and $g.LastIntensity -gt 0){
          Write-Glyph -x $x -y ([int][Math]::Floor($g.LastPosition)) -s ((Set-FG 0 ([byte]$g.LastIntensity) 0) + $g.Last)
        }
      }

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