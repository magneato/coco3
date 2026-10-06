#!/bin/bash
# ==============================================================================
# run.sh - build and play CoCo3 Wolfenstein 3D in MAME
# ==============================================================================
# Boots a CoCo3 with 2 MB RAM (-ramsize 2M is REQUIRED: the column routines and
# data live in physical pages up to $5F), forces the RGB monitor, mounts
# build/WOLF3D.DSK and types   LOADM"WOLF3D":EXEC   through the keyboard matrix
# (the technique from arc3/run.sh: set_value on the matrix ports is robust where
# natural-keyboard posting is not).  It runs unthrottled while the 18 KB loads and
# the boot code builds its tables, then drops to real time as soon as the game's
# frame counter starts to move.
#
# Controls
#   W / UP     forward          S / DOWN    backward
#   A / LEFT   turn left        D / RIGHT   turn right
#   SPACE      open door        T           toggle the terminator autopilot
#   BREAK      back to BASIC
#
# Usage:  ./run.sh [--release] [--no-build] [--headless] [--video FILE.mp4] [--demo SECONDS] [--start level] [--vision] [extra MAME args...]
#   --release      play the Ashen Bastion stand-in bundle (builds it if needed)
#   --demo N        let the terminator autopilot play N seconds (60 emulated frames each), then quit
#   --video FILE    record the emulated screen and sound, ONE FRAME AT A TIME (MAME writes every emulated frame, so the
#                   capture is exact whatever the host speed) and encode FILE with ffmpeg; with --demo the
#                   recording covers exactly the N seconds of play (the disk-load phase is skipped)
#   --vision        keep the red 'terminator vision' palette in the demo (default: ordinary colours, easier on the eyes)
#   --start level   begin the demo at the start of the level (the only start there is: the spawn point)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BUILD=1; MODE="window"; VIDEO=""; DEMO=0; START=level; VISION=0; RELEASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --release)  RELEASE=1; shift ;;
        --no-build) BUILD=0; shift ;;
        --headless) MODE="headless"; shift ;;
        --video)    VIDEO="$2"; shift 2 ;;
        --demo)     DEMO="$2"; shift 2 ;;
        --start)    START="$2"; shift 2 ;;
        --vision)   VISION=1; shift ;;
        -h|--help)  sed -n 2,26p "$0"; exit 0 ;;
        *) break ;;
    esac
done
[ "$START" = "level" ] || { echo "run.sh: --start level is the only start point"; exit 1; }
[ "$DEMO" -gt 0 ] 2>/dev/null && [ -z "$VIDEO" ] && VIDEO=demo.mp4
[ "$BUILD" = "1" ] && {
    if [ "$RELEASE" = "1" ]; then
        ./release.sh || exit 1
    else
        ./build.sh || exit 1
    fi
}
DISK="${SCRIPT_DIR}/build/WOLF3D.DSK"
SYMBOLS="${SCRIPT_DIR}/build/wolf3d.sym"
if [ "$RELEASE" = "1" ]; then
    DISK="${SCRIPT_DIR}/release/WOLF3D.DSK"
    SYMBOLS="${SCRIPT_DIR}/release/WOLF3D.SYM"
    [ -f "$DISK" ] || { echo "run.sh: release disk not found; run ./release.sh or omit --no-build"; exit 1; }
fi
command -v mame &> /dev/null || { echo "mame not found (sudo apt install mame)"; exit 1; }

ROMPATH="${MAME_ROMPATH:-${HOME}/mame/roms;${HOME}/dev/mame/roms;/usr/local/share/games/mame/roms;/usr/share/games/mame/roms}"
mkdir -p build
LUA="${SCRIPT_DIR}/build/autoboot.lua"      # (a mktemp file + EXIT trap made MAME skip the typed command)
cat > "$LUA" <<'LUAEOF'
-- type LOADM"WOLF3D":EXEC via the keyboard matrix; force the RGB monitor; speed through the load
local function field(p, f) return manager.machine.ioport.ports[p].fields[f] end
local ROW = { {"@","A","B","C","D","E","F","G"}, {"H","I","J","K","L","M","N","O"}, {"P","Q","R","S","T","U","V","W"}, {"X","Y","Z"} }
local DIG = { ["3"]="3  #  ~", ["2"]="2  \"" }
local function keydef(ch)
  for r, letters in ipairs(ROW) do for _, l in ipairs(letters) do
    if l == ch:upper() and l:match("%a") then return {":row"..(r-1), l:lower().."  "..l, false} end end end
  if DIG[ch] then return {":row4", DIG[ch], false} end
  if ch == '"' then return {":row4", '2  "', true} end
  if ch == ":" then return {":row5", ":  *", false} end
  if ch == "\n" then return {":row6", "ENTER", false} end
end
local events, f = {}, 80
local cmd = 'LOADM"WOLF3D":EXEC\n'
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
local fast = os.getenv("WOLF_HEADLESS") ~= "1"
local shot_at = tonumber(os.getenv("WOLF_SHOT") or "0")     -- test hook: snapshot + quit at this frame
local demo_frames = (tonumber(os.getenv("WOLF_DEMO") or "0") or 0) * 60
local rec_raw = os.getenv("WOLF_REC")                         -- raw AVI path when recording
local rec_at, rec_on = nil, false
_G.h = emu.add_machine_frame_notifier(function()       -- global: or the handle is garbage collected
  frame = frame + 1
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nev <= #events and frame >= events[nev][1] do events[nev][2](); nev = nev + 1 end
  if fast and not throttled then
    manager.machine.video.throttled = false
    -- game started once the frame counter ($06) is small and counting
    local fc = mem:read_u8(6) * 256 + mem:read_u8(7)
    if frame > 300 and fc > 0 and fc < 30000 and mem:read_u8(0x0B) < 0x80 and cpu.state["PC"].value >= 0x2000 and cpu.state["PC"].value < 0x4000 then
      manager.machine.video.throttled = true; throttled = true
    end
  end
  if rec_raw and rec_raw ~= "" then
    manager.machine.video.throttled = false                    -- recording is frame-exact: no need to wait for the wall clock
    local fc = mem:read_u8(6) * 256 + mem:read_u8(7)
    local running = frame > 300 and fc > 0 and fc < 30000 and cpu.state["PC"].value >= 0x2000 and cpu.state["PC"].value < 0x4000
    if demo_frames == 0 and not rec_on then manager.machine.video:begin_recording(rec_raw); rec_on = true end
    if demo_frames > 0 and running and not rec_at then
      rec_at = frame + 30                                      -- half a second of the first view, then the autopilot takes over
      manager.machine.video:begin_recording(rec_raw); rec_on = true
    end
    if rec_at and frame == rec_at - 2 and os.getenv("WOLF_EYES_ADDR") then mem:write_u8(tonumber(os.getenv("WOLF_EYES_ADDR")), 1) end
    if rec_at and frame == rec_at then field(":row2", "t  T"):set_value(1) end
    if rec_at and frame == rec_at + 8 then field(":row2", "t  T"):set_value(0) end
    if rec_at and frame >= rec_at - 30 + demo_frames then manager.machine.video:end_recording(); manager.machine:exit() end
  end
  if shot_at > 0 and frame % 100 == 0 then
    print(string.format("T frame=%d PC=%04X fcount=%d throttled=%s", frame, cpu.state["PC"].value, mem:read_u8(6)*256+mem:read_u8(7), tostring(throttled)))
  end
  if shot_at > 0 and frame == shot_at then manager.machine.video:snapshot() end
  if shot_at > 0 and frame == shot_at + 3 then manager.machine:exit() end
end)
LUAEOF

export WOLF_DEMO="$DEMO"
EYES=""
if [ -f "$SYMBOLS" ]; then
    EYES="$(grep -i '^eyes_plain EQU' "$SYMBOLS" | sed 's/.*\$//' || true)"
fi
[ "$VISION" = 0 ] && [ -n "$EYES" ] && export WOLF_EYES_ADDR="$((16#$EYES))"
[ -n "$VIDEO" ] && { rm -f build/demo_raw*.avi; export WOLF_REC="${SCRIPT_DIR}/build/demo_raw.avi"; }
CRF=12
FLAGS=( coco3 -rompath "$ROMPATH" -ramsize 2M -flop1 "$DISK" -autoboot_script "$LUA" -skip_gameinfo )
if [ -n "$VIDEO" ]; then MODE=headless; fi       # a recording run is unattended: no window pacing needed
if [ "$MODE" = "window" ]; then
    mame "${FLAGS[@]}" -video soft -window -nomaximize -resolution 960x720 "$@"
else
    WOLF_HEADLESS=1 mame "${FLAGS[@]}" -video soft -window -nomaximize -sound none -nothrottle "$@"
fi
RC=$?

if [ -n "$VIDEO" ]; then
    RAW="$(ls -t build/demo_raw*.avi 2>/dev/null | head -1)"
    [ -f "$RAW" ] || { echo "run.sh: MAME wrote no recording"; exit 1; }
    # MAME's frames are 4:3 on screen but stored with 2:1 pixels: scale x2 / x4 with nearest neighbour (no blur), 60 fps
    # the raw AVI also carries MAME's audio mix (48 kHz, even with -sound none): kept as AAC
    ffmpeg -y -loglevel error -i "$RAW" -c:a aac -b:a 128k -ac 1 -vf "scale=iw*2:ih*4:flags=neighbor,setsar=1" \
           -c:v libx264 -profile:v high -level 4.2 -crf $CRF -preset slow -pix_fmt yuv420p -r 60 -movflags +faststart "$VIDEO" \
        && echo "run.sh: wrote $VIDEO ($(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$VIDEO") frames)"
fi
exit $RC
