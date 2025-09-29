<#
.SYNOPSIS
  Conway's Game of Life cellular automaton that updates only changed cells per frame (no full clears).

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites cells that changed (including erasing with space).
  - Matches the cmatrix-style update loop (no CancelKeyPress handler; any key exits, Ctrl+C treated as input).
  - Classic Conway's Game of Life rules with configurable patterns and colors.

.PARAMETER Fps
  Target frames per second (default: 10).

.PARAMETER Density
  Initial random seed density (0.1-0.9, default: 0.3).

.PARAMETER Pattern
  Initial pattern type: Random, Glider, Pulsar, Gosper, Acorn (default: Random).

.PARAMETER ColorMode
  Cell coloring: Mono, Age, Rainbow, Pulse (default: Mono).

.PARAMETER WrapEdges
  Enable edge wrapping (toroidal topology, default: off).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.EXAMPLE
  .\clife.ps1
  Run with default random pattern.

.EXAMPLE
  .\clife.ps1 -Pattern Gosper -ColorMode Age
  Start with Gosper Glider Gun, age-based coloring.

.EXAMPLE
  .\clife.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(1,60)][int]$Fps = 10,
  [ValidateRange(0.1,0.9)][double]$Density = 0.3,
  [ValidateSet('Random','Glider','Pulsar','Gosper','Acorn')][string]$Pattern = 'Random',
  [ValidateSet('Mono','Age','Rainbow','Pulse')][string]$ColorMode = 'Mono',
  [switch]$WrapEdges,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Conway's Game of Life
=====================

SYNOPSIS
    Classic cellular automaton with differential rendering and multiple patterns.

USAGE
    .\clife.ps1 [OPTIONS]
    .\clife.ps1 -h

DESCRIPTION
    Conway's Game of Life with classic rules: cells live or die based on
    their neighbors. Features famous patterns, multiple color modes, and
    optional edge wrapping for toroidal topology.

GAME RULES
    - A live cell with 2-3 neighbors survives
    - A dead cell with exactly 3 neighbors becomes alive
    - All other cells die or stay dead

OPTIONS
    -Fps <int>          Target frames per second (1-60, default: 10)
    -Density <double>   Random seed density (0.1-0.9, default: 0.3)
                        Only used for Random pattern
    -Pattern <string>   Starting pattern (default: Random)
    -ColorMode <string> Cell coloring scheme (default: Mono)
    -WrapEdges          Enable toroidal topology (wrap around edges)
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

PATTERNS
    Random    Random seed based on Density parameter
    Glider    Small diagonal-moving spaceship
    Pulsar    Period-3 oscillator (symmetric pattern)
    Gosper    Gosper Glider Gun (produces gliders indefinitely)
    Acorn     Methuselah pattern (takes 5206 generations to stabilize)

COLOR MODES
    Mono      Single green color (classic)
    Age       Color based on cell age (older = different color)
    Rainbow   Rainbow colors across the field
    Pulse     Pulsing brightness effect

EXAMPLES
    .\clife.ps1
        Random pattern with default settings

    .\clife.ps1 -Pattern Gosper -WrapEdges
        Gosper Glider Gun on wrapped edges

    .\clife.ps1 -Pattern Pulsar -ColorMode Rainbow
        Pulsar oscillator with rainbow colors

    .\clife.ps1 -Pattern Acorn -ColorMode Age -Fps 20
        Watch Acorn evolve with age-based colors at faster speed

    .\clife.ps1 -Density 0.5 -WrapEdges -ColorMode Pulse
        Dense random start with pulsing on toroidal grid

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Uses differential rendering (only updates changed cells)
    - Edge wrapping creates infinite toroidal space
    - Acorn pattern takes over 5000 generations to stabilize
    - Age mode shows how long cells have been alive

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

# --- Game of Life logic ---------------------------------------------------------
class GameOfLife {
  [bool[,]]$grid
  [bool[,]]$nextGrid
  [int[,]]$ageGrid
  [int]$width
  [int]$height
  [bool]$wrap
  [int]$generation

  GameOfLife([int]$w, [int]$h, [bool]$wrapEdges){
    $this.width = $w
    $this.height = $h
    $this.wrap = $wrapEdges
    $this.grid = New-Object 'bool[,]' ($h, $w)
    $this.nextGrid = New-Object 'bool[,]' ($h, $w)
    $this.ageGrid = New-Object 'int[,]' ($h, $w)
    $this.generation = 0
  }

  [void]SeedRandom([double]$density){
    $rand = [System.Random]::new()
    for ($y = 0; $y -lt $this.height; $y++){
      for ($x = 0; $x -lt $this.width; $x++){
        if ($rand.NextDouble() -lt $density){
          $this.grid[$y,$x] = $true
          $this.ageGrid[$y,$x] = 1
        }
      }
    }
  }

  [void]SeedPattern([string]$patternName){
    $centerX = [int]($this.width / 2)
    $centerY = [int]($this.height / 2)

    switch ($patternName) {
      'Glider' {
        $this.SetCell($centerX+1, $centerY, $true)
        $this.SetCell($centerX+2, $centerY+1, $true)
        $this.SetCell($centerX, $centerY+2, $true)
        $this.SetCell($centerX+1, $centerY+2, $true)
        $this.SetCell($centerX+2, $centerY+2, $true)
      }
      'Pulsar' {
        # Pulsar pattern (period 3 oscillator)
        $coords = @(
          @(-6,-4),@(-6,-3),@(-6,-2),@(-6,2),@(-6,3),@(-6,4),
          @(-4,-6),@(-4,-1),@(-4,1),@(-4,6),
          @(-3,-6),@(-3,-1),@(-3,1),@(-3,6),
          @(-2,-6),@(-2,-1),@(-2,1),@(-2,6),
          @(-1,-4),@(-1,-3),@(-1,-2),@(-1,2),@(-1,3),@(-1,4),
          @(1,-4),@(1,-3),@(1,-2),@(1,2),@(1,3),@(1,4),
          @(2,-6),@(2,-1),@(2,1),@(2,6),
          @(3,-6),@(3,-1),@(3,1),@(3,6),
          @(4,-6),@(4,-1),@(4,1),@(4,6),
          @(6,-4),@(6,-3),@(6,-2),@(6,2),@(6,3),@(6,4)
        )
        foreach ($coord in $coords) {
          $this.SetCell($centerX + $coord[0], $centerY + $coord[1], $true)
        }
      }
      'Gosper' {
        # Gosper Glider Gun (simplified version)
        $coords = @(
          @(1,5),@(1,6),@(2,5),@(2,6),
          @(11,5),@(11,6),@(11,7),@(12,4),@(12,8),@(13,3),@(13,9),@(14,3),@(14,9),
          @(15,6),@(16,4),@(16,8),@(17,5),@(17,6),@(17,7),@(18,6),
          @(21,3),@(21,4),@(21,5),@(22,3),@(22,4),@(22,5),@(23,2),@(23,6),
          @(25,1),@(25,2),@(25,6),@(25,7),
          @(35,3),@(35,4),@(36,3),@(36,4)
        )
        foreach ($coord in $coords) {
          $this.SetCell($centerX + $coord[0] - 20, $centerY + $coord[1] - 5, $true)
        }
      }
      'Acorn' {
        # Acorn pattern (grows for 5206 generations)
        $coords = @(@(0,1),@(1,3),@(2,0),@(2,1),@(2,4),@(2,5),@(2,6))
        foreach ($coord in $coords) {
          $this.SetCell($centerX + $coord[0] - 3, $centerY + $coord[1] - 1, $true)
        }
      }
      default {
        $this.SeedRandom($script:InitialDensity)
      }
    }
  }

  [void]SetCell([int]$x, [int]$y, [bool]$alive){
    if ($x -ge 0 -and $x -lt $this.width -and $y -ge 0 -and $y -lt $this.height){
      $this.grid[$y,$x] = $alive
      if ($alive) { $this.ageGrid[$y,$x] = 1 }
    }
  }

  [int]CountNeighbors([int]$x, [int]$y){
    $count = 0
    for ($dy = -1; $dy -le 1; $dy++){
      for ($dx = -1; $dx -le 1; $dx++){
        if ($dx -eq 0 -and $dy -eq 0) { continue }

        $nx = $x + $dx
        $ny = $y + $dy

        if ($this.wrap) {
          $nx = ($nx + $this.width) % $this.width
          $ny = ($ny + $this.height) % $this.height
        } elseif ($nx -lt 0 -or $nx -ge $this.width -or $ny -lt 0 -or $ny -ge $this.height) {
          continue
        }

        if ($this.grid[$ny,$nx]) { $count++ }
      }
    }
    return $count
  }

  [void]Update(){
    # Clear next generation
    for ($y = 0; $y -lt $this.height; $y++){
      for ($x = 0; $x -lt $this.width; $x++){
        $this.nextGrid[$y,$x] = $false
      }
    }

    # Apply Conway's rules
    for ($y = 0; $y -lt $this.height; $y++){
      for ($x = 0; $x -lt $this.width; $x++){
        $neighbors = $this.CountNeighbors($x, $y)
        $alive = $this.grid[$y,$x]

        if ($alive) {
          # Cell survives with 2 or 3 neighbors
          if ($neighbors -eq 2 -or $neighbors -eq 3) {
            $this.nextGrid[$y,$x] = $true
            $this.ageGrid[$y,$x] = [Math]::Min(255, $this.ageGrid[$y,$x] + 1)
          } else {
            $this.ageGrid[$y,$x] = 0
          }
        } else {
          # Cell is born with exactly 3 neighbors
          if ($neighbors -eq 3) {
            $this.nextGrid[$y,$x] = $true
            $this.ageGrid[$y,$x] = 1
          }
        }
      }
    }

    # Swap grids
    $temp = $this.grid
    $this.grid = $this.nextGrid
    $this.nextGrid = $temp
    $this.generation++
  }

  [bool]IsAlive([int]$x, [int]$y){
    return $this.grid[$y,$x]
  }

  [int]GetAge([int]$x, [int]$y){
    return $this.ageGrid[$y,$x]
  }
}

# --- Color calculation ----------------------------------------------------------
function Get-CellColor([bool]$alive, [int]$age, [int]$generation){
  if (-not $alive) { return 0 }

  switch ($script:ColorMode) {
    'Mono' {
      return PackRGB 0 255 0  # Classic green
    }
    'Age' {
      $intensity = [Math]::Min(255, 100 + $age * 5)
      return PackRGB $intensity $intensity 0  # Yellow gradient
    }
    'Rainbow' {
      $hue = ($age * 10) % 360
      $rgb = HSV-To-RGB $hue 0.8 1.0
      return PackRGB $rgb[0] $rgb[1] $rgb[2]
    }
    'Pulse' {
      $pulse = [Math]::Sin($generation * 0.2 + $age * 0.1) * 0.5 + 0.5
      $intensity = [byte]([Math]::Round(128 + $pulse * 127))
      return PackRGB 0 $intensity 0  # Pulsing green
    }
    default {
      return PackRGB 0 255 0
    }
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
$script:InitialDensity = $Density
$script:ColorMode = $ColorMode
$script:Game = $null

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

try {
  while ($true){
    if (Test-KeyAvailable){ $null = Read-Key; break }

    if ($sw.ElapsedMilliseconds -ge $frameMs){
      $bw=[Console]::BufferWidth; $bh=[Console]::BufferHeight
      if ($bw -le 0){ $bw = 1 }
      if ($bh -le 0){ $bh = 1 }
      $maxX = $bw - 1
      $maxY = $bh - 2   # avoid last row to prevent scroll

      # (Re)alloc buffers on size change
      $bufSize = $bw * $bh
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)

        # Initialize game with new dimensions
        $script:Game = [GameOfLife]::new($bw, $maxY + 1, $WrapEdges.IsPresent)
        $script:Game.SeedPattern($Pattern)

        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Update game state
      $script:Game.Update()

      # Render cells into buffers
      for ($y = 0; $y -le $maxY; $y++){
        for ($x = 0; $x -le $maxX; $x++){
          $alive = $script:Game.IsAlive($x, $y)
          if ($alive) {
            $age = $script:Game.GetAge($x, $y)
            $color = Get-CellColor $alive $age $script:Game.generation
            $idx = $x + $bw * $y
            $script:NewChars[$idx] = '█'
            $script:NewColor[$idx] = $color
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

      # Status line at bottom (generation counter)
      $statusText = "Generation: $($script:Game.generation)"
      $statusY = $bh - 1
      if ($statusY -ge 0) {
        [void]$sb.Append("$e[$($statusY+1);1H")
        [void]$sb.Append((Set-FG 128 128 128))
        [void]$sb.Append($statusText)
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