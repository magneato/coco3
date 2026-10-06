#!/bin/bash
# ==============================================================================
# run.sh - build CUBE and run it on an emulated CoCo 3 (MAME)
# ==============================================================================
# Boots a CoCo 3 (2 MB; the program needs 512 KB: it uses physical pages $30-$37), forces the
# RGB monitor, mounts build/CUBE.DSK and types LOADM"CUBE":EXEC
# through the keyboard matrix.  The emulator runs flat out until the program starts, then
# at real speed.
#
# Keys (on the CoCo):  SPACE next phase   BREAK back to BASIC
#
# Usage:  ./run.sh [--no-build] [--headless] [--video FILE.mp4] [--demo SECONDS] [extra MAME args...]
#   --video FILE   record the emulated screen and sound one frame at a time (exact whatever the host
#                  speed) and encode FILE with ffmpeg, sound included.  Without --demo the recording
#                  covers the WHOLE show from power-on: the BASIC screen, the typed LOADM, the title
#                  (music starts there) and one lap of the cube, about 80 s.
#   --demo N       record only N seconds, starting when the program does (default file cube.mp4)
#   --headless     no window pacing (as for tests)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
PROG=CUBE

BUILD=1; MODE="window"; VIDEO=""; DEMO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --headless) MODE="headless"; shift ;;
        --video)    VIDEO="$2"; shift 2 ;;
        --demo)     DEMO="$2"; shift 2 ;;
        -h|--help)  sed -n 2,19p "$0"; exit 0 ;;
        *) break ;;
    esac
done
[ "$DEMO" -gt 0 ] 2>/dev/null && [ -z "$VIDEO" ] && VIDEO=cube.mp4
[ "$BUILD" = "1" ] && { ./build.sh || exit 1; }
DISK="${SCRIPT_DIR}/build/${PROG}.DSK"
[ -f "$DISK" ] || { echo "run.sh: build/${PROG}.DSK not found; omit --no-build"; exit 1; }
command -v mame &> /dev/null || { echo "mame not found (sudo apt install mame)"; exit 1; }

ROMPATH="${MAME_ROMPATH:-${HOME}/mame/roms;${HOME}/dev/mame/roms;/usr/local/share/games/mame/roms;/usr/share/games/mame/roms}"
mkdir -p build
LUA="${SCRIPT_DIR}/build/autoboot.lua"      # (a fixed file: a mktemp file + EXIT trap made MAME skip the typing)
cat > "$LUA" <<'LUAEOF'
-- type LOADM"<PROG>":EXEC through the keyboard matrix; force the RGB monitor; fast until the program runs.
-- The program says it is running by counting vsyncs in the word at $0006 (with $000B = 0 and the CPU in
-- $2000-$3FFF), and says its show is over by making $000C nonzero.
local function field(p, f) return manager.machine.ioport.ports[p].fields[f] end
local ROW = { {"@","A","B","C","D","E","F","G"}, {"H","I","J","K","L","M","N","O"}, {"P","Q","R","S","T","U","V","W"}, {"X","Y","Z"} }
local function keydef(ch)
  for r, letters in ipairs(ROW) do for _, l in ipairs(letters) do
    if l == ch:upper() and l:match("%a") then return {":row"..(r-1), l:lower().."  "..l, false} end end end
  if ch == '"' then return {":row4", '2  "', true} end
  if ch == ":" then return {":row5", ":  *", false} end
  if ch == "\n" then return {":row6", "ENTER", false} end
end
local events, f = {}, 80
local cmd = 'LOADM"' .. os.getenv("RUN_PROG") .. '":EXEC\n'
for i = 1, #cmd do
  local d = keydef(cmd:sub(i, i))
  if d then
    if d[3] then events[#events+1] = {f-2, function() field(":row6","SHIFT"):set_value(1) end} end
    events[#events+1] = {f,   function() field(d[1], d[2]):set_value(1) end}
    events[#events+1] = {f+8, function() field(d[1], d[2]):set_value(0); if d[3] then field(":row6","SHIFT"):set_value(0) end end}
    f = f + 18
  end
end
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local frame, nev, throttled = 0, 1, false
local fast = os.getenv("RUN_HEADLESS") ~= "1"
local demo_frames = (tonumber(os.getenv("RUN_DEMO") or "0") or 0) * 60
local rec_raw = os.getenv("RUN_REC")
local rec_on, rec_at, run_at, end_at = false, nil, nil, nil
_G.h = emu.add_machine_frame_notifier(function()       -- global: or the handle is garbage collected
  frame = frame + 1
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nev <= #events and frame >= events[nev][1] do events[nev][2](); nev = nev + 1 end
  local fc = mem:read_u8(6) * 256 + mem:read_u8(7)
  local pc = cpu.state["PC"].value
  local running = frame > 300 and fc > 0 and fc < 30000 and mem:read_u8(0x0B) < 0x80 and pc >= 0x2000 and pc < 0x4000
  if fast and not throttled then
    manager.machine.video.throttled = false
    if running then manager.machine.video.throttled = true; throttled = true end
  end
  if rec_raw and rec_raw ~= "" then
    manager.machine.video.throttled = false                    -- recording is frame-exact: no need to wait
    if demo_frames == 0 then                                   -- the whole show, from power-on
      if not rec_on then manager.machine.video:begin_recording(rec_raw); rec_on = true end
      if running and not run_at then run_at = frame end
      if run_at and frame > run_at + 120 and mem:read_u8(0x0C) ~= 0 and not end_at then end_at = frame + 90 end
      if end_at and frame >= end_at then manager.machine.video:end_recording(); manager.machine:exit() end
    else                                                       -- N seconds from the start of the program
      if running and not rec_at then rec_at = frame; manager.machine.video:begin_recording(rec_raw); rec_on = true end
      if rec_at and frame >= rec_at + demo_frames then manager.machine.video:end_recording(); manager.machine:exit() end
    end
  end
end)
LUAEOF

export RUN_PROG="$PROG" RUN_DEMO="$DEMO"
CRF=18
[ -n "$VIDEO" ] && { rm -f build/rec_raw*.avi; export RUN_REC="${SCRIPT_DIR}/build/rec_raw.avi"; MODE=headless; }
FLAGS=( coco3 -rompath "$ROMPATH" -ramsize 2M -flop1 "$DISK" -autoboot_script "$LUA" -skip_gameinfo )
if [ "$MODE" = "window" ]; then
    mame "${FLAGS[@]}" -video soft -window -nomaximize -resolution 960x720 "$@"
else
    RUN_HEADLESS=1 mame "${FLAGS[@]}" -video soft -window -nomaximize -sound none -nothrottle "$@"
fi
RC=$?

if [ -n "$VIDEO" ]; then
    RAW="$(ls -t build/rec_raw*.avi 2>/dev/null | head -1)"
    [ -f "$RAW" ] || { echo "run.sh: MAME wrote no recording"; exit 1; }
    # MAME stores 2:1 pixels: scale x2 / x4 with nearest neighbour (no blur), 60 fps; the AVI carries
    # MAME's audio mix (48 kHz, even with -sound none), kept as AAC
    ffmpeg -y -loglevel error -i "$RAW" -c:a aac -b:a 128k -ac 1 -vf "scale=iw*2:ih*4:flags=neighbor,setsar=1" \
           -c:v libx264 -profile:v high -level 4.2 -crf $CRF -preset slow -pix_fmt yuv420p -r 60 -movflags +faststart "$VIDEO" \
        && echo "run.sh: wrote $VIDEO ($(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$VIDEO") frames)"
fi
exit $RC
