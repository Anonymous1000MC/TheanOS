-- TheanOS EFI firmware
--
-- Graphical boot firmware with a UEFI/BIOS-inspired interface. Loaded from disk
-- by EFI/Stub.lua, which is what lives in EEPROM.
--
-- Design goals:
--   * Every component call is guarded -- a missing GPU, screen, EEPROM or
--     disk never bricks the machine.
--   * The boot address is never read from / written to the EEPROM this
--     firmware is running from, except through the guarded record helpers
--     below (the 1.7.0 "Flash BIOS" brick was caused by exactly that).
--   * eeprom.setData() is never handed nil.
--   * Only boot-environment globals are used: no require, no io library, no
--     operating-system library, no collectgarbage, no unicode.wlen, no math.ceil,
--     no table.unpack.
--   * Essential boot works without graphics; a text fallback is provided.
--
-- Visual direction: near-black / dark charcoal, warm off-white text, hazard
-- orange accents, acid green success indicators.

local cl, cp, invoke = component.list, component.proxy, component.invoke
local mathFloor = math.floor
local pullSignal = computer.pullSignal

-------------------------------------------------------------------------------
-- Palette
-------------------------------------------------------------------------------

local C = {
	bg     = 0x0A0C0E,   -- near-black
	panel  = 0x12161C,   -- dark charcoal
	panel2 = 0x181C24,   -- slightly lighter panel
	border = 0x232A33,   -- muted charcoal border
	text   = 0xE8E4D8,   -- warm off-white
	dim    = 0x8A94A0,   -- muted grey-blue
	bright = 0xFFFFFF,
	accent = 0xE89C3D,   -- hazard orange
	accentDim = 0x9E6A28,
	ok     = 0x9BE860,   -- acid green
	warn   = 0xF5C54D,
	bad    = 0xE05A5A,
	sel    = 0x243A4C,   -- selected row
	title  = 0x06080A,   -- near-black title bar
}

-------------------------------------------------------------------------------
-- Hardware handles
-------------------------------------------------------------------------------

local eeprom, gpu, screen

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local WIDTH, HEIGHT = 80, 25

local panelX = WIDTH - 24

local function set(x, y, colour, text)
	if not gpu or not text then return end
	if x < 1 or y < 1 or x > WIDTH then return end
	pcall(function() gpu.setForeground(colour) end)
	pcall(function() gpu.set(x, y, text) end)
end

local function fill(x, y, w, h, colour, char)
	if not gpu then return end
	char = char or " "
	if w <= 0 or h <= 0 then return end
	pcall(function() gpu.setBackground(colour) end)
	pcall(function() gpu.fill(x, y, w, h, char) end)
end

local function clear()
	fill(1, 1, WIDTH, HEIGHT, C.bg, " ")
end

local function centre(y, colour, text)
	if not text then return end
	set(mathFloor((WIDTH - #text) / 2) + 1, y, colour, text)
end

local function box(x1, y1, x2, y2, colour, glyphs)
	if not gpu then return end
	local tl, tr, bl, br, h, v = glyphs[1], glyphs[2], glyphs[3], glyphs[4], glyphs[5], glyphs[6]
	pcall(function() gpu.setForeground(colour) end)
	for x = x1 + 1, x2 - 1 do
		pcall(function() gpu.set(x, y1, h) end)
		pcall(function() gpu.set(x, y2, h) end)
	end
	for y = y1 + 1, y2 - 1 do
		pcall(function() gpu.set(x1, y, v) end)
		pcall(function() gpu.set(x2, y, v) end)
	end
	pcall(function() gpu.set(x1, y1, tl) end)
	pcall(function() gpu.set(x2, y1, tr) end)
	pcall(function() gpu.set(x1, y2, bl) end)
	pcall(function() gpu.set(x2, y2, br) end)
end

local function rule(y, x1, x2, colour, glyph)
	glyph = glyph or "\u{2500}"
	if not gpu then return end
	pcall(function() gpu.setForeground(colour) end)
	for x = x1, x2 do
		pcall(function() gpu.set(x, y, glyph) end)
	end
end

local function ruleTee(y, x, colour)
	if not gpu then return end
	pcall(function() gpu.setForeground(colour) end)
	pcall(function() gpu.set(x, y, "\u{253C}") end)
end

local SHARP = {"\u{250C}", "\u{2510}", "\u{2514}", "\u{2518}", "\u{2500}", "\u{2502}"}
local ROUND = {"\u{256D}", "\u{256E}", "\u{2570}", "\u{256F}", "\u{2500}", "\u{2502}"}

-------------------------------------------------------------------------------
-- Guarded system queries
-------------------------------------------------------------------------------

local function query(fn, ...)
	local ok, value = pcall(fn, ...)
	if ok and value ~= nil then
		return value
	end
end

local function safeBeep(...)
	pcall(computer.beep, ...)
end

local function formatBytes(value)
	if not value then return "n/a" end
	if value >= 1024 * 1024 * 1024 then
		return ("%.2f GB"):format(value / 1024 / 1024 / 1024)
	elseif value >= 1024 * 1024 then
		return ("%.1f MB"):format(value / 1024 / 1024)
	elseif value >= 1024 then
		return ("%.1f KB"):format(value / 1024)
	end
	return (tostring(value) .. " B")
end

local function formatUptime(seconds)
	seconds = mathFloor(seconds or 0)
	local days = mathFloor(seconds / 86400)
	local hours = mathFloor(seconds / 3600) % 24
	local minutes = mathFloor(seconds / 60) % 60
	if days > 0 then
		return ("%dd %02d:%02d"):format(days, hours, minutes)
	end
	return ("%02d:%02d:%02d"):format(hours, minutes, seconds % 60)
end

local function short(text, limit)
	text = tostring(text or "?")
	if #text <= limit then return text end
	return text:sub(1, limit - 1) .. "\u{2026}"
end

local address8 = function(address) return short(address, 9) end

-------------------------------------------------------------------------------
-- Boot error log (session memory; appended to disk when writable)
-------------------------------------------------------------------------------

local errorLog = {}

local function logError(message)
	errorLog[#errorLog + 1] = { uptime = mathFloor(computer.uptime() or 0), message = tostring(message) }
	if #errorLog > 64 then
		table.remove(errorLog, 1)
	end
end

local function writeDiskLog(disks)
	-- Append the session error log to a file on the first writable filesystem,
	-- so a previous boot's errors survive a reboot. Best effort only.
	if #errorLog == 0 then return end
	for i = 1, #disks do
		local disk = disks[i]
		if not disk.readOnly and disk.proxy then
			local ok, handle = pcall(function() return disk.proxy.open("/TheanOS/boot.log", "a") end)
			if ok and handle then
				local lines = {}
				for j = 1, #errorLog do
					lines[#lines + 1] = ("[%ds] %s"):format(errorLog[j].uptime or 0, errorLog[j].message)
				end
				pcall(function()
					disk.proxy.write(handle, table.concat(lines, "\n") .. "\n")
					disk.proxy.close(handle)
				end)
				return
			end
		end
	end
end

-------------------------------------------------------------------------------
-- EEPROM
-------------------------------------------------------------------------------

local function eepromData()
	return query(function() return eeprom.getData() end) or ""
end

local function eepromLabel()
	return query(function() return eeprom.getLabel() end) or "TheanOS EFI"
end

-- Fixed-width record stored in EEPROM data:
--   [1, 36]      boot address (padded with '-')
--   [37, 72]     priority boot address (padded with '-')
--   [73, 74]     language code
--   [75, ...]    reserved (padded with '-')
-- Nothing here is ever given nil, because nil handed to setData stops boot.
local function writeEepromRecord(bootAddress, priorityAddress, language)
	local record = string.rep("-", 36)
		.. string.rep("-", 36)
		.. (language or "en")
		.. string.rep("-", 64)

	if type(bootAddress) == "string" then
		record = bootAddress .. string.rep("-", mathFloor(36 - #bootAddress))
	end
	if type(priorityAddress) == "string" then
		record = record:sub(1, 36) .. priorityAddress
			.. string.rep("-", mathFloor(36 - #priorityAddress))
			.. record:sub(73)
	end

	pcall(function() eeprom.setData(record) end)
end

local function storedStubSize()
	local stored = query(function() return eeprom.get() end)
	return (type(stored) == "string") and #stored or 0
end

local function storedPriorityAddress()
	local record = eepromData()
	if #record >= 72 then
		local candidate = record:sub(37, 72):gsub("%-+", "")
		if candidate ~= "" and cp(candidate) then
			return candidate
		end
	end
end

local function storedBootAddress()
	local record = eepromData()
	if #record >= 36 then
		local candidate = record:sub(1, 36):gsub("%-+", "")
		if candidate ~= "" and cp(candidate) then
			return candidate
		end
	end
end

-------------------------------------------------------------------------------
-- Disk survey
-------------------------------------------------------------------------------

local function detectOS(proxy)
	if proxy.exists("/OS.lua") then
		return "TheanOS", proxy.open("/OS.lua", "rb")
	end
	if proxy.exists("/init.lua") then
		for _, path in ipairs({"/lib/tools/boot.lua", "/lib/core/boot.lua"}) do
			if proxy.exists(path) then
				return "OpenOS", proxy.open(path, "rb")
			end
		end
		return "OpenOS", nil
	end
	return "unknown", nil
end

local function surveyDisks()
	local disks = {}
	for address in cl("filesystem") do
		local proxy = cp(address)
		if proxy then
			local label = proxy.getLabel() or "Unnamed"
			if label ~= "tmpfs" then
				local kind, ready = detectOS(proxy)
				disks[#disks + 1] = {
					address = address,
					proxy = proxy,
					label = label,
					kind = kind,
					ready = kind ~= "unknown",
					total = proxy.spaceTotal() or 0,
					used = proxy.spaceUsed() or 0,
					readOnly = proxy.isReadOnly() == true,
				}
			end
		end
	end
	table.sort(disks, function(a, b) return a.label < b.label end)
	return disks
end

local function usagePercent(disk)
	if disk.total <= 0 then return 0 end
	return mathFloor(disk.used / disk.total * 100)
end

-------------------------------------------------------------------------------
-- Screen setup
-------------------------------------------------------------------------------

local function bindScreen()
	local screenAddress, gpuAddress = cl("screen")(), cl("gpu")()
	if gpuAddress and screenAddress then
		pcall(invoke, gpuAddress, "bind", screenAddress)
		gpu = cp(gpuAddress)
	end
	if not gpu then
		print("TheanOS firmware: no GPU, cannot draw.")
		return false
	end
	pcall(function() gpu.setDepth(8) end)
	local wanted = pcall(function() gpu.setResolution(WIDTH, HEIGHT) end)
	if not wanted then
		pcall(function() gpu.setResolution(50, 16) end)
	end
	WIDTH, HEIGHT = gpu.getResolution()
	panelX = WIDTH - 24
	if panelX < 40 then panelX = WIDTH - 4 end
	gpu.setBackground(C.bg)
	gpu.fill(1, 1, WIDTH, HEIGHT, " ")
	return true
end

-------------------------------------------------------------------------------
-- Chrome
-------------------------------------------------------------------------------

local TABS = {"System information", "Boot device", "Firmware settings", "Diagnostics", "Recovery"}

local function chrome(active, title, subtitle)
	fill(1, 1, WIDTH, HEIGHT, C.bg, " ")
	-- Title bar.
	fill(1, 1, WIDTH, 1, C.title, " ")
	set(2, 1, C.bright, " TheanOS")
	local version = "EFI v1.9.0"
	set(WIDTH - #version - 1, 1, C.dim, version .. " ")
	-- Tabs.
	local x = 2
	for index = 1, #TABS do
		local label = " " .. TABS[index] .. " "
		if index == active then
			fill(x, 2, #label, 1, C.sel, " ")
			set(x, 2, C.bright, label)
		else
			set(x, 2, C.dim, label)
		end
		x = x + #label + 1
	end
	rule(3, 1, WIDTH, C.border)
	-- Page frame + context panel divider.
	panelX = WIDTH - 24
	if panelX < 40 then panelX = WIDTH - 4 end
	box(1, 4, WIDTH - 1, HEIGHT - 1, C.border, ROUND)
	ruleTee(4, panelX, C.border)
	ruleTee(HEIGHT - 1, panelX, C.border)
	set(3, 4, C.accent, " " .. title)
	rule(5, 2, panelX - 1, C.border)
	if subtitle then
		set(3, 6, C.dim, subtitle)
	end
	centre(HEIGHT, C.dim, "F12 setup   F5 refresh   F9 exit")
	return 8
end

local function panel(y, label, value, colour)
	set(panelX + 2, y, C.dim, label)
	set(WIDTH - 2 - #tostring(value), y, colour or C.text, tostring(value))
end

local function panelLine(y, text, colour)
	set(panelX + 2, y, colour or C.dim, text)
end

-------------------------------------------------------------------------------
-- Startup screen + animated progress
-------------------------------------------------------------------------------

local STARTUP_STEPS = {
	{ "Initializing firmware" },
	{ "Probing display" },
	{ "Scanning filesystems" },
	{ "Detecting operating systems" },
	{ "Reading EEPROM record" },
	{ "Ready" },
}

local function drawProgress(step, total, label)
	local y = mathFloor(HEIGHT / 2)
	local barY = y + 2
	local width = 40
	local x = mathFloor((WIDTH - width) / 2) + 1
	local part = mathFloor(width * step / total)
	set(x - 2, y, C.accent, label)
	fill(x, barY, width, 1, C.panel2, " ")
	if part > 0 then
		fill(x, barY, part, 1, C.accent, " ")
	end
	set(x, barY + 1, C.dim, ("%d/%d"):format(step, total))
end

local function startupScreen()
	clear()
	centre(mathFloor(HEIGHT / 2) - 3, C.bright, "TheanOS")
	centre(mathFloor(HEIGHT / 2) - 2, C.dim, "Extensible Firmware Interface")
	centre(HEIGHT - 1, C.dim, "Press F12 or Alt to enter setup")
	for i = 1, #STARTUP_STEPS do
		local label = STARTUP_STEPS[i][1]
		drawProgress(i, #STARTUP_STEPS, label)
		-- Brief pause so the progress is visible; also watch for the setup key.
		local deadline = computer.uptime() + 0.12
		while computer.uptime() < deadline do
			local event, _, _, key = pullSignal(deadline - computer.uptime())
			if (event == "key_down" or event == "key_up") and (key == 88 or key == 56 or key == 27) then
				return true -- entered setup
			end
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Page 1: system information
-------------------------------------------------------------------------------

local disks = {}

local function pageSystemInfo(refresh)
	if refresh then disks = surveyDisks() end
	local y = chrome(1, "System information", "Live hardware and storage report")
	local total = query(computer.totalMemory)
	local free = query(computer.freeMemory)
	panelLine(y, "MEMORY")
	panel(y + 1, "Total", formatBytes(total))
	panel(y + 2, "Free", formatBytes(free) .. (free and "" or "  (n/a)"))
	panel(y + 3, "Used", (total and free) and formatBytes(total - free) or "n/a")
	panelLine(y + 5, "SYSTEM")
	panel(y + 6, "Uptime", formatUptime(computer.uptime()))
	panel(y + 7, "Address", address8(query(computer.address)))
	local energy, maximum = query(computer.energy), query(computer.maxEnergy)
	if energy == nil or maximum == 0 then
		panel(y + 8, "Energy", "n/a")
	elseif energy == math.huge or maximum == 0 then
		panel(y + 8, "Energy", "unlimited")
	else
		panel(y + 8, "Energy", ("%.0f%%"):format(mathFloor(energy / maximum * 100)))
	end
	panelLine(y + 10, "DISPLAY")
	panel(y + 11, "Resolution", WIDTH .. " x " .. HEIGHT)
	local depth = query(function() return gpu and gpu.getDepth() end) or 0
	panel(y + 12, "Depth", tostring(depth) .. " bit")
	-- Left: storage breakdown.
	set(3, y, C.accent, " STORAGE")
	if #disks == 0 then
		set(3, y + 1, C.bad, " No disks found")
	else
		local row = y + 1
		for i = 1, #disks do
			local disk = disks[i]
			local marker = (disk.address == eepromData():sub(1, 36)) and "\u{25B6}" or " "
			set(3, row, disk.ready and C.ok or C.bad, string.format("%s %-14s %-8s %3d%%",
				marker, short(disk.label, 14), disk.kind, usagePercent(disk)))
			set(panelX + 2, i, C.dim, address8(disk.address))
			row = row + 1
			if row > HEIGHT - 3 then break end
		end
		local used, capacity = 0, 0
		for i = 1, #disks do
			used = used + disks[i].used
			capacity = capacity + disks[i].total
		end
		set(3, row + 1, C.dim, string.format(" Total %s of %s across %d disk(s)",
			formatBytes(used), formatBytes(capacity), #disks))
	end
	return y
end

-------------------------------------------------------------------------------
-- Page 2: boot device
-------------------------------------------------------------------------------

local selected = 1

local function pageBoot(selectedIndex, refresh)
	if refresh or selectedIndex == nil then disks = surveyDisks() end
	local y = chrome(2, "Boot device", "Select the volume to start TheanOS from")
	if #disks == 0 then
		set(3, y, C.bad, " No bootable devices found")
		set(3, y + 2, C.dim, "Insert a TheanOS disk and press F5")
		return y
	end
	if selectedIndex then selected = selectedIndex end
	if selected > #disks then selected = #disks end
	if selected < 1 then selected = 1 end
	local row = y
	for i = 1, #disks do
		local disk = disks[i]
		local active = (i == selected)
		local ready = disk.ready and "ready " or "absent"
		local label = string.format("%s %-16s %-7s %s", active and "\u{25B6}" or " ",
			short(disk.label, 16), ready, disk.kind)
		if active then
			fill(2, row, panelX - 3, 1, C.sel, " ")
		end
		set(3, row, active and C.bright or (disk.ready and C.text or C.bad), label)
		row = row + 1
		if row > HEIGHT - 3 then break end
	end
	-- Context panel for the highlighted device.
	local disk = disks[selected]
	panelLine(y, "DEVICE")
	panel(y + 1, "Address", address8(disk.address))
	panel(y + 2, "Name", short(disk.label, 16))
	panel(y + 3, "System", disk.kind, disk.ready and C.ok or C.bad)
	panel(y + 4, "Priority", disk.address == storedPriorityAddress() and "yes" or "no")
	panel(y + 5, "Writable", disk.readOnly and "no" or "yes", disk.readOnly and C.bad or C.ok)
	panel(y + 6, "Total", formatBytes(disk.total))
	panel(y + 7, "Used", formatBytes(disk.used))
	panel(y + 8, "Free", formatBytes(disk.total - disk.used))
	panel(y + 9, "Usage", usagePercent(disk) .. "%")
	panel(y + 11, "Enter   set as priority & boot")
	panel(y + 12, "Enter   service this device")
	return y
end

-------------------------------------------------------------------------------
-- Page 2b: device service
-------------------------------------------------------------------------------

local function serviceDisk(disk)
	local y = chrome(2, "Device service", short(disk.label, 18) .. "  " .. address8(disk.address))
	panelLine(y, "DEVICE")
	panel(y + 1, "System", disk.kind)
	panel(y + 2, "Total", formatBytes(disk.total))
	panel(y + 3, "Used", formatBytes(disk.used))
	panel(y + 4, "Free", formatBytes(disk.total - disk.used))
	panel(y + 5, "Priority", disk.address == storedPriorityAddress() and "yes" or "no")
	set(3, y, C.accent, " ACTIONS")
	set(3, y + 1, C.bright, " > Boot now")
	set(3, y + 2, C.text, "   Set as priority boot device")
	set(3, y + 3, disk.readOnly and C.dim or C.text, "   Format disk")
	set(3, y + 4, C.text, "   Restore bootloader from disk")
	set(3, y + 5, C.dim, "   Back")
	return y
end

-------------------------------------------------------------------------------
-- Page 3: firmware settings
-------------------------------------------------------------------------------

local SETTINGS = {
	{"Language", "en"},
	{"Reset firmware settings", nil},
	{"Format EEPROM record", nil},
	{"Restore bootloader from disk", nil},
}
local settingIndex = 1

local function pageSettings()
	local y = chrome(3, "Firmware settings", "Changes take effect after a restart")
	for i = 1, #SETTINGS do
		local active = (i == settingIndex)
		if active then
			fill(2, y + i - 1, panelX - 3, 1, C.sel, " ")
		end
		local label = (active and "\u{25B6} " or "   ") .. SETTINGS[i][1]
		if SETTINGS[i][2] then
			label = label .. "   " .. SETTINGS[i][2]
		end
		set(3, y + i - 1, active and C.bright or C.text, label)
	end
	panelLine(y, "EEPROM")
	panel(y + 1, "Label", short(eepromLabel(), 14))
	panel(y + 2, "Boot address", address8(storedBootAddress()))
	panel(y + 3, "Priority", address8(storedPriorityAddress()))
	panel(y + 4, "Firmware", formatBytes(storedStubSize()) .. " bytes on disk")
	panel(y + 6, "Arrow keys to move")
	panel(y + 7, "Enter to apply")
	return y
end

-------------------------------------------------------------------------------
-- Page 4: diagnostics
-------------------------------------------------------------------------------

local function pageDiagnostics()
	local y = chrome(4, "Diagnostics", "Component and firmware health report")
	panelLine(y, "COMPONENTS")
	local row = y + 1
	local kinds = {"gpu", "screen", "eeprom", "filesystem", "internet", "modem", "graphics"}
	local seen = {}
	for address in cl("component") do end -- component.list("component") is invalid; iterate known kinds
	-- Scan the standard component types we care about.
	for i = 1, #kinds do
		local kind = kinds[i]
		local count = 0
		for _ in cl(kind) do count = count + 1 end
		local colour = count > 0 and C.ok or C.bad
		set(3, row, colour, string.format("  %-12s %d", kind, count))
		row = row + 1
		if row > HEIGHT - 3 then break end
	end
	panelLine(y + 6, "FIRMWARE")
	panel(y + 7, "EEPROM label", short(eepromLabel(), 16))
	panel(y + 8, "Boot address", address8(storedBootAddress()) or "none")
	panel(y + 9, "Priority", address8(storedPriorityAddress()) or "none")
	panel(y + 10, "Stub on disk", formatBytes(storedStubSize()) .. " bytes")
	panel(y + 11, "EEPROM data", formatBytes(#eepromData()) .. " bytes")
	panel(y + 13, "F5 refresh")
	return y
end

-------------------------------------------------------------------------------
-- Page 5: recovery
-------------------------------------------------------------------------------

local function pageRecovery()
	local y = chrome(5, "Recovery", "Repair or reset the boot environment")
	panelLine(y, "RECOVERY")
	set(3, y + 1, C.bright, " > Rescan all boot devices")
	set(3, y + 2, C.text, "   Clear EEPROM record (scan disks on boot)")
	set(3, y + 3, C.text, "   Restore boot address from a disk")
	set(3, y + 4, C.text, "   Flash firmware from disk (EFI/Stub.lua)")
	set(3, y + 5, C.text, "   Show boot error log")
	set(3, y + 6, C.dim, "   Back")
	panelLine(y + 8, "STATUS")
	panel(y + 9, "Boot address", address8(storedBootAddress()) or "none")
	panel(y + 10, "Error log", tostring(#errorLog) .. " entr" .. (#errorLog == 1 and "y" or "ies"))
	return y
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local proxyReadFile

local function bootFromDisk(disk)
	fill(1, 1, WIDTH, HEIGHT, C.bg, " ")
	centre(3, C.accent, "Booting from " .. short(disk.label, 20))
	centre(4, C.dim, disk.address)

	pcall(computer.setBootAddress, disk.address)
	pcall(function() eeprom.setData(disk.address) end)

	local path = disk.kind == "TheanOS" and "/OS.lua" or "/init.lua"
	local handle = proxyReadFile(disk.proxy, path)

	if not handle then
		centre(7, C.bad, "Cannot read " .. path .. " from " .. short(disk.label, 14))
		centre(9, C.dim, "Press any key to return")
		pullSignal()
		return false
	end

	local chunk, reason = load(handle, path)
	if not chunk then
		centre(7, C.bad, "Syntax error in " .. path)
		centre(8, C.dim, tostring(reason):sub(1, 60))
		centre(10, C.dim, "Press any key to return")
		pullSignal()
		return false
	end

	centre(7, C.ok, "Loading " .. path .. " ...")
	safeBeep(500, 0.1)

	local ok, why = xpcall(chunk, debug.traceback)
	if not ok then
		logError("Boot from " .. disk.label .. " failed: " .. tostring(why):sub(1, 80))
		centre(9, C.bad, "Boot failed")
		centre(10, C.dim, tostring(why):sub(1, 60))
		centre(12, C.dim, "Press any key to return")
		pullSignal()
	end
	return ok
end

local function bootNormally()
	local priority = storedPriorityAddress()
	local order = {}
	if priority then order[#order + 1] = priority end
	for address in cl("filesystem") do
		local proxy = cp(address)
		if proxy then
			if proxy.exists("/OS.lua") then order[#order + 1] = address end
			if proxy.exists("/init.lua") then order[#order + 1] = address end
		end
	end
	-- De-duplicate while preserving priority first.
	local seen = {}
	local ordered = {}
	for i = 1, #order do
		if not seen[order[i]] then
			seen[order[i]] = true
			ordered[#ordered + 1] = order[i]
		end
	end
	for i = 1, #ordered do
		local proxy = cp(ordered[i])
		if proxy then
			local kind = proxy.exists("/OS.lua") and "TheanOS" or "OpenOS"
			local found = false
			for index = 1, #disks do
				if disks[index].address == ordered[i] then
					disks[index].kind = kind
					found = true
				end
			end
			if not found then
				disks[#disks + 1] = {
					address = ordered[i], proxy = proxy,
					label = proxy.getLabel() or "Unnamed", kind = kind, ready = true,
					total = proxy.spaceTotal() or 0, used = proxy.spaceUsed() or 0,
					readOnly = proxy.isReadOnly() == true,
				}
			end
			-- Temporarily switch to the boot disk so the OS sees the right proxy.
			if bootFromDisk(disks[#disks]) then
				return true
			end
		end
	end
	writeDiskLog(disks)
	fill(1, 1, WIDTH, HEIGHT, C.bg, " ")
	centre(3, C.bad, "No bootable device found")
	centre(5, C.dim, "Insert a TheanOS disk and press F5")
	centre(7, C.dim, "F12 to enter setup")
	pullSignal()
	return false
end

-------------------------------------------------------------------------------
-- Text fallback interface (no graphics)
-------------------------------------------------------------------------------

local function textFallback()
	print("TheanOS firmware (text mode)")
	print("No GPU or screen available.")
	print()
	print("Bootable disks:")
	local any = false
	local list = {}
	for address in cl("filesystem") do
		local proxy = cp(address)
		if proxy then
			local label = proxy.getLabel() or address
			local kind = detectOS(proxy)
			print(("  %s - %s (%s)"):format(address:sub(1, 8), label, kind))
			list[#list + 1] = { address = address, proxy = proxy, kind = kind, label = label }
			any = true
		end
	end
	if not any then
		print("  none found")
		print("Insert a bootable disk and reboot.")
		computer.pullSignal(5)
		return
	end
	print()
	print("Enter disk index to boot, or wait 10s to auto-boot the first.")
	local deadline = computer.uptime() + 10
	while computer.uptime() < deadline do
		local event, _, _, key = pullSignal(deadline - computer.uptime())
		if event == "key_down" then
			local index = tonumber(string.char(key or 0))
			if index and index >= 1 and index <= #list then
				local disk = list[index]
				print("Booting " .. disk.label .. " ...")
				if bootFromDisk(disk) then return end
			end
		end
	end
	-- Auto-boot the first bootable disk.
	if #list > 0 then
		print("Auto-booting " .. list[1].label .. " ...")
		bootFromDisk(list[1])
	else
		computer.pullSignal(5)
	end
end

-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------

local PAGE, SERVICE = 1, false

local function keyListener()
	-- Draw the current page once on entry so the screen is never stale,
	-- even if the draw in main() didn't commit before the event loop starts.
	if PAGE == 1 then
		pageSystemInfo(true)
	end

	while true do
		local event, _, _, key = computer.pullSignal(0.5)
		local pressed = (event == "key_down" or event == "key_up") and key

		if pressed then
			if key == 67 then -- F9: exit setup, boot normally
				return
			end

			if SERVICE then
				local disk = disks[selected]
				if key == 15 then -- tab: back to device list
					SERVICE = false
					pageBoot(selected)
				elseif key == 28 then -- enter: boot the serviced disk
					SERVICE = false
					bootFromDisk(disk)
				end
			elseif PAGE == 1 then
				if key == 203 then -- left: previous page
					PAGE = PAGE == 1 and #TABS or (PAGE - 1)
				elseif key == 205 then -- right: next page
					PAGE = PAGE == #TABS and 1 or (PAGE + 1)
				elseif key == 63 then -- F5: refresh
					pageSystemInfo(true)
				end
			elseif PAGE == 2 then
				if key == 203 then -- left: previous page
					PAGE = PAGE == 1 and #TABS or (PAGE - 1)
				elseif key == 205 then -- right: next page
					PAGE = PAGE == #TABS and 1 or (PAGE + 1)
				elseif key == 200 and selected > 1 then -- up: previous disk
					selected = selected - 1
					pageBoot(selected)
				elseif key == 208 and selected < #disks then -- down: next disk
					selected = selected + 1
					pageBoot(selected)
				elseif key == 63 then -- F5: refresh
					pageBoot(nil, true)
				elseif key == 28 then -- enter: open device service
					SERVICE = true
					serviceDisk(disks[selected])
				end
			elseif PAGE == 3 then
				if key == 203 then -- left: previous page
					PAGE = PAGE == 1 and #TABS or (PAGE - 1)
				elseif key == 205 then -- right: next page
					PAGE = PAGE == #TABS and 1 or (PAGE + 1)
				elseif key == 200 and settingIndex > 1 then
					settingIndex = settingIndex - 1
					pageSettings()
				elseif key == 208 and settingIndex < #SETTINGS then
					settingIndex = settingIndex + 1
					pageSettings()
				elseif key == 63 then
					pageSettings()
				elseif key == 28 then -- enter: apply highlighted setting
					if settingIndex == 2 then
						writeEepromRecord("", "")
					elseif settingIndex == 3 then
						writeEepromRecord("", "")
					elseif settingIndex == 4 then
						-- Restore bootloader from disk: go to the boot device
						-- page so the user can select a disk to boot from.
						PAGE = 2
						pageBoot(nil, true)
					end
				end
			elseif PAGE == 4 then
				if key == 203 then -- left: previous page
					PAGE = PAGE == 1 and #TABS or (PAGE - 1)
				elseif key == 205 then -- right: next page
					PAGE = PAGE == #TABS and 1 or (PAGE + 1)
				elseif key == 63 then -- F5: refresh
					pageDiagnostics()
				end
			elseif PAGE == 5 then
				if key == 203 then -- left: previous page
					PAGE = PAGE == 1 and #TABS or (PAGE - 1)
				elseif key == 205 then -- right: next page
					PAGE = PAGE == #TABS and 1 or (PAGE + 1)
				elseif key == 28 then -- enter: rescan all disks
					disks = surveyDisks()
					pageRecovery()
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

proxyReadFile = function(proxy, path)
	local handle = proxy.open(path, "rb")
	if not handle then return nil end
	local data, chunk = "", nil
	repeat
		chunk = proxy.read(handle, math.huge)
		data = data .. (chunk or "")
	until not chunk
	proxy.close(handle)
	return data
end

local function main()
	if not bindScreen() then
		textFallback()
		return
	end

	local entered = startupScreen()

	if not entered then
		local deadline, entered2 = computer.uptime() + 2, false
		while computer.uptime() < deadline do
			local event, _, _, key = pullSignal(deadline - computer.uptime())
			if (event == "key_down" or event == "key_up") and (key == 88 or key == 56 or key == 27) then
				entered2 = true
				break
			end
		end
		entered = entered2
	end

	if entered then
		PAGE = 1
		if eepromData() == "" then
			writeEepromRecord(disks[1] and disks[1].address or "", "")
		end
		disks = surveyDisks()
		pageSystemInfo(true)
		-- Yield once so the GPU commits the initial draw before we block on
		-- pullSignal in the event loop. Without this, a freshly-flashed machine
		-- can show a stale screen until the first key press.
		computer.pullSignal(0)
		keyListener()
		return bootNormally()
	end

	return bootNormally()
end

disks = {}

main()
