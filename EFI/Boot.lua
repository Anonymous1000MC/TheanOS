
local
	stringsTheanOSEFI,
	stringsChangeLabel,
	stringsKeyDown,
	stringsComponentAdded,
	stringsFilesystem,
	stringsURLBoot,
	stringsBootMark,
	
	componentProxy,
	componentList,
	pullSignal,
	uptime,
	tableInsert,
	mathMax,
	mathMin,
	mathHuge,
	mathFloor,

	colorsTitle,
	colorsBackground,
	colorsText,
	colorsSelectionBackground,
	colorsSelectionText,

	OSList,
	bindGPUToScreen,
	drawRectangle,
	drawText,
	newMenuElement,
	drawCentrizedText,
	drawTitle,
	status,
	executeString,
	boot,
	newMenuBackElement,
	menu,
	input,
	internetExecute =

	"TheanOS EFI",
	"Change label",
	"key_down",
	"component_added",
	"filesystem",
	"URL boot",
	"\u{25B6} ",

	component.proxy,
	component.list,
	computer.pullSignal,
	computer.uptime,
	table.insert,
	math.max,
	math.min,
	math.huge,
	math.floor,

	0x2D2D2D,
	0xE1E1E1,
	0x878787,
	0x878787,
	0xE1E1E1

local
	eeprom,
	gpu,
	internetAddress =

	componentProxy(componentList("eeprom")()),
	componentProxy(componentList("gpu")()),
	componentList("internet")()

local
	gpuSet,
	gpuSetBackground,
	gpuFill,
	eepromSetData,
	eepromGetData,
	eepromSet,
	eepromGet,
	eepromSetLabel,
	eepromGetLabel,
	screenWidth, 
	screenHeight =

	gpu.set,
	gpu.setBackground,
	gpu.fill,
	eeprom.setData,
	eeprom.getData,
	eeprom.set,
	eeprom.get,
	eeprom.setLabel,
	eeprom.getLabel

OSList,
bindGPUToScreen,
drawRectangle,
drawText,
newMenuElement,
drawCentrizedText,
drawTitle,
status,
executeString,
boot,
newMenuBackElement,
menu,
input,
internetExecute =

{
	{
		"/OS.lua"
	},
	{
		"/init.lua",
		function()
			computer.getBootAddress, computer.setBootAddress = eepromGetData, eepromSetData
		end
	}
},

function()
	local screenAddress = componentList("screen")()
	
	if screenAddress then
		gpu.bind(screenAddress, true)
		screenWidth, screenHeight = gpu.getResolution()
		gpu.setDepth(8)	
	end
end,

function(x, y, width, height, color)
	gpuSetBackground(color)
	gpuFill(x, y, width, height, " ")
end,

function(x, y, foreground, text)
	gpu.setForeground(foreground)
	gpuSet(x, y, text)
end,

function(text, callback, breakLoop)
	return {
		s = text,
		c = callback,
		b = breakLoop
	}
end,

function(y, foreground, text)
	drawText(mathFloor(screenWidth / 2 - #text / 2), y, foreground, text)
end,

function(y, title)
	y = mathFloor(screenHeight / 2 - y / 2)
	drawRectangle(1, 1, screenWidth, screenHeight, colorsBackground)
	drawCentrizedText(y, colorsTitle, title)

	return y + 2
end,

function(statusText, needWait)
	local lines = {}

	for line in statusText:gmatch("[^\r\n]+") do
		lines[#lines + 1] = line:gsub("\t", "  ")
	end
	
	local y = drawTitle(#lines, stringsTheanOSEFI)
	
	for i = 1, #lines do
		drawCentrizedText(y, colorsText, lines[i])
		y = y + 1
	end

	if needWait then
		while pullSignal() ~= stringsKeyDown do

		end
	end
end,

function(...)
	local result, reason = load(...)

	if result then
		result, reason = xpcall(result, debug.traceback)

		if result then
			return
		end
	end

	status(reason, 1)
end,

function(proxy)
	local OS

	for i = 1, #OSList do
		OS = OSList[i]

		if proxy.exists(OS[1]) then
			status("Booting from " .. (proxy.getLabel() or proxy.address))

			-- Updating current EEPROM boot address if it's differs from given proxy address
			if eepromGetData() ~= proxy.address then
				eepromSetData(proxy.address)
			end

			-- Running OS pre-boot function
			if OS[2] then
				OS[2]()
			end

			-- Reading boot file
			local handle, data, chunk, success, reason = proxy.open(OS[1], "rb"), ""

			repeat
				chunk = proxy.read(handle, mathHuge)
				data = data .. (chunk or "")
			until not chunk

			proxy.close(handle)

			-- Running boot file
			executeString(data, "=" .. OS[1])

			return 1
		end
	end
end,

function(f)
	return newMenuElement("Back", f, 1)
end,

function(title, items)
	local selectedIndex = 1

	while 1 do
		local y, x, text, e = drawTitle(#items + 2, title)
		
		for i = 1, #items do
			text = "  " .. items[i].s .. "  "
			x = mathFloor(screenWidth / 2 - #text / 2)
			
			if i == selectedIndex then
				gpuSetBackground(colorsSelectionBackground)
				drawText(x, y, colorsSelectionText, text)
				gpuSetBackground(colorsBackground)
			else
				drawText(x, y, colorsText, text)
			end
			
			y = y + 1
		end

		e = { pullSignal() }

		if e[1] == stringsKeyDown then
			if e[4] == 200 and selectedIndex > 1 then
				selectedIndex = selectedIndex - 1
			
			elseif e[4] == 208 and selectedIndex < #items then
				selectedIndex = selectedIndex + 1
			
			elseif e[4] == 28 then
				if items[selectedIndex].c then
					items[selectedIndex].c()
				end
				
				if items[selectedIndex].b then
					break
				end
			end
		elseif e[1] == stringsComponentAdded and e[3] == "screen" then
			bindGPUToScreen()
		end
	end
end,

function(title, prefix)
	local
		y,
		text,
		state,
		prefixedText,
		char,
		e =

		drawTitle(2, title),
		"",
		1

	while 1 do
		prefixedText = prefix .. text

		gpuFill(1, y, screenWidth, 1, " ")
		drawCentrizedText(y, colorsText, prefixedText .. (state and "_" or ""))

		e = { pullSignal(0.5) }

		if e[1] == stringsKeyDown then
			if e[4] == 28 then
				return text

			elseif e[4] == 14 then
				text = text:sub(1, -2)
			
			else
				char = unicode.char(e[3])

				if char:match("^[%w%d%p%s]+") then
					text = text .. char
				end
			end

			state = 1
		
		elseif e[1] == "clipboard" then
			text = text .. e[3]
		
		elseif not e[1] then
			state = not state
		end
	end
end,

function(url)
	local
		connection,
		data,
		result,
		reason =

		componentProxy(internetAddress).request(url),
		""

	if connection then
		status("Downloading script")

		while 1 do
			result, reason = connection.read(mathHuge)	
			
			if result then
				data = data .. result
			else
				connection.close()
				
				if reason then
					status(reason, 1)
				else
					executeString(data, "=url")
				end

				break
			end
		end
	else
		status("Invalid URL", 1)
	end
end

bindGPUToScreen()
status("Hold Alt to show boot options")

-- Set by menu entries that end the session (Continue boot, Boot from device,
-- Reboot) so the Alt block below returns to the normal boot path instead of
-- dropping the user back into the menu.
local menuExit = false

--------------------------------------------------------------------------------
--- Submenus
--
-- Everything below uses only the calls the rest of this file already used:
-- component.list / component.proxy, computer.pullSignal / uptime / shutdown /
-- setBootAddress, gpu.bind / setDepth / setBackground / fill / setForeground /
-- set / getResolution, table.insert, string.rep and math. computer.totalMemory is
-- wrapped in pcall because it is the one addition and may not exist here.
--------------------------------------------------------------------------------

local function safeTotalMemory()
	local ok, value = pcall(computer.totalMemory)
	return (ok and type(value) == "number") and value or nil
end

local function deviceSummary()
	local found, address, total, used = {}, eepromGetData(), 0, 0

	for candidate in componentList(stringsFilesystem) do
		local proxy = componentProxy(candidate)

		if proxy then
			found[#found + 1] = candidate
			total = total + (proxy.spaceTotal() or 0)
			used = used + (proxy.spaceUsed() or 0)
		end
	end

	local percent = total > 0 and mathFloor(used / total * 100) or 0

	return #found, total, used, percent, address
end

local function diagnosticsItems()
	local disks, total, used, percent = deviceSummary()

	local items = {
		newMenuElement("Disks: " .. tostring(disks)),
		newMenuElement("Space: " .. tostring(used) .. " / " .. tostring(total) .. " bytes"),
		newMenuElement("Usage: " .. tostring(percent) .. "%"),
	}

	local memory = safeTotalMemory()
	tableInsert(items, #items, newMenuElement("Memory: " .. (memory and (tostring(mathFloor(memory / 1024)) .. " KB") or "not reported")))

	tableInsert(items, #items, newMenuElement("Boot device: " .. (eepromGetData() or "not set")))
	tableInsert(items, #items, newMenuElement("Screen: " .. tostring(screenWidth) .. " x " .. tostring(screenHeight)))

	tableInsert(items, #items, newMenuBackElement())

	return items
end

local function maintenanceItems()
	return {
		newMenuElement("Clear boot device", function()
			-- An empty string, never nil: the eeprom has to keep holding a string,
			-- and a nil here stops the firmware from booting at all.
			pcall(function() eepromSetData("") end)
			status("Boot device cleared, the next boot will scan every disk")
			menu("Maintenance", maintenanceItems())
		end),

		newMenuElement("Restore bootloader from disk", function()
			local proxy, address

			for candidate in componentList(stringsFilesystem) do
				local candidateProxy = componentProxy(candidate)

				if candidateProxy and candidateProxy.exists("/EFI/Stub.lua") then
					proxy, address = candidateProxy, candidate
					break
				end
			end

			if not proxy then
				status("/EFI/Stub.lua not found on any disk")
				return
			end

			local handle = proxy.open("/EFI/Stub.lua", "rb")
			local data, chunk = "", nil

			if handle then
				repeat
					chunk = proxy.read(handle, mathHuge)
					data = data .. (chunk or "")
				until not chunk

				proxy.close(handle)
			end

			if #data == 0 then
				status("Stub is empty or unreadable")
				return
			end

			local written = eepromSet(data)

			if written == false then
				status("EEPROM cannot hold " .. #data .. " bytes")
			else
				eepromSetLabel("TheanOS EFI")

				local stored = eepromGet()

				if type(stored) == "string" and #stored == #data then
					status("Bootloader restored and verified")
				else
					status("Written but not readable, do not reboot")
				end
			end
		end),

		newMenuBackElement()
	}
end

local function aboutItems()
	local version = "unknown"
	local handle = eepromGetLabel() or stringsTheanOSEFI

	return {
		newMenuElement("TheanOS bootloader"),
		newMenuElement(""),
		newMenuElement("Version: 1.7.4"),
		newMenuElement("Bootloader label: " .. tostring(handle)),
		newMenuElement(""),
		newMenuElement("This menu is served from /EFI/Boot.lua."),
		newMenuElement("EEPROM holds only the small stub that loads it,"),
		newMenuElement("so the bootloader can be updated without reflashing."),
		newMenuElement(""),
		newMenuBackElement()
	}
end

-- Waiting 1 sec for user to press Alt key
local deadline, eventData = uptime() + 1

while uptime() < deadline do
	eventData = { pullSignal(deadline - uptime()) }

	if eventData[1] == stringsKeyDown and eventData[4] == 56 then
		local utilities = {
			newMenuElement("Disk utility", function()
				local
					restrict,
					filesystems =
					
					function(text, limit)
						return (#text < limit and text .. string.rep(" ", limit - #text) or text:sub(1, limit)) .. "   "
					end,
					{ newMenuBackElement() }

				local function updateFilesystems()
					for i = 2, #filesystems do
						table.remove(filesystems, 1)
					end

					for address in componentList(stringsFilesystem) do
						local proxy = componentProxy(address)

						local
							label,
							isReadOnly =

							proxy.getLabel() or "Unnamed",
							proxy.isReadOnly()

						tableInsert(filesystems, 1,
							newMenuElement(
								(address == eepromGetData() and "> " or "  ") ..
								restrict(label, 10) ..
								restrict(proxy.spaceTotal() > 1048575 and "HDD" or proxy.spaceTotal() > 65535 and "FDD" or "SYS", 3) ..
								restrict(isReadOnly and "R  " or "R/W", 3) ..
								restrict(math.ceil(proxy.spaceUsed() / proxy.spaceTotal() * 100) .. "%", 4) ..
								address:sub(1, 8) .. "…",
								
								function()
									local elements = {
										newMenuElement(
											"Set as bootable",
											function()
												eepromSetData(address)
												updateFilesystems()
											end,
											1
										),

										newMenuBackElement()
									}

									if not isReadOnly then
										tableInsert(elements, 2, newMenuElement(
											stringsChangeLabel,
											function()
												pcall(proxy.setLabel, input(stringsChangeLabel, "New value: "))
												updateFilesystems()
											end,
											1
										))

										tableInsert(elements, 3, newMenuElement(
											"Erase",
											function()
												status("Erasing " .. address)
												proxy.remove("")
												updateFilesystems()
											end,
											1
										))
									end

									menu(label .. " (" .. address .. ")", elements)
								end
							)
						)
					end
				end

				updateFilesystems()
				menu("Select filesystem", filesystems)
			end),

			newMenuBackElement()
		}

		-- Boot actions, above the utilities. "Continue" is the default path and is
		-- listed first so it is what a stray Enter press lands on.
		tableInsert(utilities, 1, newMenuElement("Continue boot", function()
			menuExit = true
		end, 1))

		tableInsert(utilities, 2, newMenuElement("Boot from device", function()
			local devices = { newMenuBackElement() }
			local added = 0

			for address in componentList(stringsFilesystem) do
				local proxy = componentProxy(address)
				local label = proxy.getLabel() or "Unnamed"
				local total = proxy.spaceTotal()
				local used = proxy.spaceUsed()
				local percent = total > 0 and mathFloor(used / total * 100) or 0

				added = added + 1

				tableInsert(devices, #devices, newMenuElement(
					(address == eepromGetData() and stringsBootMark or "  ") .. label,
					function()
						eepromSetData(address)
						computer.setBootAddress(address)
						menuExit = true
					end,
					1
				))

				tableInsert(devices, #devices, newMenuElement(
					"      " .. (total > 1048575 and "HDD" or (total > 65535 and "FDD" or "SYS")) ..
					"  " .. percent .. "%  " .. tostring(total) .. " bytes"
				))
			end

			if added == 0 then
				tableInsert(devices, #devices, newMenuElement("  (no disks found)"))
			end

			menu("Boot from device", devices)
		end))

		tableInsert(utilities, 3, newMenuElement("Diagnostics", function()
			menu("Diagnostics", diagnosticsItems())
		end))

		tableInsert(utilities, 4, newMenuElement("Maintenance", function()
			menu("Maintenance", maintenanceItems())
		end))

		tableInsert(utilities, 5, newMenuElement("About", function()
			menu("About", aboutItems())
		end))

		if internetAddress then	
			tableInsert(utilities, 6, newMenuElement("System recovery", function()
				internetExecute("https://tinyurl.com/29urhz7z")
			end))
			
			tableInsert(utilities, 7, newMenuElement(stringsURLBoot, function()
				internetExecute(input(stringsURLBoot, "Address: "))
			end))
		end

		tableInsert(utilities, #utilities, newMenuElement("Reboot", function()
			computer.shutdown()
		end))

		menu(stringsTheanOSEFI .. "  v1.7.4", utilities)

		menuExit = false
	end
end

-- Trying to boot from previously selected fs or from any available
local bootProxy = componentProxy(eepromGetData())

if not (bootProxy and boot(bootProxy)) then
	local function tryBootFromAny()
		for address in componentList(stringsFilesystem) do
			bootProxy = componentProxy(address)

			if boot(bootProxy) then
				computer.shutdown()
			else
				bootProxy = nil
			end
		end

		if not bootProxy then
			status("Not boot sources found")
		end
	end

	tryBootFromAny()

	-- Waiting for any fs component available
	while 1 do
		if pullSignal() == stringsComponentAdded then
			tryBootFromAny()
		end
	end
end
