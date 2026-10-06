-- test/watch.lua - boot a disk, type LOADM"<RUN_PROG>":EXEC, then print the 32x16 text screen every
-- WATCH_EVERY frames (and take a snapshot) until $000C turns nonzero (the program is done) or WATCH_MAX
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
local cmd = 'LOADM"' .. os.getenv("RUN_PROG") .. '":EXEC\n'
for i = 1, #cmd do
  local d = keydef(cmd:sub(i, i))
  if d then
    if d[3] then events[#events+1] = {f-2, function() port(":row6","SHIFT"):set_value(1) end} end
    events[#events+1] = {f,   function() port(d[1], d[2]):set_value(1) end}
    events[#events+1] = {f+8, function() port(d[1], d[2]):set_value(0); if d[3] then port(":row6","SHIFT"):set_value(0) end end}
    f = f + 18
  end
end
local every = tonumber(os.getenv("WATCH_EVERY") or "3600")
local snapat = {}
for x in string.gmatch(os.getenv("WATCH_SNAP") or "", "%d+") do snapat[tonumber(x)] = true end
local maxf = tonumber(os.getenv("WATCH_MAX") or "2000000")
local frame, nev, done_at, started = 0, 1, nil, false
local function screen()
  print(string.format("---- frame %d (%.1f min emulated)", frame, frame / 3600))
  for r = 0, 15 do
    local t = ""
    for c = 0, 31 do
      local b = mem:read_u8(0x400 + r * 32 + c)
      if b >= 0x80 then t = t .. "#" else b = b & 0x3F; if b < 32 then b = b + 64 end; t = t .. string.char(b) end
    end
    print("|" .. t .. "|")
  end
end
_G.h = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  manager.machine.video.throttled = false
  local m = manager.machine.ioport.ports[":screen_config"].fields["Monitor Type"]
  if m.user_value ~= 1 then m.user_value = 1 end
  while nev <= #events and frame >= events[nev][1] do events[nev][2](); nev = nev + 1 end
  if frame % every == 0 then screen() end
  if snapat[frame] then manager.machine.video:snapshot() end
  if frame > 300 and mem:read_u8(6) == 0 and mem:read_u8(7) == 1 then started = true end   -- the program's handshake
  if started and mem:read_u8(0x0C) ~= 0 and not done_at then done_at = frame end
  if (done_at and frame >= done_at + 120) or frame >= maxf then
    screen()
    if os.getenv("WATCH_SNAP") then manager.machine.video:snapshot() end
    local dump = os.getenv("WATCH_DUMP")
    if dump then                                   -- W0 and the model windows, for test/verify.sh
      local fh = io.open(dump, "wb")
      for a = 0x0000, 0x1FFF do fh:write(string.char(mem:read_u8(a))) end
      for a = 0x8000, 0xBFFF do fh:write(string.char(mem:read_u8(a))) end
      fh:close()
    end
    manager.machine:exit()
  end
end)
