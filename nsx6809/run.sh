#!/bin/bash
# ==============================================================================
# run.sh - NSX6809 on an emulated CoCo 3 (MAME, 512 KB: the memory of a 1986 upgraded CoCo 3)
# ==============================================================================
#   ./run.sh --train     train: boots MNSTTRN.DSK, types LOADM"MNSTTRN":EXEC, runs the emulator flat
#                        out (35 minutes of CoCo time, about 1.5 minutes here), then takes the trained
#                        MODEL.NSX off the disk into build/MODEL.NSX and onto MNSTINFR.DSK
#   ./run.sh             infer: boots MNSTINFR.DSK, types LOADM"MNSTINFR":EXEC, real speed, your turn
#
# Options:  --no-build   use the disks as they are       --headless   no window pacing (tests)
#           --watch      (with --train) at real speed in a window: 35 minutes, as on a real CoCo 3
#
# On the CoCo:  W A S D / joystick  move   SPACE / fire  ink   X  rub   CLEAR  wipe   ENTER  guess
#               LEFT / RIGHT  the 16 characters   0-9  an MNIST example   BREAK  back to BASIC
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
TRAIN=0; BUILD=1; MODE=window; WATCH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --train)    TRAIN=1; shift ;;
        --no-build) BUILD=0; shift ;;
        --headless) MODE=headless; shift ;;
        --watch)    WATCH=1; shift ;;
        -h|--help)  sed -n 2,16p "$0"; exit 0 ;;
        *) break ;;
    esac
done
[ "$BUILD" = 1 ] && { ./build.sh || exit 1; }
command -v mame &> /dev/null || { echo "mame not found (sudo apt install mame)"; exit 1; }
ROMPATH="${MAME_ROMPATH:-${HOME}/mame/roms;${HOME}/dev/mame/roms;/usr/local/share/games/mame/roms;/usr/share/games/mame/roms}"

if [ "$TRAIN" = 1 ]; then PROG=MNSTTRN; else PROG=MNSTINFR; fi
DISK="build/${PROG}.DSK"
[ -f "$DISK" ] || { echo "run.sh: $DISK not found; omit --no-build"; exit 1; }
LUA="build/autoboot.lua"
cat > "$LUA" <<'LUAEOF'
-- type LOADM"<PROG>":EXEC through the keyboard matrix; force the RGB monitor; fast while loading.
-- The programs say they are running with $0006/$0007 (1 = loaded and going) and finished with $000C.
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
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local fastall = os.getenv("RUN_FASTALL") == "1"     -- training: flat out to the end, then quit
local frame, nev, started, done_at, slowed = 0, 1, false, nil, false
_G.h = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nev <= #events and frame >= events[nev][1] do events[nev][2](); nev = nev + 1 end
  local tk = mem:read_u8(6) * 256 + mem:read_u8(7)
  if frame > 300 and tk >= 1 and tk < 30000 and mem:read_u8(0x0B) == 0 then started = true end
  if fastall then
    manager.machine.video.throttled = false
    if started and mem:read_u8(0x0C) ~= 0 and not done_at then done_at = frame end
    if done_at and frame >= done_at + 180 then manager.machine:exit() end
  elseif not slowed then
    manager.machine.video.throttled = false            -- inference: fast through the disk load,
    if started and tk >= 2 then manager.machine.video.throttled = true; slowed = true end   -- then real time
  end
end)
LUAEOF
export RUN_PROG="$PROG"
[ "$TRAIN" = 1 ] && [ "$WATCH" = 0 ] && export RUN_FASTALL=1
FLAGS=( coco3 -rompath "$ROMPATH" -ramsize 512K -flop1 "$SCRIPT_DIR/$DISK" -autoboot_script "$SCRIPT_DIR/$LUA" -skip_gameinfo )
if [ "$MODE" = window ]; then
    mame "${FLAGS[@]}" -video soft -window -nomaximize -resolution 960x720 "$@"
else
    mame "${FLAGS[@]}" -video soft -window -nomaximize -sound none -nothrottle "$@"
fi
RC=$?
if [ "$TRAIN" = 1 ]; then
    # the output of training: MODEL.NSX off the training disk, onto the inference disk
    python3 tools/dsk.py get "$DISK" MODEL.NSX build/MODEL.NSX && python3 tools/nsxdata.py show build/MODEL.NSX
    python3 tools/dsk.py put build/MNSTINFR.DSK MODEL.NSX build/MODEL.NSX && echo "run.sh: MNSTINFR.DSK now holds this model - ./run.sh --no-build"
fi
exit $RC
