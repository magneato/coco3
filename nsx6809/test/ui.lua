-- test/ui.lua - boot MNSTINFR, then play a script of key presses (frames counted from the moment the UI
-- loop runs: its vsync counter at $0006 passes 10), take snapshots and dump RAM.
--   UI_SCRIPT="10-14:7,40-44:ENTER,..."   hold KEY over a frame range (W A S D X SPACE ENTER CLEAR LEFT RIGHT
--                                          UP DOWN BREAK 0-9, or JX=n / JY=n to set the right joystick 0-1023)
--   UI_SNAP="30 60"   snapshots       UI_DUMP="60:build/d1.bin"   W0 ($0000-$1FFF) to a file      UI_EXIT=200
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local function port(p, f) return manager.machine.ioport.ports[p].fields[f] end
local ROW = { {"@","A","B","C","D","E","F","G"}, {"H","I","J","K","L","M","N","O"}, {"P","Q","R","S","T","U","V","W"}, {"X","Y","Z"} }
local function keydef(ch)
  for r, letters in ipairs(ROW) do for _, l in ipairs(letters) do
    if l == ch:upper() and l:match("%a") then return {":row"..(r-1), l:lower().."  "..l, false} end end end
  if ch == '"' then return {":row4", '2  "', true} end
  if ch == ":" then return {":row5", ":  *", false} end
  if ch == "\n" then return {":row6", "ENTER", false} end
end
local boot, f = {}, 80
local cmd = 'LOADM"MNSTINFR":EXEC\n'
for i = 1, #cmd do
  local d = keydef(cmd:sub(i, i))
  if d then
    if d[3] then boot[#boot+1] = {f-2, function() port(":row6","SHIFT"):set_value(1) end} end
    boot[#boot+1] = {f,   function() port(d[1], d[2]):set_value(1) end}
    boot[#boot+1] = {f+8, function() port(d[1], d[2]):set_value(0); if d[3] then port(":row6","SHIFT"):set_value(0) end end}
    f = f + 18
  end
end
local K = { W={":row2","w  W"}, A={":row0","a  A"}, S={":row2","s  S"}, D={":row0","d  D"}, X={":row3","x  X"},
  SPACE={":row3","SPACE"}, ENTER={":row6","ENTER"}, CLEAR={":row6","CLEAR"}, LEFT={":row3","LEFT"}, RIGHT={":row3","RIGHT"},
  UP={":row3","UP"}, DOWN={":row3","DOWN"}, BREAK={":row6","BREAK"}, FIRE={":joystick_buttons","Right Button 1"},
  ["0"]={":row4","0"}, ["1"]={":row4","1  !  |"}, ["2"]={":row4",'2  "'}, ["3"]={":row4","3  #  ~"}, ["4"]={":row4","4  $"},
  ["5"]={":row4","5  %"}, ["6"]={":row4","6  &"}, ["7"]={":row4","7  '  ^"}, ["8"]={":row5","8  (  ["}, ["9"]={":row5","9  )  ]"} }
local seq = {}
for a, b, k in string.gmatch(os.getenv("UI_SCRIPT") or "", "(%d+)%-(%d+):([%w=]+)") do seq[#seq+1] = {tonumber(a), tonumber(b), k} end
local snaps, dumps = {}, {}
for s in string.gmatch(os.getenv("UI_SNAP") or "", "%d+") do snaps[tonumber(s)] = true end
for s, p in string.gmatch(os.getenv("UI_DUMP") or "", "(%d+):([^,]+)") do dumps[tonumber(s)] = p end
local exitat = tonumber(os.getenv("UI_EXIT") or "600")
local frame, nb, base, cur = 0, 1, nil, {}
_G.h = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  manager.machine.video.throttled = false
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nb <= #boot and frame >= boot[nb][1] do boot[nb][2](); nb = nb + 1 end
  local tk = mem:read_u8(6) * 256 + mem:read_u8(7)
  if not base and frame > 500 and tk >= 10 and tk < 1000 then base = frame; print("UI ready at frame " .. frame) end
  if not base then return end
  local t = frame - base
  local want = {}
  for _, e in ipairs(seq) do
    local k = e[3]
    local jx, jy = k:match("^JX=(%d+)$"), k:match("^JY=(%d+)$")
    if t == e[1] and jx then port(":joystick_rx", "AD Stick X"):set_value(tonumber(jx)) end
    if t == e[1] and jy then port(":joystick_ry", "AD Stick Y"):set_value(tonumber(jy)) end
    if K[k] then
      local id = K[k][1] .. "/" .. K[k][2]
      want[id] = want[id] or {k = K[k], v = 0}
      if t >= e[1] and t <= e[2] then want[id].v = 1 end
    end
  end
  for id, x in pairs(want) do if cur[id] ~= x.v then port(x.k[1], x.k[2]):set_value(x.v); cur[id] = x.v end end
  if snaps[t] then manager.machine.video:snapshot(); print("SNAP " .. t) end
  if dumps[t] then
    local fh = io.open(dumps[t], "wb")
    for a = 0x0000, 0x1FFF do fh:write(string.char(mem:read_u8(a))) end
    fh:close(); print("DUMP " .. t .. " " .. dumps[t])
  end
  if t >= exitat then manager.machine:exit() end
end)
