<#
.SYNOPSIS
  Rotating wireframe shapes (Pyramid, Octahedron, Dodecahedron) — diff-write, cmatrix-style.

.DESCRIPTION
  - Keeps a persistent screen image and only rewrites cells that changed (including erasing with space).
  - Shapes selectable with -Shape.
  - No CancelKeyPress handler (Ctrl+C treated as input). Any key exits cleanly.
  - Optional rainbow edge colors; default Matrix-green.
  - cmatrix-style shutdown: hard clear + RIS unless -NoHardClear.

.PARAMETER Fps
  Target frames per second (default: 30).

.PARAMETER Size
  Visual scale (default: 18).

.PARAMETER Speed
  Rotation speed multiplier (default: 1.0).

.PARAMETER Shape
  'Pyramid' | 'Octahedron' | 'Dodecahedron'. Default: Octahedron.

.PARAMETER Rainbow
  Rainbow edge colors (default: off).

.PARAMETER NoHardClear
  Skip the final hard clear (RIS) on exit; leave the screen as-is.

.EXAMPLE
  .\cwire.ps1
  Run with default octahedron.

.EXAMPLE
  .\cwire.ps1 -Shape Dodecahedron -Rainbow
  Complex dodecahedron with rainbow colors.

.EXAMPLE
  .\cwire.ps1 -h
  Display help message.
#>

[CmdletBinding()]
param(
  [ValidateRange(5,120)][int]$Fps = 30,
  [ValidateRange(8,120)][int]$Size = 18,
  [double]$Speed = 1.0,
  [ValidateSet('Pyramid','Octahedron','Dodecahedron')][string]$Shape = 'Octahedron',
  [switch]$Rainbow,
  [switch]$NoHardClear,
  [Alias("h")][switch]$Help
)

# Handle help request
if ($Help) {
    $helpText = @"

Rotating Wireframe Shapes
==========================

SYNOPSIS
    3D rotating wireframe polyhedra with ASCII line drawing.

USAGE
    .\cwire.ps1 [OPTIONS]
    .\cwire.ps1 -h

DESCRIPTION
    Renders rotating 3D wireframe polyhedra using ASCII characters for edges.
    Choose from three geometric shapes with varying complexity. Optional
    rainbow coloring for edges, or classic Matrix green. Features proper
    3D rotation and perspective projection.

OPTIONS
    -Fps <int>          Target frames per second (5-120, default: 30)
    -Size <int>         Visual scale (8-120, default: 18)
    -Speed <double>     Rotation speed multiplier (default: 1.0)
    -Shape <string>     Polyhedron type (default: Octahedron)
    -Rainbow            Use rainbow edge colors
    -NoHardClear        Don't clear screen on exit
    -h                  Show this help and exit

SHAPES
    Pyramid
        4 vertices, 6 edges (tetrahedron)
        Simplest shape, clean appearance

    Octahedron
        6 vertices, 12 edges
        Double pyramid, balanced complexity
        Default shape

    Dodecahedron
        20 vertices, 30 edges
        Complex 12-sided polyhedron
        Most intricate and visually impressive

EXAMPLES
    .\cwire.ps1
        Default octahedron in green

    .\cwire.ps1 -Shape Pyramid
        Simple pyramid wireframe

    .\cwire.ps1 -Shape Dodecahedron -Rainbow
        Complex dodecahedron with rainbow colors

    .\cwire.ps1 -Size 30 -Speed 0.5
        Large, slow-rotating octahedron

    .\cwire.ps1 -Shape Pyramid -Rainbow -Fps 60
        Fast rainbow pyramid at high framerate

    .\cwire.ps1 -Shape Dodecahedron -Size 25 -Speed 1.5
        Large, fast dodecahedron

CONTROLS
    Any key or Ctrl+C to exit

NOTES
    - Uses proper 3D rotation matrices and perspective projection
    - Edges drawn with ASCII line characters (|, -, /, \)
    - Rainbow mode gives each edge a unique color
    - Larger Size values need wider terminals
    - Dodecahedron is the most complex with 30 edges
    - Speed can be fractional for slower rotation
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

# --- Color helpers --------------------------------------------------------------
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

# Plot & line drawing
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

# --- Shape definitions ----------------------------------------------------------
function Get-Shape {
  param([string]$name)
  switch ($name) {
    'Pyramid' {
      $v = @(
        [Vec3]::new(-1,-1,-1),
        [Vec3]::new( 1,-1,-1),
        [Vec3]::new( 1,-1, 1),
        [Vec3]::new(-1,-1, 1),
        [Vec3]::new( 0, 1, 0)  # apex
      )
      $e = @( 0,1, 1,2, 2,3, 3,0, 0,4, 1,4, 2,4, 3,4 )
      return ,@($v,$e)
    }
    'Octahedron' {
      $v = @(
        [Vec3]::new( 1, 0, 0),
        [Vec3]::new(-1, 0, 0),
        [Vec3]::new( 0, 1, 0),
        [Vec3]::new( 0,-1, 0),
        [Vec3]::new( 0, 0, 1),
        [Vec3]::new( 0, 0,-1)
      )
      $e = @( 0,2, 0,3, 0,4, 0,5, 1,2, 1,3, 1,4, 1,5, 2,4, 2,5, 3,4, 3,5 )
      return ,@($v,$e)
    }
    'Dodecahedron' {
      # Build vertices using golden ratio
      $phi = (1.0 + [math]::Sqrt(5.0)) / 2.0
      $inv = 1.0 / $phi
      $verts = New-Object System.Collections.Generic.List[object]

      # 8 vertices of a cube
      foreach ($sx in @(-1,1)){
        foreach ($sy in @(-1,1)){
          foreach ($sz in @(-1,1)){
            $verts.Add([Vec3]::new($sx, $sy, $sz)) | Out-Null
          }
        }
      }
      # 12 vertices from permutations
      $pairs = @(
        @(0,  $inv,  $phi),
        @($inv,  $phi, 0),
        @($phi,  0,  $inv)
      )
      foreach($p in $pairs){
        $a,$b,$c = $p[0],$p[1],$p[2]
        foreach($sb in @(-1,1)){
          foreach($sc in @(-1,1)){
            $verts.Add([Vec3]::new( 0, $sb*$b, $sc*$c)) | Out-Null
            $verts.Add([Vec3]::new($sb*$b, $sc*$c, 0)) | Out-Null
            $verts.Add([Vec3]::new($sb*$c, 0, $sc*$b)) | Out-Null
          }
        }
      }
      # Pack into array
      $v = @()
      foreach($pt in $verts){ $v += ,$pt }

      # Derive edges by connecting nearest neighbor distances (shortest non-zero)
      $n = $v.Count
      $dmin = [double]::PositiveInfinity
      for ($i=0; $i -lt $n; $i++){
        for ($j=$i+1; $j -lt $n; $j++){
          $dx = $v[$i].x - $v[$j].x
          $dy = $v[$i].y - $v[$j].y
          $dz = $v[$i].z - $v[$j].z
          $d = [math]::Sqrt($dx*$dx + $dy*$dy + $dz*$dz)
          if ($d -gt 1e-6 -and $d -lt $dmin){ $dmin = $d }
        }
      }
      $tol = $dmin * 1.05  # 5% tolerance
      $elist = New-Object System.Collections.Generic.List[int]
      for ($i=0; $i -lt $n; $i++){
        for ($j=$i+1; $j -lt $n; $j++){
          $dx = $v[$i].x - $v[$j].x
          $dy = $v[$i].y - $v[$j].y
          $dz = $v[$i].z - $v[$j].z
          $d = [math]::Sqrt($dx*$dx + $dy*$dy + $dz*$dz)
          if ($d -le $tol){
            $elist.Add($i) | Out-Null
            $elist.Add($j) | Out-Null
          }
        }
      }
      # Convert to flat int array
      $e = @()
      foreach($idx in $elist){ $e += ,$idx }
      return ,@($v,$e)
    }
  }
}

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
      $camDist = 4.0

      # Buffers (re)alloc
      $bufSize = $bw * $bh
      if ($script:PrevChars -eq $null -or $bw -ne $script:BufW -or $bh -ne $script:BufH){
        $script:BufW = $bw; $script:BufH = $bh
        $script:PrevChars = New-Object 'char[]' ($bufSize)
        $script:PrevColor = New-Object 'int[]'  ($bufSize)
        $script:NewChars  = New-Object 'char[]' ($bufSize)
        $script:NewColor  = New-Object 'int[]'  ($bufSize)
        try { [Console]::Write($AnsiClearHome) } catch {}
      }
      [System.Array]::Clear($script:NewChars, 0, $script:NewChars.Length)
      [System.Array]::Clear($script:NewColor, 0, $script:NewColor.Length)

      # Rotation
      $dt = $frameMs / 1000.0
      $angle += ($Speed * 1.0 * $dt)
      $ax = $angle * 0.6
      $ay = $angle * 1.0
      $az = $angle * 0.4

      # Build shape data (once per frame in case we add dynamic shapes later)
      $shapeData = Get-Shape $Shape
      $verts = $shapeData[0]
      $edges = $shapeData[1]

      # Rotate & project all vertices
      $nverts = $verts.Count
      $proj = New-Object 'object[]' $nverts
      for ($i=0; $i -lt $nverts; $i++){
        $vr = Rotate-XYZ $verts[$i] $ax $ay $az
        $xy = Project $vr $scale $camDist $cx $cy $aspect
        $proj[$i] = $xy
      }

      # Draw all edges
      for ($eidx=0; $eidx -lt $edges.Count; $eidx+=2){
        $a = $edges[$eidx]; $b = $edges[$eidx+1]
        $x0 = $proj[$a][0]; $y0 = $proj[$a][1]
        $x1 = $proj[$b][0]; $y1 = $proj[$b][1]

        if ($Rainbow){
          $h = (($eidx * 18) + ($angle * 180 / [math]::PI * 2)) % 360
          $rgb = HSV-To-RGB $h 1.0 1.0
          $packed = PackRGB $rgb[0] $rgb[1] $rgb[2]
        } else {
          $packed = PackRGB 0 255 0
        }
        Draw-Line $x0 $y0 $x1 $y1 '#' $packed $bw $bh
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
