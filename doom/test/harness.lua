-- test/harness.lua - boot the real disk image exactly like run.sh does (RGB monitor forced,
-- LOADM typed through the keyboard matrix), then drive the game with scripted keys and take
-- screenshots + telemetry.  Configured through environment variables:
--   SHOTS="900 1000"          emulated frames at which to snapshot
--   KEYSEQ="900-940:RIGHT,..." hold keys (W S A D UP DOWN LEFT RIGHT SPACE T BREAK) in a frame range
--   EXITAT=1200               frame at which to quit MAME
--   LOADCMD='LOADM"DOOM":EXEC'
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local function port(p, f) return manager.machine.ioport.ports[p].fields[f] end

-- ---- keyboard matrix typer (press/release the matrix directly: robust in headless MAME) ----
local ROW = { {"@","A","B","C","D","E","F","G"}, {"H","I","J","K","L","M","N","O"}, {"P","Q","R","S","T","U","V","W"}, {"X","Y","Z"} }
local DIG = { ["0"]="0", ["1"]="1  !  |", ["2"]="2  \"", ["3"]="3  #  ~", ["4"]="4  $", ["5"]="5  %", ["6"]="6  &", ["7"]="7  '  ^" }
local function keydef(ch)
  local u = ch:upper()
  for r, letters in ipairs(ROW) do for _, l in ipairs(letters) do
    if l == u and l:match("%a") then return {":row"..(r-1), l:lower().."  "..l, false} end end end
  if DIG[ch] then return {":row4", DIG[ch], false} end
  if ch == '"' then return {":row4", '2  "', true} end
  if ch == ":" then return {":row5", ":  *", false} end
  if ch == "\n" then return {":row6", "ENTER", false} end
end
local events = {}
local function type_string(str, start)
  local f = start
  for i = 1, #str do
    local d = keydef(str:sub(i, i))
    if d then
      if d[3] then events[#events+1] = {f-2, function() port(":row6","SHIFT"):set_value(1) end} end
      events[#events+1] = {f,   function() port(d[1], d[2]):set_value(1) end}
      events[#events+1] = {f+8, function() port(d[1], d[2]):set_value(0); if d[3] then port(":row6","SHIFT"):set_value(0) end end}
      f = f + 18
    end
  end
end
table.sort(events, function(a, b) return a[1] < b[1] end)
type_string((os.getenv("LOADCMD") or 'LOADM"DOOM":EXEC') .. "\n", 80)
table.sort(events, function(a, b) return a[1] < b[1] end)

-- ---- scripted game keys ----
local KEYMAP = { W={":row2","w  W"}, S={":row2","s  S"}, A={":row0","a  A"}, D={":row0","d  D"}, T={":row2","t  T"}, F={":row0","f  F"}, CTRL={":row6","CTRL"},
  UP={":row3","UP"}, DOWN={":row3","DOWN"}, LEFT={":row3","LEFT"}, RIGHT={":row3","RIGHT"}, SPACE={":row3","SPACE"}, BREAK={":row6","BREAK"} }
local seq, cur = {}, {}
for a, b, k in string.gmatch(os.getenv("KEYSEQ") or "", "(%d+)%-(%d+):(%u+)") do seq[#seq+1] = {tonumber(a), tonumber(b), k} end
local shots = {}
for f in string.gmatch(os.getenv("SHOTS") or "", "%d+") do shots[tonumber(f)] = true end
local txt_at, dump_at = {}, {}
for f in string.gmatch(os.getenv("TXT") or "", "%d+") do txt_at[tonumber(f)] = true end
for f, a, n in string.gmatch(os.getenv("DUMP") or "", "(%d+):(%x+):(%d+)") do dump_at[tonumber(f)] = {tonumber(a, 16), tonumber(n)} end
local watch = tonumber(os.getenv("WATCH") or "-1")
local tele = {}
for f, x, y, a in string.gmatch(os.getenv("TELE") or "", "(%d+):([%d%.]+):([%d%.]+):(%d+)") do tele[tonumber(f)] = {tonumber(x), tonumber(y), tonumber(a)} end
local exitat = tonumber(os.getenv("EXITAT") or "0")
-- TRACEFILE="6091-6093:/path/trace.log": every instruction in that frame range (needs mame -debug)
-- PAGEDUMP="6000:A0-BD:/path/pages.bin": map each physical page into W4 of both tasks, append its 8 KB, quit
local pd_f, pd_a, pd_b, pd_path = (os.getenv("PAGEDUMP") or ""):match("(%d+):(%x+)%-(%x+):(.+)")
pd_f, pd_a, pd_b = tonumber(pd_f), tonumber(pd_a or "0", 16), tonumber(pd_b or "0", 16)
local tf_a, tf_b, tf_path = (os.getenv("TRACEFILE") or ""):match("(%d+)%-(%d+):(.+)")
tf_a, tf_b = tonumber(tf_a), tonumber(tf_b)
local tr_a, tr_b, tr_n = (os.getenv("TRACE") or ""):match("(%d+)%-(%d+):(%d+)")
tr_a, tr_b, tr_n = tonumber(tr_a), tonumber(tr_b), tonumber(tr_n)

local SYM = {}
do
  local f = io.open((os.getenv("BUILD") or "build") .. "/doom.sym", "r")
  if f then for l in f:lines() do local n, v = l:match("^(%S+) EQU %$(%x+)"); if n then SYM[n] = tonumber(v, 16) end end f:close() end
end
local function b8(name) return SYM[name] and mem:read_u8(SYM[name]) or -1 end
local function w(a) return mem:read_u8(a) * 256 + mem:read_u8(a + 1) end
local frame, nev = 0, 1
_G.h = emu.add_machine_frame_notifier(function()      -- keep the handle global or it is garbage collected
  frame = frame + 1
  if os.getenv('TOGGLE') then manager.machine.video.throttled = false end
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nev <= #events and frame >= events[nev][1] do events[nev][2](); nev = nev + 1 end
  local want = {}
  for _, e in ipairs(seq) do
    local k = KEYMAP[e[3]]; local id = k[1] .. "/" .. k[2]
    want[id] = want[id] or {k=k, v=0}
    if frame >= e[1] and frame <= e[2] then want[id].v = 1 end
  end
  for id, x in pairs(want) do
    if cur[id] ~= x.v then port(x.k[1], x.k[2]):set_value(x.v); cur[id] = x.v end
  end
  if tr_a and frame >= tr_a and frame <= tr_b and (frame - tr_a) % tr_n == 0 then
    print(string.format("TRACE t=%.3f frame=%d PC=%04X S=%04X U=%04X X=%04X Y=%04X A=%02X B=%02X DP=%02X CC=%02X fcount=%d W=%d",
      manager.machine.time:as_double(), frame, cpu.state["PC"].value, cpu.state["S"].value, cpu.state["U"].value, cpu.state["X"].value, cpu.state["Y"].value,
      cpu.state["A"].value, cpu.state["B"].value, cpu.state["DP"].value, cpu.state["CC"].value, w(6), (watch >= 0) and mem:read_u8(watch) or -1))
  end
  if pd_f and frame == pd_f then
    local out = io.open(pd_path, "wb")
    for pg = pd_a, pd_b do
      mem:write_u8(0xFFA4, pg); mem:write_u8(0xFFAC, pg)
      local t = {}
      for a = 0x8000, 0x9FFF do t[#t + 1] = string.char(mem:read_u8(a)) end
      out:write(table.concat(t))
    end
    out:close()
    print("PAGEDUMP done")
    manager.machine:exit()
  end
  if tf_a and frame == tf_a then manager.machine.debugger:command("trace " .. tf_path .. ",maincpu") end
  if tf_b and frame == tf_b then manager.machine.debugger:command("trace off,maincpu") end
  if tele[frame] then          -- teleport the player (tile coordinates, angle units) for deterministic screenshots
    local x, y, a = tele[frame][1], tele[frame][2], tele[frame][3]
    local xi, yi = math.floor(x * 256), math.floor(y * 256)
    mem:write_u8(0, xi // 256); mem:write_u8(1, xi % 256); mem:write_u8(2, yi // 256); mem:write_u8(3, yi % 256)
    mem:write_u8(4, a // 256); mem:write_u8(5, a % 256)
  end
  if txt_at[frame] then
    for r = 0, 15 do
      local t = ""
      for c = 0, 31 do local b = mem:read_u8(0x400 + r * 32 + c) & 0x3F; if b < 32 then b = b + 64 end; t = t .. string.char(b) end
      if t:match("%S") then print("TXT|" .. t .. "|") end
    end
  end
  if dump_at[frame] then
    local a, n = dump_at[frame][1], dump_at[frame][2]
    local t = ""
    for i = 0, n - 1 do t = t .. string.format("%02X ", mem:read_u8(a + i)) end
    print(string.format("DUMP frame=%d @%04X: %s", frame, a, t))
  end
  if shots[frame] then
    local score = ""
    if SYM.gauge_tally then for i = 0, 5 do score = score .. mem:read_u8(SYM.gauge_tally + i) end end
    print(string.format("SHOT frame=%d posx=%04X posy=%04X ang=%d fcount=%d spin=%d aimode=%d PC=%04X health=%d ammo=%d score=%s lives=%d q=%d ob=%d",
      frame, w(0), w(2), w(4), w(6), w(8), mem:read_u8(0x0F), cpu.state["PC"].value, b8("vitality"), b8("payload"), score, b8("gauge_lives"), b8("coarseness"), SYM.replay_end and ((w(SYM.replay_end) - 0x1E80) // 2) or -1))
    manager.machine.video:snapshot()
  end
  if exitat > 0 and frame >= exitat then manager.machine:exit() end
end)
