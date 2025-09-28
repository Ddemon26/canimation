#!/usr/bin/env bash
# Matrix-ish console rain for Linux shell (bash), ported 1:1 from cmatrix.ps1 logic.
# Key behavioral guarantees mirrored from the PS script:
# - No start wipe: overlays on existing text; no background painting.
# - Draw clamps: last ROW is avoided to prevent scroll; last COLUMN is allowed.
# - One stream per column; streams reset when they pass bottom-1.
# - Leader color: green by default, or white with --white-leader.
# - Glyph pool: exact character sets and spacing as in the PS script.
# - Speed is an integer base velocity per stream; intensity grows by a fixed step based on a per-stream IntensityChange.
# - Trail uses the *previous* frame's glyph and intensity at the last position.
# - Resize: re-allocates one stream per current width.
# - Exit: hard terminal reset (ESC c) unless --no-hard-clear.

set -u

# --------------------------- Args --------------------------------------------
FPS=30              # [5..120]
SPEED=1             # [1..5], base integer velocity
LETTERS=0
WHITE_LEADER=0
NO_HARD_CLEAR=0

usage() {
  cat <<'EOF'
Usage: ./cmatrix.sh [--fps N] [--speed N] [--letters] [--white-leader] [--no-hard-clear]

  --fps N          Target frames per second (5..120). Default 30.
  --speed N        Base integer vertical speed (1..5). Default 1.
  --letters        Use letter/digit-heavy glyph set (with spaces), as in PS version.
  --white-leader   Use white leader (default is green).
  --no-hard-clear  Skip hard terminal reset (ESC c) on exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fps) shift; FPS="${1:-}";;
    --speed) shift; SPEED="${1:-}";;
    --letters) LETTERS=1;;
    --white-leader) WHITE_LEADER=1;;
    --no-hard-clear) NO_HARD_CLEAR=1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
  shift || true
done

is_int='^[0-9]+$'
if ! [[ "$FPS" =~ $is_int ]] || (( FPS < 5 || FPS > 120 )); then
  echo "--fps must be integer in [5,120]" >&2; exit 1
fi
if ! [[ "$SPEED" =~ $is_int ]] || (( SPEED < 1 || SPEED > 5 )); then
  echo "--speed must be integer in [1,5]" >&2; exit 1
fi

# --------------------------- ANSI helpers ------------------------------------
ESC=$'\e'
ansi_reset="${ESC}[0m"
ansi_clear_full="${ESC}[3J${ESC}[2J${ESC}[H"   # clear scrollback + screen + home
ansi_scroll_up_max="${ESC}[9999S"
RIS="${ESC}c"                                   # HARD reset

fg_rgb(){ printf "${ESC}[38;2;%d;%d;%dm" "$1" "$2" "$3"; }

# Leader color per PS: green by default, white if requested
leader_fg_green=$(fg_rgb 0 255 0)
leader_fg_white=$(fg_rgb 240 240 240)

# --------------------------- State & helpers ---------------------------------
# Terminal dims (0-based math internally)
cols=0; rows=0

# One stream per column, all integer math for positions as in PS
declare -a cur_pos      # current y position (int)
declare -a last_pos     # last y position (int)
declare -a velocity     # int, = BaseSpeed
declare -a intensity    # 0..255, grows by intensity_step
declare -a last_int     # previous intensity
declare -a intensity_step # floor(255 * IntensityChange), where IntensityChange in [0.01..0.20]
declare -a cur_char     # current glyph (single char)
declare -a last_char    # previous glyph

BaseSpeed=$(( SPEED ))
(( BaseSpeed < 1 )) && BaseSpeed=1

# Exact glyph pools from the PS script (note leading spaces which create gaps)
if (( LETTERS == 1 )); then
  glyph_pool="   ACBDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()<>?{}[]<>~"
else
  glyph_pool="   +=1234567890!@#$%^&*()<>?{}[]<>~"
fi
pool_len=${#glyph_pool}

rand_int(){
  # echo integer in [0, $1) using $RANDOM
  local max=$1
  if (( max <= 1 )); then echo 0; return; fi
  echo $(( RANDOM % max ))
}

rand_between(){
  # echo integer in [a, b] inclusive
  local a=$1 b=$2
  echo $(( a + RANDOM % (b - a + 1) ))
}

get_size(){
  local c r
  c=$(tput cols 2>/dev/null || echo 80)
  r=$(tput lines 2>/dev/null || echo 24)
  (( c < 1 )) && c=1
  (( r < 2 )) && r=2
  cols=$c
  rows=$r
}

# Convert 0-based x,y to ANSI cursor move and print string, with bounds guard:
# allow last column (x <= cols-1), avoid last row (y <= rows-2)
write_glyph(){
  local x=$1 y=$2 s=$3
  local maxX=$(( cols - 1 ))
  local maxY=$(( rows - 2 ))
  if (( maxX < 0 || maxY < 0 )); then return; fi
  if (( x < 0 || y < 0 || x > maxX || y > maxY )); then return; fi
  # ANSI uses 1-based
  local ry=$(( y + 1 ))
  local rx=$(( x + 1 ))
  printf "${ESC}[%d;%dH%s" "$ry" "$rx" "$s"
}

random_glyph(){
  local idx; idx=$(rand_int "$pool_len")
  # bash substring of bytes; pool is ASCII so OK
  printf "%s" "${glyph_pool:idx:1}"
}

# Initialize or reinitialize streams for current width
setup_stream(){
  local x=$1
  # CurrentPosition = Rand(-rows, floor(rows*0.6))
  local max_start=$(printf "%.0f\n" "$(awk -v h="$rows" 'BEGIN{print (h*0.6)}')")
  local start=$(( (RANDOM % (max_start + rows + 1)) - rows ))
  cur_pos[$x]=$start
  last_pos[$x]=$start
  velocity[$x]=$BaseSpeed
  intensity[$x]=0
  last_int[$x]=0
  # IntensityChange = Rand(1..20) / 100.0; step = floor(255 * IntensityChange)
  local pct; pct=$(rand_between 1 20)
  intensity_step[$x]=$(( (255 * pct) / 100 ))
  # Random current & last glyphs from pool
  cur_char[$x]=$(random_glyph)
  last_char[$x]=$(random_glyph)
}

init_streams(){
  get_size
  local x
  for (( x=0; x<cols; x++ )); do
    setup_stream "$x"
  done
}

# --------------------------- Cleanup -----------------------------------------
restore_terminal(){
  # show cursor
  printf "${ESC}[?25h"
  if (( NO_HARD_CLEAR == 1 )); then
    # Soft cleanup: reset, move home, no RIS
    printf "%s" "$ansi_reset"
    printf "${ESC}[H"
  else
    # Hard reset like PS: clear scrollback & screen, scroll viewport, then RIS
    printf "%s" "$ansi_clear_full"
    printf "%s" "$ansi_scroll_up_max"
    printf "%s" "$RIS"
  fi
}

trap 'restore_terminal' EXIT
trap 'exit 0' INT TERM

# --------------------------- Main loop ---------------------------------------
init_streams

frame_ns=$(( 1000000000 / FPS ))
now_ns(){ date +%s%N; }
prev_time=$(now_ns)

# Hide cursor; set noncanonical, non-echo, nonblocking input
printf "${ESC}[?25l"
stty_state=$(stty -g 2>/dev/null || echo "")
stty -echo -icanon time 0 min 0 2>/dev/null || true

# Leader color choice
if (( WHITE_LEADER == 1 )); then
  head_color="$leader_fg_white"
else
  head_color="$leader_fg_green"
fi

while :; do
  now=$(now_ns)
  elapsed=$(( now - prev_time ))
  if (( elapsed >= frame_ns )); then
    prev_time="$now"

    # Handle resize
    old_cols=$cols; old_rows=$rows
    get_size
    if (( cols != old_cols || rows != old_rows )); then
      # Rebuild array to exactly one stream per column
      # If width increased, init new cols; if decreased, truncate logical iteration.
      for (( x=old_cols; x<cols; x++ )); do
        setup_stream "$x"
      done
      # No need to wipe; we overlay only.
    fi

    # Effective draw limits (mimic PS: min(screen, buffer) -1 / -2)
    # In bash, use current cols/rows for both window & buffer.
    limitX=$(( cols - 1 ))
    limitY=$(( rows - 2 ))

    # Draw each column
    for (( x=0; x<=limitX; x++ )); do
      # Move(): update last*, then advance intensity and position, and possibly change current glyph
      lp=${cur_pos[$x]}
      last_pos[$x]=$lp
      last_int[$x]=${intensity[$x]}
      last_char[$x]=${cur_char[$x]}

      # intensity += floor(255 * IntensityChange) -> intensity_step[x]
      new_int=$(( last_int[$x] + intensity_step[$x] ))
      (( new_int > 255 )) && new_int=255
      intensity[$x]=$new_int

      # currentPosition += velocity
      cur_pos[$x]=$(( lp + ${velocity[$x]} ))

      # If current glyph isn't a space, pick a new random glyph this frame
      if [[ "${cur_char[$x]}" != " " ]]; then
        cur_char[$x]=$(random_glyph)
      fi

      # if beyond bottom-1 => Setup() (preserves last_* for trailing draw this frame)
      if (( ${cur_pos[$x]} > rows - 1 )); then
        setup_stream "$x"
      fi

      # Draw leader at current position
      y=${cur_pos[$x]}
      if (( y >= 0 && y <= limitY )); then
        write_glyph "$x" "$y" "${head_color}${cur_char[$x]}${ansi_reset}"
      fi

      # Draw trail at last position with last_int
      lpy=${last_pos[$x]}
      if (( lpy >= 0 && lpy <= limitY )) && [[ "${last_char[$x]}" != " " ]] && (( ${last_int[$x]} > 0 )); then
        # fg 0, last_int, 0
        printf -v trail_color "%s" "$(fg_rgb 0 ${last_int[$x]} 0)"
        write_glyph "$x" "$lpy" "${trail_color}${last_char[$x]}${ansi_reset}"
      fi
    done
  else
    # yield CPU very briefly
    sleep 0.001
  fi

  # Break on any key press
  if IFS= read -r -n1 -t 0 _; then
    break
  fi
done

# Restore terminal io & show cursor (resetting color handled in EXIT trap)
stty "$stty_state" 2>/dev/null || true
printf "${ESC}[?25h"
