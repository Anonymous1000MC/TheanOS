-- TheanOS EEPROM stub: the only part stored in EEPROM, so it stays minimal --
-- pick a disk, pick a file, load it. The bootloader (/EFI/Boot.lua) and the OS
-- (/OS.lua) are ordinary files, so updating them needs no EEPROM rewrite.
--
-- Read-only with respect to its own EEPROM, deliberately: 1.7.0 wrote the boot
-- address from in here and the Flash action never restored it, leaving no boot
-- device and a firmware error. See EFI/Recover.lua.

local list, proxy = component.list, component.proxy
local eeprom, gpu = proxy(list("eeprom")()), proxy(list("gpu")())
local screen = proxy(list("screen")())

if screen then gpu.bind(screen, true) gpu.setDepth(8) end

local function fail(msg)
	pcall(function() gpu.set(1, 1, 0xE05A5A, 0, msg) end)
	pcall(function() computer.pullSignal(5) end)
end

local function loadFile(path)
	for address in list("filesystem") do
		local p = proxy(address)

		if p and p.exists(path) then
			local h = p.open(path, "rb")

			if h then
				local d, c = "", nil
				repeat c = p.read(h, math.huge) d = d .. (c or "") until not c
				p.close(h)

				local f = load(d, path)
				if f then return f end

				fail("Syntax error: " .. path)
			end
		end
	end
end

local ok, run = pcall(function()
	local deadline, menu = computer.uptime() + 2, false

	while computer.uptime() < deadline do
		local e = {computer.pullSignal(deadline - computer.uptime())}
		if e[1] == "key_down" and (e[4] == 56 or e[4] == 27) then menu = true break end
	end

	local f = menu and loadFile("/EFI/Boot.lua") or nil
	if not f then f = loadFile("/OS.lua") or loadFile("/init.lua") or loadFile("/EFI/Boot.lua") end

	return f
end)

if not ok then
	fail("Stub error: " .. tostring(run))
elseif run then
	-- Never let an error here leave the machine showing nothing at all.
	local booted, why = xpcall(run, debug.traceback)

	if not booted then fail("Boot failed: " .. tostring(why)) end
else
	fail("No boot disk. Alt for menu.")
end