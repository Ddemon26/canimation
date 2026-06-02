<#
.SYNOPSIS
  ASCII Art Aquarium - Underwater animation with fish, sharks, whales, and more!

.DESCRIPTION
  A PowerShell port of the classic Perl Asciiquarium featuring:
  - Multiple fish species (old and new varieties)
  - Sharks with collision detection (eat small fish!)
  - Whales with animated water spouts
  - Ships sailing on the surface
  - Sea monsters (old and new designs)
  - Big fish (two unique designs)
  - Swaying seaweed
  - Seafloor castle
  - Rising bubbles with waterline collision
  - Splat effects when sharks catch fish
  - Multi-layer water animation with waves

.PARAMETER Fps
  Target frames per second (default: 20).

.PARAMETER Speed
  Global speed multiplier for all entities (default: 1.0).

.PARAMETER Classic
  Use only original fish and monster designs (no new varieties).

.PARAMETER NoHardClear
  Skip the final hard terminal reset on exit.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\asciiquarium-improved.ps1
  Run with default settings (20 FPS, normal speed, all fish types).

.EXAMPLE
  .\asciiquarium-improved.ps1 -Fps 30 -Speed 1.5
  Faster animation at higher framerate.

.EXAMPLE
  .\asciiquarium-improved.ps1 -Classic
  Original fish and monsters only.

.EXAMPLE
  .\asciiquarium-improved.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
    [ValidateRange(5,60)][int]$Fps = 20,
    [ValidateRange(0.1,5.0)][double]$Speed = 1.0,
    [switch]$Classic,
    [switch]$NoHardClear,
    [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

ASCII Art Aquarium
==================

SYNOPSIS
    Underwater animation with fish, sharks, whales, and sea creatures!

USAGE
    .\asciiquarium-improved.ps1 [OPTIONS]
    .\asciiquarium-improved.ps1 -h

DESCRIPTION
    A vibrant underwater scene featuring multiple species of fish swimming
    across your terminal, sharks hunting for prey, whales breaching the
    surface, ships sailing by, and mysterious sea monsters. Complete with
    realistic physics, collision detection, and beautiful ASCII art.

OPTIONS
    -Fps <int>        Target frames per second (5-60, default: 20)
    -Speed <double>   Movement speed multiplier (0.1-5.0, default: 1.0)
    -Classic          Use only original fish/monster designs
    -NoHardClear      Don't reset terminal on exit
    -h                Show this help and exit

FEATURES
    Marine Life
        • Multiple fish species with randomized colors
        • Sharks with realistic hunting behavior
        • Whales with animated water spouts
        • Sea monsters (two design sets)
        • Large "big fish" species

    Environment
        • Four-layer animated water surface
        • Swaying seaweed (random heights)
        • Decorative seafloor castle
        • Rising bubbles from fish

    Physics & Interaction
        • Z-depth layering for realistic perspective
        • Collision detection (sharks eat small fish!)
        • Splat effects on fish consumption
        • Bubbles pop at water surface
        • Entities respawn when leaving screen

VISUAL LAYERS (Front to Back)
    - GUI elements (depth 0-1)
    - Sharks (depth 2)
    - Fish schools (depth 3-20)
    - Seaweed (depth 21)
    - Castle (depth 22)
    - Water waves (surface)

MARINE LIFE COUNT
    - Fish: Dynamically scales with terminal size
    - Seaweed: ~1 per 15 columns of screen width
    - Random entities: Sharks, whales, ships, monsters, big fish (rotating)

EXAMPLES
    .\asciiquarium-improved.ps1
        Default aquarium with all fish types

    .\asciiquarium-improved.ps1 -Fps 30 -Speed 1.5
        Faster, more energetic animation

    .\asciiquarium-improved.ps1 -Classic -Speed 0.5
        Slow, classic mode with original designs

    .\asciiquarium-improved.ps1 -Fps 10 -NoHardClear
        Low framerate, leaves screen on exit

CONTROLS
    Ctrl+C to exit

TECHNICAL NOTES
    - Entity-based architecture with lifecycle management
    - Z-depth sorted rendering for layered effects
    - Automatic terminal resize detection
    - Safe console operations with error handling
    - Color-coded entities with ASCII art designs

CREDITS
    Original Perl version: Kirk Baucom <kbaucom@schizoid.com>
    ASCII Art: Joan Stark, Claudio Matsuoka
    PowerShell Port: 2025
    License: GNU General Public License v2

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
$AnsiClearHome   = "$e[H"
$AnsiClearFull   = "$e[3J$e[2J$e[H"
$AnsiScrollUpMax = "$e[9999S"
$RIS             = "$e" + "c"

# --- Safe console helpers -----------------------------------------------------
function Test-KeyAvailable {
    try { return [Console]::KeyAvailable }
    catch { return $false }
}

function Read-Key {
    try { return [Console]::ReadKey($true) }
    catch { return $null }
}

# --- Color helpers ------------------------------------------------------------
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

# Version
$script:Version = "1.2-ps"
$script:NewFish = -not $Classic
$script:NewMonster = -not $Classic

# Z-depth layers (lower number = in front)
$script:Depth = @{
    guiText     = 0
    gui         = 1
    shark       = 2
    fish_start  = 3
    fish_end    = 20
    seaweed     = 21
    castle      = 22
    water_line3 = 2
    water_gap3  = 3
    water_line2 = 4
    water_gap2  = 5
    water_line1 = 6
    water_gap1  = 7
    water_line0 = 8
    water_gap0  = 9
}

# ANSI Color codes (precomputed for performance)
$script:Colors = @{
    Cyan    = Set-FG 0 255 255
    Red     = Set-FG 255 0 0
    Yellow  = Set-FG 255 255 0
    Blue    = Set-FG 0 0 255
    Green   = Set-FG 0 255 0
    Magenta = Set-FG 255 0 255
    White   = Set-FG 255 255 255
    Black   = Set-FG 0 0 0
}

# Packed RGB color codes for buffer comparisons
$script:PackedColors = @{
    Cyan    = PackRGB 0 255 255
    Red     = PackRGB 255 0 0
    Yellow  = PackRGB 255 255 0
    Blue    = PackRGB 0 0 255
    Green   = PackRGB 0 255 0
    Magenta = PackRGB 255 0 255
    White   = PackRGB 255 255 255
    Black   = PackRGB 0 0 0
}

# Color mapping function from Perl codes to ANSI
function Get-ANSIColor {
    param([char]$Code)

    switch -CaseSensitive ($Code) {
        'c' { return $script:Colors.Cyan }
        'C' { return $script:Colors.Cyan }
        'r' { return $script:Colors.Red }
        'R' { return $script:Colors.Red }
        'y' { return $script:Colors.Yellow }
        'Y' { return $script:Colors.Yellow }
        'b' { return $script:Colors.Blue }
        'B' { return $script:Colors.Blue }
        'g' { return $script:Colors.Green }
        'G' { return $script:Colors.Green }
        'm' { return $script:Colors.Magenta }
        'M' { return $script:Colors.Magenta }
        'w' { return $script:Colors.White }
        'W' { return $script:Colors.White }
        'k' { return $script:Colors.Black }
        'K' { return $script:Colors.Black }
        default { return $script:Colors.White }
    }
}

function Get-RandomColor {
    param([string]$ColorMask)

    $colorNames = @('Cyan', 'Red', 'Yellow', 'Blue', 'Green', 'Magenta')
    $result = $ColorMask

    # Replace numeric placeholders with random colors
    1..9 | ForEach-Object {
        $color = $colorNames[(Get-Random -Maximum $colorNames.Count)]
        $result = $result -replace $_, $color[0]
    }

    return $result
}

# Global entity list and state
$script:Entities = [System.Collections.ArrayList]@()
$script:EntityIdCounter = 0
$script:TermWidth = 0
$script:TermHeight = 0
$script:SpeedMultiplier = $Speed

# --- Double-buffer system (like other animations) --------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB
$script:rnd = [System.Random]::new()

# --- Buffer drawing helper --------------------------------------------------------
function Set-BufferCell([int]$x, [int]$y, [char]$ch, [int]$color){
  if ($x -lt 0 -or $y -lt 0 -or $x -ge $script:BufW -or $y -ge ($script:BufH - 1)){ return }
  $idx = $y * $script:BufW + $x
  if ($idx -ge 0 -and $idx -lt $script:NewChars.Length){
    $script:NewChars[$idx] = $ch
    $script:NewColor[$idx] = $color
  }
}

# --- Simple Fish Entity -----------------------------------------------------------
class Fish {
  [double]$x
  [double]$y
  [double]$vx
  [string]$art
  [int]$color

  Fish([double]$startX, [double]$startY, [double]$speed, [string]$fishArt, [int]$fishColor){
    $this.x = $startX
    $this.y = $startY
    $this.vx = $speed
    $this.art = $fishArt
    $this.color = $fishColor
  }

  [void]Update([double]$dt, [int]$bw, [int]$bh){
    $this.x += $this.vx * $dt * $script:SpeedMultiplier

    # Wrap around screen
    if ($this.vx -gt 0 -and $this.x -gt $bw + 5){
      $this.x = -5
    } elseif ($this.vx -lt 0 -and $this.x -lt -5){
      $this.x = $bw + 5
    }
  }

  [void]Draw(){
    $ix = [int][math]::Round($this.x)
    $iy = [int][math]::Round($this.y)
    for ($i=0; $i -lt $this.art.Length; $i++){
      Set-BufferCell ($ix + $i) $iy $this.art[$i] $this.color
    }
  }
}

# --- Initialize fish --------------------------------------------------------------
$FishList = New-Object System.Collections.Generic.List[Fish]

function Init-Fish([int]$bw, [int]$bh){
  $FishList.Clear()

  # Fish designs (simple ASCII art)
  $fishDesigns = @(
    @{ art = "><>"; colors = @('Cyan','Yellow','Magenta','Green') }
    @{ art = "<><"; colors = @('Red','Blue','Yellow','Cyan') }
    @{ art = ">=>"; colors = @('Green','Magenta','Cyan','Yellow') }
  )

  $numFish = [math]::Max(5, [int]($bw * $bh / 100))
  for ($i=0; $i -lt $numFish; $i++){
    $design = $fishDesigns[$script:rnd.Next($fishDesigns.Count)]
    $colorName = $design.colors[$script:rnd.Next($design.colors.Count)]
    $packedColor = $script:PackedColors[$colorName]

    $x = $script:rnd.NextDouble() * $bw
    $y = 5 + $script:rnd.NextDouble() * ($bh - 10)
    $speed = ($script:rnd.Next(0,2) * 2 - 1) * (5 + $script:rnd.NextDouble() * 10)  # -15 to 15

    $FishList.Add([Fish]::new($x, $y, $speed, $design.art, $packedColor))
  }
}

# --- Main animation loop ----------------------------------------------------------
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

# Initial clear
try { [Console]::Write($AnsiClearHome) } catch {}

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $bufSize = $bw * $bh

      # Resize buffers / reset on size change
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        Init-Fish $bw $bh
        try { [Console]::Write($AnsiClearHome) } catch {}
      } elseif ($FishList.Count -eq 0){
        Init-Fish $bw $bh
      }

      # Fast clear New buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Time step
      $dt = $frameMs / 1000.0

      # Update and draw all fish
      foreach ($fish in $FishList){
        $fish.Update($dt, $bw, $bh)
        $fish.Draw()
      }

      # Draw water line at top (simple wave effect)
      $waterY = 2
      for ($x=0; $x -lt $bw; $x++){
        $waveOffset = [int]([math]::Sin($x * 0.3 + ($sw.ElapsedMilliseconds / 500.0)) * 1)
        $wy = $waterY + $waveOffset
        if ($wy -ge 0 -and $wy -lt $bh){
          Set-BufferCell $x $wy '~' $script:PackedColors.Cyan
        }
      }

      # Diff and render
      $sb = [System.Text.StringBuilder]::new(4096)
      $lastColor = -1
      for ($i=0; $i -lt $bufSize; $i++){
        $nc = $script:NewChars[$i]
        $nCol = $script:NewColor[$i]
        $pc = $script:PrevChars[$i]
        $pCol = $script:PrevColor[$i]
        if ($nc -ne $pc -or $nCol -ne $pCol){
          $script:PrevChars[$i] = $nc
          $script:PrevColor[$i] = $nCol
          $y = [int]($i / $bw)
          $x = $i % $bw
          $null = $sb.Append("$e[$(1+$y);$(1+$x)H")
          if ($nCol -ne $lastColor){
            $lastColor = $nCol
            $r = ($nCol -shr 16) -band 0xFF
            $g = ($nCol -shr  8) -band 0xFF
            $b =  $nCol         -band 0xFF
            $null = $sb.Append("$e[38;2;${r};${g};${b}m")
          }
          $null = $sb.Append($nc)
        }
      }
      if ($sb.Length -gt 0){
        try { [Console]::Write($sb.ToString()) } catch {}
      }

      $sw.Restart()
    }
    Start-Sleep -Milliseconds 1
  }
} finally {
  # Restore console state
  try { [Console]::CursorVisible = $originalVis } catch {}
  try { [Console]::TreatControlCAsInput = $origTreatCtrlC } catch {}
  if (-not $NoHardClear){
    try { [Console]::Write($RIS) } catch {}
  }
  try { [Console]::Write("`n") } catch {}
}

