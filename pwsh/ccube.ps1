<#
.SYNOPSIS
  Rotating 3D wireframe cube (diff-write, cmatrix-style).

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites changed cells per frame (including erasing with space).
  - No CancelKeyPress handler; Ctrl+C is treated as input; any key exits cleanly.
  - Optional rainbow edges; default Matrix-green.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Size
  Cube scale in characters (default: 18).

.PARAMETER Speed
  Base rotation speed multiplier (default: 1.0).

.PARAMETER Rainbow
  Rainbow edge colors instead of green (default: off).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.PARAMETER Help
  Display this help message and exit.

.EXAMPLE
  .\ccube.ps1
  Run with default settings (green wireframe cube).

.EXAMPLE
  .\ccube.ps1 -Rainbow -Size 24 -Speed 1.5
  Larger rainbow cube rotating faster.

.EXAMPLE
  .\ccube.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(8,120)][int]$Size = 18,
  [double]$Speed = 1.0,
  [switch]$Rainbow,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Rotating 3D Wireframe Cube
==========================

SYNOPSIS
    ASCII 3D wireframe cube with differential rendering and rotation.

USAGE
    .\ccube.ps1 [OPTIONS]
    .\ccube.ps1 -h

DESCRIPTION
    A smooth rotating wireframe cube rendered in ASCII with differential 
    frame updates for performance. Features configurable colors, size, 
    and rotation speed with matrix-style visual effects.

OPTIONS
    -Fps <int>         Target frames per second (5-120, default: 30)
    -Size <int>        Cube scale in characters (8-120, default: 18)
    -Speed <double>    Rotation speed multiplier (default: 1.0)
    -Rainbow          Use rainbow edge colors instead of green
    -NoHardClear      Don't clear screen on exit
    -h                Show this help and exit

EXAMPLES
    .\ccube.ps1
        Standard green wireframe cube

    .\ccube.ps1 -Rainbow -Size 24 -Speed 1.5
        Large rainbow cube with faster rotation

    .\ccube.ps1 -Fps 60 -Speed 0.5
        High framerate with slow, smooth rotation

    .\ccube.ps1 -Size 12 -NoHardClear
        Small cube, leave screen unchanged on exit

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Uses differential rendering (only updates changed pixels)
    - Cube rotates around multiple axes simultaneously  
    - Rainbow mode cycles colors based on edge and time
    - Resize terminal window to change projection area
    - Performance optimized with character-level diff updates

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

# --- Rainbow helper -------------------------------------------------------------
function HSV-To-RGB([double]$h, [double]$s, [double]$v){
  if ($s -le 0){ $r = $v; $g = $v; $b = $v }
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

# --- Math & geometry ------------------------------------------------------------
class Vec3 {
  [double]$x; [double]$y; [double]$z
  Vec3([double]$x,[double]$y,[double]$z){ $this.x=$x; $this.y=$y; $this.z=$z }
}
function Rotate-XYZ([Vec3]$v, [double]$ax, [double]$ay, [double]$az){
  $cx=[math]::Cos($ax); $sx=[math]::Sin($ax)
  $cy=[math]::Cos($ay); $sy=[math]::Sin($ay)
  $cz=[math]::Cos($az); $sz=[math]::Sin($az)
  # X
  $y1 = $v.y*$cx - $v.z*$sx
  $z1 = $v.y*$sx + $v.z*$cx
  $x1 = $v.x
  # Y
  $x2 = $x1*$cy + $z1*$sy
  $z2 = -$x1*$sy + $z1*$cy
  $y2 = $y1
  # Z
  $x3 = $x2*$cz - $y2*$sz
  $y3 = $x2*$sz + $y2*$cz
  return [Vec3]::new($x3,$y3,$z2)
}
function Project([Vec3]$v, [double]$scale, [double]$dist, [int]$cx, [int]$cy, [double]$aspect){
  $z = $v.z + $dist
  if ($z -le 0.001){ $z = 0.001 }
  $px = ($v.x / $z) * $scale * $aspect
  $py = ($v.y / $z) * $scale
  return @([int]([math]::Round($cx + $px)), [int]([math]::Round($cy - $py)))
}

# --- Buffers --------------------------------------------------------------------
$script:BufW = 0
$script:BufH = 0
$script:PrevChars = $null  # char[]
$script:PrevColor = $null  # int[] packed RGB
$script:NewChars  = $null  # char[]
$script:NewColor  = $null  # int[] packed RGB

# --- Cube data ------------------------------------------------------------------
$verts = @(
  [Vec3]::new(-1,-1,-1),
  [Vec3]::new( 1,-1,-1),
  [Vec3]::new( 1, 1,-1),
  [Vec3]::new(-1, 1,-1),
  [Vec3]::new(-1,-1, 1),
  [Vec3]::new( 1,-1, 1),
  [Vec3]::new( 1, 1, 1),
  [Vec3]::new(-1, 1, 1)
)
$edges = @(0,1, 1,2, 2,3, 3,0, 4,5, 5,6, 6,7, 7,4, 0,4, 1,5, 2,6, 3,7)

# --- Setup ----------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameMs = [int](1000 / $Fps)
$angle = 0.0

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

# Plot into buffers
function Plot([int]$x,[int]$y,[char]$ch,[int]$packed,[int]$bw,[int]$bh){
  $maxX=$bw-1; $maxY=$bh-2
  if ($x -lt 0 -or $y -lt 0 -or $x -gt $maxX -or $y -gt $maxY){ return }
  $script:NewChars[$x + $bw*$y] = $ch
  $script:NewColor[$x + $bw*$y] = $packed
}
function Draw-Line([int]$x0,[int]$y0,[int]$x1,[int]$y1,[char]$ch,[int]$packed,[int]$bw,[int]$bh){
  $dx = [math]::Abs($x1 - $x0)
  $dy = -[math]::Abs($y1 - $y0)
  $sx = ($(if ($x0 -lt $x1) { 1 } else { -1 }))
  $sy = ($(if ($y0 -lt $y1) { 1 } else { -1 }))
  $err = $dx + $dy
  $x = $x0; $y = $y0
  while ($true) {
    Plot $x $y $ch $packed $bw $bh
    if ($x -eq $x1 -and $y -eq $y1){ break }
    $e2 = 2*$err
    if ($e2 -ge $dy){ $err += $dy; $x += $sx }
    if ($e2 -le $dx){ $err += $dx; $y += $sy }
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
      $maxY = $bh - 2
      $cx = [int]([math]::Floor($bw/2))
      $cy = [int]([math]::Floor($bh/2))
      $aspect = if ($bh -gt 0){ [double]$bw / [double]$bh } else { 1.0 }
      $scale = $Size
      $camDist = 3.0

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

      # Fast clear new buffers
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Rotation based on time
      $dt = $frameMs / 1000.0
      $angle += ($Speed * 1.2 * $dt)
      $ax = $angle * 0.6
      $ay = $angle * 1.0
      $az = $angle * 0.4

      # Rotate & project vertices
      $proj = New-Object 'object[]' 8
      for ($i=0; $i -lt 8; $i++){
        $vr = Rotate-XYZ $verts[$i] $ax $ay $az
        $xy = Project $vr $scale $camDist $cx $cy $aspect
        $proj[$i] = $xy
      }

      # Draw edges into buffers
      for ($eidx=0; $eidx -lt $edges.Count; $eidx+=2){
        $a = $edges[$eidx]; $b = $edges[$eidx+1]
        $x0 = $proj[$a][0]; $y0 = $proj[$a][1]
        $x1 = $proj[$b][0]; $y1 = $proj[$b][1]

        if ($Rainbow){
          $h = (($eidx * 30) + ($angle * 180 / [math]::PI * 2)) % 360
          $rgb = HSV-To-RGB $h 1.0 1.0
          $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
        } else {
          $packed = PackRGB 0 255 0
        }
        Draw-Line $x0 $y0 $x1 $y1 '█' $packed $bw $bh
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
