-- TheanOS EEPROM stub: the only part stored in EEPROM, so it stays minimal --
-- pick a disk, pick a file, load it. The bootloader (/EFI/Boot.lua) and the OS
-- (/OS.lua) are ordinary files, so updating them needs no EEPROM rewrite.

local list, proxy = component.list, component.proxy
local eeprom, gpu = proxy(list("eeprom")()), proxy(list("gpu")())
local screen = proxy(list("screen")())

if screen then gpu.bind(screen, true) gpu.setDepth(8) end

local function loadFile(path)
	for address in list("filesystem") do
		local p = proxy(address)

		if p and p.exists(path) then
			local h = p.open(path, "rb")

			if h then
				local d, c = "", nil
				repeat c = p.read(h, math.huge) d = d .. (c or "") until not c
				p.close(h)

				pcall(computer.setBootAddress, address)
				pcall(function() eeprom.setData(address) end)

				local f = load(d, path)
				if f then return f end

				gpu.set(1, 1, 0xE05A5A, 0, "Syntax error: " .. path)
				computer.pullSignal(3)
			end
		end
	end
end

local deadline, menu = computer.uptime() + 2, false

while computer.uptime() < deadline do
	local e = {computer.pullSignal(deadline - computer.uptime())}
	if e[1] == "key_down" and (e[4] == 56 or e[4] == 27) then menu = true break end
end

local run = menu and loadFile("/EFI/Boot.lua") or nil
if not run then run = loadFile("/OS.lua") or loadFile("/init.lua") or loadFile("/EFI/Boot.lua") end

if run then
	local ok, why = xpcall(run, debug.traceback)
	if not ok then
		gpu.set(1, 1, 0xE05A5A, 0, "Boot failed: " .. tostring(why))
		computer.pullSignal(5)
	end
else
	gpu.set(1, 1, 0xE05A5A, 0, "No boot disk. Alt for menu.")
	computer.pullSignal(5)
end