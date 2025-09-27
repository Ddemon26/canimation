<#
.SYNOPSIS
  Bouncing DVD logo – colored ASCII logo that changes color on each corner hit (diff-write).

.DESCRIPTION
  - Matches cmatrix-style renderer: keeps a persistent screen image and only rewrites changed cells.
  - Colored ASCII "DVD" logo bounces around the screen.
  - Color changes ONLY when the logo hits a **corner** (both X and Y collide on the same frame).
  - Any key exits (Ctrl+C treated as input). No CancelKeyPress handler.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 60).

.PARAMETER Speed
  Movement speed multiplier (default: 1.0).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\cdvd.ps1
  Run with default settings (60 FPS, normal speed).

.EXAMPLE
  .\cdvd.ps1 -Speed 2.0 -Fps 120
  Fast bouncing logo at high framerate.

.EXAMPLE
  .\cdvd.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,240)][int]$Fps = 60,
  [double]$Speed = 1.0,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Bouncing DVD Logo Screensaver
=============================

SYNOPSIS
    Classic bouncing DVD logo with corner-hit color changes and smooth motion.

USAGE
    .\cdvd.ps1 [OPTIONS]
    .\cdvd.ps1 -h

DESCRIPTION
    Nostalgic DVD screensaver recreation featuring a colored ASCII "DVD" logo 
    that bounces around the terminal. The logo changes color only when it hits 
    a corner (both horizontal and vertical walls simultaneously). Uses 
    differential rendering for smooth performance.

OPTIONS
    -Fps <int>        Target frames per second (5-240, default: 60)
    -Speed <double>   Movement speed multiplier (default: 1.0)
    -NoHardClear     Don't clear screen on exit
    -h               Show this help and exit

BEHAVIOR
    - Logo bounces off all four walls with realistic physics
    - Color changes ONLY on corner hits (mythical corner hit!)
    - Nine vibrant colors in rotation: red, orange, yellow, green, cyan, blue, magenta, hot pink, white
    - Smooth floating-point motion with pixel-perfect collision detection
    - Starts from center position on launch or resize

EXAMPLES
    .\cdvd.ps1
        Standard DVD logo at 60 FPS

    .\cdvd.ps1 -Speed 2.0 -Fps 120
        Fast-moving logo at high framerate

    .\cdvd.ps1 -Speed 0.5 -Fps 30
        Slow, relaxing movement

    .\cdvd.ps1 -NoHardClear
        Leave screen unchanged on exit

CONTROLS
    Any key or Ctrl+C to exit

TRIVIA
    - Corner hits are rare due to precise collision physics
    - Logo dimensions: 5 rows × 31 columns
    - Based on the classic DVD player screensaver
    - Each corner hit cycles through the color palette
    - Uses differential rendering (only updates changed pixels)

TECHNICAL NOTES
    - Floating-point position tracking for smooth motion
    - Collision detection with proper velocity reflection  
    - ASCII art logo with full character fidelity
    - High-precision timing for consistent frame rates
    - Memory-efficient differential screen updates

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

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# --- Logo (ASCII only) ----------------------------------------------------------
# 5 rows high, ~31 columns wide
$Logo = @(
  "  ____    __     __   ____  ",
  " |  _ \   \ \   / /  |  _ \ ",
  " | | | |   \ \ / /   | | | |",
  " | |_| |    \ V /    | |_| |",
  " |____/      \_/     |____/ "
)
$LogoH = $Logo.Count
$LogoW = ($Logo | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

function PackRGB([byte]$r,[byte]$g,[byte]$b){ return ([int]$r -shl 16) -bor ([int]$g -shl 8) -bor ([int]$b) }

# Corner-hit color palette
$Palette = @(
  (PackRGB 255 0   0),   # red
  (PackRGB 255 165 0),   # orange
  (PackRGB 255 255 0),   # yellow
  (PackRGB 0   255 0),   # green
  (PackRGB 0   255 255), # cyan
  (PackRGB 0   0   255), # blue
  (PackRGB 255 0   255), # magenta
  (PackRGB 255 105 180), # hot pink
  (PackRGB 255 255 255)  # white
)
$paletteIndex = 0

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)

# Save console state; hide cursor
$originalVis = $true
try { $originalVis = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}

# Ctrl+C as input (avoid CancelKeyPress runspace handler)
$origTreatCtrlC = $false
try { $origTreatCtrlC = [Console]::TreatControlCAsInput } catch {}
try { [Console]::TreatControlCAsInput = $true } catch {}

# Initial clear
try { [Console]::Write($AnsiClearHome) } catch {}

# Motion state (floating point)
$px = 0.0; $py = 0.0
$vx = 20.0 * $Speed  # chars/sec horizontally
$vy = 10.0 * $Speed  # chars/sec vertically

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

      # Ensure buffers / reset on resize
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        # Start near center
        $px = [math]::Max(0, [double]([int]($bw/2 - $LogoW/2)))
        $py = [math]::Max(0, [double]([int]($bh/2 - $LogoH/2)))
        try { [Console]::Write($AnsiClearHome) } catch {}
      }

      # Fast-clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Advance motion
      $dt = $frameMs / 1000.0
      $px += $vx * $dt
      $py += $vy * $dt

      # Bounds and bounce
      $hitX = $false; $hitY = $false
      if ($px -lt 0){ $px = 0; $vx = [math]::Abs($vx); $hitX = $true }
      if ([int]$px + $LogoW - 1 -gt $maxX){ $px = [double]($maxX - $LogoW + 1); $vx = -[math]::Abs($vx); $hitX = $true }
      if ($py -lt 0){ $py = 0; $vy = [math]::Abs($vy); $hitY = $true }
      if ([int]$py + $LogoH - 1 -gt $maxY){ $py = [double]($maxY - $LogoH + 1); $vy = -[math]::Abs($vy); $hitY = $true }

      if ($hitX -and $hitY){
        $paletteIndex = ($paletteIndex + 1) % $Palette.Count
      }

      $packed = $Palette[$paletteIndex]

      # Draw logo into New buffers
      $ix = [int]([math]::Round($px))
      $iy = [int]([math]::Round($py))
      for ($ly=0; $ly -lt $LogoH; $ly++){
        $sy = $iy + $ly
        if ($sy -lt 0 -or $sy -gt $maxY){ continue }
        $row = $Logo[$ly]
        for ($lx=0; $lx -lt $LogoW; $lx++){
          $sx = $ix + $lx
          if ($sx -lt 0 -or $sx -gt $maxX){ continue }
          $ch = $row[$lx]
          if ($ch -ne ' '){
            $idx = $sx + $bw * $sy
            $script:NewChars[$idx] = $ch
            $script:NewColor[$idx] = $packed
          }
        }
      }

      # Diff & draw
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
