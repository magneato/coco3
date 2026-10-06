-- test/verify.lua - boot FRACTAL like run.sh does, then dump the screen RAM ($4000-$7BFF) once per
-- scene, the moment its finished picture starts to be shown.  Driven by test/verify.sh.
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
local events, f = {}, 80
local cmd = 'LOADM"FRACTAL":EXEC\n'
for i = 1, #cmd do
  local d = keydef(cmd:sub(i, i))
  if d then
    if d[3] then events[#events+1] = {f-2, function() port(":row6","SHIFT"):set_value(1) end} end
    events[#events+1] = {f,   function() port(d[1], d[2]):set_value(1) end}
    events[#events+1] = {f+8, function() port(d[1], d[2]):set_value(0); if d[3] then port(":row6","SHIFT"):set_value(0) end end}
    f = f + 18
  end
end
local out = os.getenv("DUMPDIR")
local A_SCENE, A_TIMER = tonumber(os.getenv("A_SCENE")), tonumber(os.getenv("A_TIMER"))
local frame, nev, seen, started = 0, 1, {}, nil
_G.h = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nev <= #events and frame >= events[nev][1] do events[nev][2](); nev = nev + 1 end
  local pc = cpu.state["PC"].value
  local tk = mem:read_u8(6) * 256 + mem:read_u8(7)
  if not started and frame > 200 and tk > 0 and pc >= 0x2000 and pc < 0x4000 then started = frame end
  local sc = mem:read_u8(A_SCENE)
  local timer = mem:read_u8(A_TIMER) * 256 + mem:read_u8(A_TIMER + 1)
  if started and timer > 0 and timer < 290 and sc < 9 and not seen[sc] then
    seen[sc] = true
    local t = {}
    for a = 0x4000, 0x4000 + 15359 do t[#t+1] = string.char(mem:read_u8(a)) end
    local fh = io.open(out .. "/mame" .. (sc + 1) .. ".bin", "wb"); fh:write(table.concat(t)); fh:close()
    print(string.format("SCENE %d drawn %.1f s after the start", sc + 1, (frame - started) / 60))
    if sc == 8 then manager.machine:exit() end
  end
  if frame > 60 * 60 * 12 then print("TIMEOUT"); manager.machine:exit() end
end)
