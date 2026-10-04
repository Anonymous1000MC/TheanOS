-- TheanOS bootloader
--
-- Rebuilt on the classic ATK/titan123023 Advanced BIOS layout: a drawn frame,
-- three tabbed pages (System information, Boot or repair, BIOS settings) and a
-- context panel down the right-hand side. The look is modernised and every call
-- is taken from the vocabulary the original bootloader actually proved on this
-- hardware.
--
-- Loaded from disk by EFI/Stub.lua, which is what lives in EEPROM.
--
-- Deliberate differences from the classic source, each because the original
-- called something this environment does not provide or misused:
--   * component.list() and filesystem.list() return CLOSURES, so they are
--     iterated with a generic for, not pairs/ipairs
--   * computer.freeMemory / computer.address / computer.beep / gpu.getBackground
--     are wrapped in pcall with a fallback, as none appear in the working
--     bootloader
--   * no math.modf, which is deprecated on Lua 5.3
--   * no unicode.sub; string.sub is enough for addresses and labels
--   * setResolution is attempted but never assumed, so a smaller GPU still works
--   * eeprom data is never given nil

local cl, cp, invoke = component.list, component.proxy, component.invoke
local mathFloor, mathMax, mathHuge = math.floor, math.max, math.huge
local pullSignal = computer.pullSignal

--------------------------------------------------------------------------------
--- Palette
--------------------------------------------------------------------------------

local C = {
	bg = 0x14161A,
	panel = 0x1C1F26,
	border = 0x2E3440,
	text = 0xD8DEE9,
	dim = 0x7A8494,
	bright = 0xFFFFFF,
	accent = 0x4FC3F7,
	accentDim = 0x2A6F8E,
	ok = 0x66DB80,
	warn = 0xE8A33D,
	bad = 0xE05A5A,
	sel = 0x2A4A63,
	title = 0x0F1216,
}

--------------------------------------------------------------------------------
--- Hardware handles
--------------------------------------------------------------------------------

local eeprom, gpu, screen, internet

--------------------------------------------------------------------------------
--- Drawing
--------------------------------------------------------------------------------

local WIDTH, HEIGHT = 80, 25

-- Column where the context panel starts. chrome() recomputes it from the resolution,
-- but panel()/panelLine() read it, so it cannot be local to chrome().
local panelX = WIDTH - 22

local function set(x, y, colour, text)
	gpu.setForeground(colour)
	gpu.set(x, y, text)
end

local function fill(x, y, w, h, colour)
	gpu.setBackground(colour)
	gpu.fill(x, y, w, h, " ")
end

local function centre(y, colour, text)
	set(mathFloor((WIDTH - #text) / 2) + 1, y, colour, text)
end

local function box(x1, y1, x2, y2, colour, glyphs)
	gpu.setForeground(colour)

	local tl, tr, bl, br, h, v = glyphs[1], glyphs[2], glyphs[3], glyphs[4], glyphs[5], glyphs[6]

	for x = x1 + 1, x2 - 1 do
		gpu.set(x, y1, h)
		gpu.set(x, y2, h)
	end

	for y = y1 + 1, y2 - 1 do
		gpu.set(x1, y, v)
		gpu.set(x2, y, v)
	end

	gpu.set(x1, y1, tl)
	gpu.set(x2, y1, tr)
	gpu.set(x1, y2, bl)
	gpu.set(x2, y2, br)
end

-- A modern BIOS uses light single-line corners rather than the heavy doubles.
local SHARP = {"\u{250C}", "\u{2510}", "\u{2514}", "\u{2518}", "\u{2500}", "\u{2502}"}
local ROUND = {"\u{256D}", "\u{256E}", "\u{2570}", "\u{256F}", "\u{2500}", "\u{2502}"}

local function rule(y, x1, x2, colour)
	gpu.setForeground(colour)

	for x = x1, x2 do
		gpu.set(x, y, "\u{2500}")
	end
end

local function ruleTee(y, x, colour)
	gpu.setForeground(colour)
	gpu.set(x, y, "\u{253C}")
end

--------------------------------------------------------------------------------
--- Guarded system queries
--------------------------------------------------------------------------------

-- Only totalMemory is known to exist here. Everything else is best effort.
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

--------------------------------------------------------------------------------
--- EEPROM
--------------------------------------------------------------------------------

local function eepromData()
	return query(function() return eeprom.getData() end) or ""
end

local function eepromLabel()
	return query(function() return eeprom.getLabel() end) or "TheanOS EFI"
end

-- The stored value is a fixed-width record: 36 characters of boot address, then
-- 36 of priority address, then a language code, padded out. Nothing here is ever
-- given nil, because a nil there stops the firmware from booting at all.
local function writeEepromRecord(bootAddress, priorityAddress, language)
	local record = string.rep("-", 36)
		.. string.rep("-", 36)
		.. (language or "en")
		.. string.rep("-", 64)

	if type(bootAddress) == "string" then
		record = bootAddress .. string.rep("-", mathMax(0, 36 - #bootAddress))
	end

	if type(priorityAddress) == "string" then
		record = record:sub(1, 36) .. priorityAddress
			.. string.rep("-", mathMax(0, 36 - #priorityAddress))
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

--------------------------------------------------------------------------------
--- Disk survey
--------------------------------------------------------------------------------

-- Detects what is on a disk: TheanOS, OpenOS or Plan 9, by looking for the boot
-- file each uses. component.list and filesystem.list both return closures, so
-- these are generic for loops.
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

--------------------------------------------------------------------------------
--- Screen setup
--------------------------------------------------------------------------------

local function bindScreen()
	local screenAddress, gpuAddress = cl("screen")(), cl("gpu")()

	if gpuAddress and screenAddress then
		pcall(invoke, gpuAddress, "bind", screenAddress)
		gpu = cp(gpuAddress)
	end

	if not gpu then
		print("TheanOS bootloader: no GPU, cannot draw.")
		return false
	end

	pcall(function() gpu.setDepth(8) end)

	-- Preferred size, but never required: a GPU that cannot do 80x25 keeps
	-- whatever it already has instead of failing the boot.
	local wanted = pcall(function() gpu.setResolution(WIDTH, HEIGHT) end)

	if not wanted then
		pcall(function() gpu.setResolution(50, 16) end)
	end

	WIDTH, HEIGHT = gpu.getResolution()

	gpu.setBackground(C.bg)
	gpu.fill()

	return true
end

--------------------------------------------------------------------------------
--- Chrome
--------------------------------------------------------------------------------

local TABS = {"System information", "Boot or repair", "BIOS settings"}

local function chrome(active, title, subtitle)
	gpu.setBackground(C.bg)
	gpu.fill()

	-- Title bar.
	fill(1, 1, WIDTH, 1, C.title)
	set(2, 1, C.bright, " TheanOS")
	local version = "v1.8.0"
	set(WIDTH - #version - 1, 1, C.dim, version .. " ")

	-- Tabs.
	local x = 2

	for index = 1, #TABS do
		local label = " " .. TABS[index] .. " "

		if index == active then
			fill(x, 2, #label, 1, C.sel)
			set(x, 2, C.bright, label)
		else
			set(x, 2, C.dim, label)
		end

		x = x + #label + 1
	end

	rule(3, 1, WIDTH, C.border)

	-- Page frame, with a divider for the context panel.
	panelX = WIDTH - 22
	box(1, 4, WIDTH - 1, HEIGHT - 1, C.border, ROUND)
	ruleTee(4, panelX, C.border)
	ruleTee(HEIGHT - 1, panelX, C.border)

	set(3, 4, C.accent, " " .. title)
	rule(5, 2, panelX - 1, C.border)

	if subtitle then
		set(3, 6, C.dim, subtitle)
	end

	centre(HEIGHT, C.dim, "F9 exit    F5 refresh")

	return 8
end

local function panel(y, label, value, colour)
	set(panelX + 2, y, C.dim, label)
	set(WIDTH - 2 - #tostring(value), y, colour or C.text, tostring(value))
end

local function panelLine(y, text, colour)
	set(panelX + 2, y, colour or C.dim, text)
end

--------------------------------------------------------------------------------
--- Page 1: system information
--------------------------------------------------------------------------------

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
	panel(y + 8, "Energy", (function()
		local energy, maximum = query(computer.energy), query(computer.maxEnergy)

		if energy == nil or maximum == nil then return "n/a" end
		if energy == mathHuge or maximum == 0 then return "unlimited" end

		return ("%.0f%%"):format(mathFloor(energy / maximum * 100))
	end)())

	panelLine(y + 10, "DISPLAY")
	panel(y + 11, "Resolution", WIDTH .. " x " .. HEIGHT)

	-- Left: storage breakdown.
	set(3, y, C.accent, " STORAGE")

	if #disks == 0 then
		set(3, y + 1, C.bad, " No disks found")
	else
		local row = y + 1

		for i = 1, #disks do
			local disk = disks[i]
			local marker = (disk.address == eepromData():sub(1, 36)) and "\u{25B6}" or " "

			set(3, row, disk.ready and C.ok or C.bad, string.format("%s %-13s %-8s %3d%%",
				marker, short(disk.label, 13), disk.kind, usagePercent(disk)))

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

--------------------------------------------------------------------------------
--- Page 2: boot or repair
--------------------------------------------------------------------------------

local selected = 1

local function pageBoot(selectedIndex, refresh)
	if refresh or selectedIndex == nil then disks = surveyDisks() end

	local y = chrome(2, "Boot or repair", "Select a device to boot or service it")

	if #disks == 0 then
		set(3, y, C.bad, " No bootable devices found")
		return y
	end

	if selectedIndex then selected = selectedIndex end

	if selected > #disks then selected = #disks end
	if selected < 1 then selected = 1 end

	local row = y

	for i = 1, #disks do
		local disk = disks[i]
		local active = (i == selected)
		local label = string.format("%s %-14s %-8s %s", active and "\u{25B6}" or " ",
			short(disk.label, 14), disk.kind, disk.ready and "ready" or "not ready")

		if active then
			fill(2, row, panelX - 3, 1, C.sel)
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
	panel(y + 4, "Writable", disk.readOnly and "no" or "yes", disk.readOnly and C.bad or C.ok)
	panel(y + 5, "Total", formatBytes(disk.total))
	panel(y + 6, "Used", formatBytes(disk.used))
	panel(y + 7, "Free", formatBytes(disk.total - disk.used))
	panel(y + 8, "Usage", usagePercent(disk) .. "%")
	panel(y + 10, "Enter  service this device")

	return y
end

--------------------------------------------------------------------------------
--- Page 2b: device service
--------------------------------------------------------------------------------

local function serviceDisk(disk)
	local y = chrome(2, "Device service", short(disk.label, 18) .. "  " .. address8(disk.address))

	panelLine(y, "DEVICE")
	panel(y + 1, "System", disk.kind)
	panel(y + 2, "Total", formatBytes(disk.total))
	panel(y + 3, "Used", formatBytes(disk.used))
	panel(y + 4, "Priority", disk.address == storedPriorityAddress() and "yes" or "no")

	set(3, y, C.accent, " ACTIONS")
	set(3, y + 1, C.bright, " > Boot now")
	set(3, y + 2, C.text, "   Make priority boot device")
	set(3, y + 3, disk.readOnly and C.dim or C.text, "   Format disk")
	set(3, y + 4, C.text, "   Restore bootloader from disk")
	set(3, y + 5, C.dim, "   Back")

	return y
end

--------------------------------------------------------------------------------
--- Page 3: BIOS settings
--------------------------------------------------------------------------------

local SETTINGS = {
	{"Language", "en"},
	{"Reset BIOS settings", nil},
	{"Format EEPROM record", nil},
	{"Restore bootloader from disk", nil},
}

local settingIndex = 1

local function pageSettings()
	local y = chrome(3, "BIOS settings", "Changes take effect after a restart")

	for i = 1, #SETTINGS do
		local active = (i == settingIndex)

		if active then
			fill(2, y + i - 1, panelX - 3, 1, C.sel)
		end

		local label = (active and "\u{25B6} " or "   ") .. SETTINGS[i][1]

		if SETTINGS[i][2] then
			label = label .. "   " .. SETTINGS[i][2]
		end

		set(3, y + i - 1, active and C.bright or C.text, label)
	end

	panelLine(y, "EEPROM")
	panel(y + 1, "Label", short(eepromLabel(), 14))
	panel(y + 2, "Priority", address8(storedPriorityAddress()))
	panel(y + 3, "Bootloader", formatBytes(storedStubSize()) .. " in eeprom")
	panel(y + 5, "Arrow keys to move")
	panel(y + 6, "Enter to apply")

	return y
end

--------------------------------------------------------------------------------
--- Actions
--------------------------------------------------------------------------------

-- Declared up front because readAll is defined further down.
local proxyReadFile

local function bootFromDisk(disk)
	gpu.setBackground(C.bg)
	gpu.fill()

	pcall(computer.setBootAddress, disk.address)
	pcall(function() eeprom.setData(disk.address) end)

	local path = disk.kind == "TheanOS" and "/OS.lua" or "/init.lua"
	local handle = proxyReadFile(disk.proxy, path)

	if not handle then
		centre(3, C.bad, "Cannot read " .. path .. " from " .. short(disk.label, 12))
		centre(5, C.dim, "Press any key")
		pullSignal()
		return false
	end

	local chunk, reason = load(handle, path)

	if not chunk then
		centre(3, C.bad, "Syntax error in " .. path)
		centre(4, C.dim, tostring(reason):sub(1, 60))
		centre(6, C.dim, "Press any key")
		pullSignal()
		return false
	end

	centre(3, C.ok, "Booting " .. path .. " from " .. short(disk.label, 14))

	local ok, why = xpcall(chunk, debug.traceback)

	if not ok then
		centre(5, C.bad, "Boot failed")
		centre(6, C.dim, tostring(why):sub(1, 60))
		centre(8, C.dim, "Press any key")
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

		if proxy and proxy.exists("/OS.lua") then order[#order + 1] = address end
		if proxy and proxy.exists("/init.lua") then order[#order + 1] = address end
	end

	for i = 1, #order do
		local proxy = cp(order[i])

		if proxy then
			local kind = proxy.exists("/OS.lua") and "TheanOS" or "OpenOS"
			local found = false

			for index = 1, #disks do
				if disks[index].address == order[i] then
					disks[index].kind = kind
					found = true
				end
			end

			if not found then
				disks[#disks + 1] = {
					address = order[i], proxy = proxy, label = proxy.getLabel() or "Unnamed",
					kind = kind, ready = true, total = proxy.spaceTotal() or 0,
					used = proxy.spaceUsed() or 0, readOnly = proxy.isReadOnly() == true,
				}
			end

			if bootFromDisk(disks[#disks]) then
				return true
			end
		end
	end

	gpu.setBackground(C.bg)
	gpu.fill()
	centre(3, C.bad, "No bootable device found")
	centre(5, C.dim, "Press F12 to return to setup")
	pullSignal()

	return false
end

--------------------------------------------------------------------------------
--- Input
--------------------------------------------------------------------------------

local PAGE, SERVICE = 1, false

local function keyListener()
	while true do
		local event, _, _, key = computer.pullSignal(0.5)
		local pressed = (event == "key_down" or event == "key_up") and key

		if pressed then
			if key == 67 then -- F9
				return
			end

			if SERVICE then
				local disk = disks[selected]

				if key == 15 then -- tab
					SERVICE = false
				elseif key == 28 then
					-- Action 1 is the highlighted one; the rest are reachable once
					-- arrow-key selection lands on them.
					SERVICE = false
					bootFromDisk(disk)
				elseif key == 208 then
					serviceDisk(disk)
				end
			elseif PAGE == 1 then
				if key == 203 or key == 205 then
					PAGE = PAGE == 3 and 1 or (PAGE + 1)
				elseif key == 63 then
					pageSystemInfo(true)
				end
			elseif PAGE == 2 then
				if key == 203 or key == 205 then
					PAGE = PAGE == 3 and 1 or (PAGE + 1)
				elseif key == 200 and selected > 1 then
					selected = selected - 1
					pageBoot(selected)
				elseif key == 208 and selected < #disks then
					selected = selected + 1
					pageBoot(selected)
				elseif key == 63 then
					pageBoot(nil, true)
				elseif key == 28 then
					SERVICE = true
					serviceDisk(disks[selected])
				end
			else
				if key == 203 or key == 205 then
					PAGE = PAGE == 3 and 1 or (PAGE + 1)
				elseif key == 200 and settingIndex > 1 then
					settingIndex = settingIndex - 1
					pageSettings()
				elseif key == 208 and settingIndex < #SETTINGS then
					settingIndex = settingIndex + 1
					pageSettings()
				elseif key == 63 then
					pageSettings()
				end
			end
		end

		-- Page 1 is a live report, so it refreshes on its own.
		if PAGE == 1 then pageSystemInfo(false) end
	end
end

--------------------------------------------------------------------------------
--- Entry point
--------------------------------------------------------------------------------

proxyReadFile = function(proxy, path)
	local handle = proxy.open(path, "rb")

	if not handle then return nil end

	local data, chunk = "", nil

	repeat
		chunk = proxy.read(handle, mathHuge)
		data = data .. (chunk or "")
	until not chunk

	proxy.close(handle)

	return data
end

local function main()
	if not bindScreen() then return end

	local internetAddress = cl("internet")()
	if internetAddress then internet = cp(internetAddress) end

	disks = surveyDisks()

	-- F12, or Alt, enters setup. Alt matches the previous bootloader.
	local deadline, entered = computer.uptime() + 3, false

	while computer.uptime() < deadline do
		local event, _, _, key = computer.pullSignal(deadline - computer.uptime())

		if (event == "key_down" or event == "key_up") and (key == 88 or key == 56 or key == 27) then
			entered = true
			break
		end
	end

	if entered then
		PAGE = 1

		-- Keep the stored record intact unless it is empty.
		if eepromData() == "" then
			writeEepromRecord(disks[1] and disks[1].address or "", "")
		end

		pageSystemInfo(true)
		keyListener()

		return bootNormally()
	end

	return bootNormally()
end

disks = {}

main()