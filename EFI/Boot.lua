-- TheanOS bootloader
--
-- Loaded from disk by EFI/Stub.lua, which is what actually lives in EEPROM. Keeping
-- the two apart means this file can be as large as it likes: the update system
-- delivers it as an ordinary file, so pushing a release updates the bootloader
-- with no EEPROM rewrite and no size ceiling.
--
-- Runs in OpenComputers' boot environment. That means no require(), no
-- filesystem library and no MineOS libraries -- only component, computer, gpu,
-- screen and the Lua standard library. Tools/tests/efi_test.lua enforces that.

local componentProxy = component.proxy
local componentList = component.list
local pullSignal = computer.pullSignal
local uptime = computer.uptime

--------------------------------------------------------------------------------
--- Palette and drawing
--------------------------------------------------------------------------------

local COLOR = {
	title = 0x2D2D2D,
	background = 0x1E1E1E,
	text = 0xE1E1E1,
	dim = 0x878787,
	heading = 0xFFFFFF,
	accent = 0x66DB80,
	warn = 0xE8A33D,
	error = 0xE05A5A,
	selected = 0x3A5A8C,
	panel = 0x2A2A2A,
}

local screenWidth, screenHeight = 80, 25
local eepromProxy, gpuProxy, screenProxy

local function bindScreen()
	screenProxy = componentList("screen")()

	if screenProxy then
		gpuProxy.bind(screenProxy, true)
		gpuProxy.setDepth(8)

		screenWidth, screenHeight = gpuProxy.getResolution()
	end
end

local function clearScreen()
	gpuProxy.setBackground(COLOR.background)
	gpuProxy.fill()
end

local function drawText(x, y, color, text)
	gpuProxy.setForeground(color)
	gpuProxy.set(x, y, color, COLOR.background, text)
end

local function drawRectangle(x1, y1, x2, y2, color)
	gpuProxy.setForeground(color)

	for y = y1, y2 do
		gpuProxy.set(x1, y, color, COLOR.background, " ")
		gpuProxy.set(x2, y, color, COLOR.background, " ")
	end

	for x = x1, x2 do
		gpuProxy.set(x, y1, color, COLOR.background, " ")
		gpuProxy.set(x, y2, color, COLOR.background, " ")
	end
end

local function fillRectangle(x1, y1, x2, y2, color)
	gpuProxy.setForeground(color)

	for y = y1, y2 do
		for x = x1, x2 do
			gpuProxy.set(x, y, color, color, " ")
		end
	end
end

local function drawCentered(y, color, text)
	local width = unicode.wlen(text)
	drawText(math.floor(screenWidth / 2 - width / 2), y, color, text)
end

--------------------------------------------------------------------------------
--- Status line
--------------------------------------------------------------------------------

local statusText = ""

-- Only print() is guaranteed in the boot environment, so the status line is done
-- with escape codes rather than io.write.
local function status(text)
	statusText = text
	print("\27[2K\r " .. text)
end

local function clearStatus()
	statusText = ""
	print("\27[2K\r")
end

--------------------------------------------------------------------------------
--- Menu
--------------------------------------------------------------------------------

-- An element is { label = string, action = function or nil, isHeader = bool }
local function header(text)
	return {label = text, isHeader = true}
end

local function item(label, action, value)
	return {label = label, action = action, value = value}
end

local function back(redraw)
	return item("← Back", redraw)
end

local function drawMenu(title, elements)
	local selected = 1
	local redraw = true

	while true do
		if redraw then
			clearScreen()

			drawCentered(2, COLOR.title, title)
			drawRectangle(1, 3, screenWidth, 3, COLOR.title)

			local y = 5
			local shown = 0

			for index = 1, #elements do
				local element = elements[index]

				if not element.hidden then
					shown = shown + 1

					local isSelected = index == selected
					local color = element.isHeader and COLOR.heading
						or (isSelected and COLOR.text or COLOR.dim)

					if isSelected then
						fillRectangle(2, y, screenWidth - 2, y, COLOR.selected)
					end

					drawText(4, y, color, element.label)

					if element.value then
						local valueText = tostring(element.value)

						drawText(
							math.max(4, screenWidth - 3 - unicode.wlen(valueText)),
							y, COLOR.accent, valueText
						)
					end

					y = y + 1
				end
			end

			drawText(2, screenHeight - 1, COLOR.dim, "↑↓ select   Enter confirm   Esc back")
		end

		local event = {pullSignal()}

		if event[1] == "key_down" then
			local code = event[4]

			if code == 200 then -- up
				repeat
					selected = selected - 1
					if selected < 1 then selected = #elements end
				until not elements[selected].hidden

				redraw = true
			elseif code == 208 then -- down
				repeat
					selected = selected + 1
					if selected > #elements then selected = 1 end
				until not elements[selected].hidden

				redraw = true
			elseif code == 28 then -- enter
				local element = elements[selected]

				if element.action then
					clearStatus()

					local keepGoing = element.action()
					if keepGoing == false then break end
				end

				redraw = true
			elseif code == 27 then -- escape
				return true
			end
		end

		if redraw then clearStatus() end
	end
end

--------------------------------------------------------------------------------
--- Hardware report
--------------------------------------------------------------------------------

local function humanBytes(bytes)
	if bytes >= 1024 * 1024 * 1024 then
		return ("%.2f GB"):format(bytes / 1024 / 1024 / 1024)
	elseif bytes >= 1024 * 1024 then
		return ("%.1f MB"):format(bytes / 1024 / 1024)
	elseif bytes >= 1024 then
		return ("%.1f KB"):format(bytes / 1024)
	end

	return (bytes .. " B")
end

local function hasComponent(kind)
	return component.proxy(component.list(kind)()) ~= nil
end

local function componentCount(kind)
	local total = 0

	for _ in componentList(kind) do
		total = total + 1
	end

	return total
end

local function drawPanel(title, lines, footer)
	clearScreen()

	drawCentered(2, COLOR.title, title)
	drawRectangle(1, 3, screenWidth, 3, COLOR.title)

	local y = 5

	for _, line in ipairs(lines) do
		local label, value = line[1], line[2]

		if label then
			drawText(3, y, COLOR.dim, label)

			if value then
				drawText(
					math.max(3 + unicode.wlen(label) + 2, screenWidth - 3 - unicode.wlen(tostring(value))),
					y, COLOR.text, tostring(value)
				)
			end
		else
			drawCentered(y, COLOR.heading, value)
		end

		y = y + 1

		if y >= screenHeight - 2 then break end
	end

	if footer then
		drawCentered(screenHeight - 1, COLOR.dim, footer)
	end
end

local function waitForKey()
	local event = {pullSignal()}

	if event[1] == "key_down" then
		return event[4]
	end

	return nil
end

--------------------------------------------------------------------------------
--- Boot
--------------------------------------------------------------------------------

local BOOT_CANDIDATES = {"/OS.lua", "/init.lua"}

local function readFile(proxy, path)
	local handle, reason = proxy.open(path, "rb")

	if not handle then
		return nil, reason
	end

	local data = ""
	local chunk

	repeat
		chunk = proxy.read(handle, math.huge)
		data = data .. (chunk or "")
	until not chunk

	proxy.close(handle)

	return data
end

-- Reads a whole file through a filesystem proxy. The boot environment has no
-- filesystem library, so this is the only way to read /EFI/Stub.lua.
local function proxyRead(path)
	for address in componentList("filesystem") do
		local proxy = componentProxy(address)

		if proxy and proxy.exists(path) then
			return readFile(proxy, path)
		end
	end
end

local function bootFrom(proxy, once)
	for _, path in ipairs(BOOT_CANDIDATES) do
		if proxy.exists(path) then
			local data, reason = readFile(proxy, path)

			if data then
				clearScreen()
				status("Booting " .. path)

				local chunk, loadReason = load(data, path)

				if chunk then
					local ran, runReason = xpcall(chunk, debug.traceback)

					if ran then
						return true
					end

					status("Boot failed: " .. tostring(runReason))
					print(tostring(runReason))
					waitForKey()
				else
					status("Syntax error in " .. path .. ": " .. tostring(loadReason))
					waitForKey()
				end
			else
				status("Cannot read " .. path .. ": " .. tostring(reason))
				waitForKey()
			end

			break
		end
	end

	return false
end

-- The EEPROM must only ever be handed a string. Passing nil clears the field in a
-- way the firmware then rejects at boot with "expected string, got nil", so an
-- empty string is used to mean "unset" and the result is read back.
local function setBootAddress(address)
	local value = type(address) == "string" and address or ""

	pcall(computer.setBootAddress, value)

	local ok = pcall(function() eepromProxy.setData(value) end)
	local stored = ok and eepromProxy.getData() or nil

	if type(stored) ~= "string" then
		status("Warning: boot address did not save")
		return false
	end

	return true
end

local function bootDevice(address)
	local proxy = componentProxy(address)

	if not proxy then
		return false
	end

	setBootAddress(address)
	return bootFrom(proxy)
end

local function continueBoot()
	local address = eepromProxy.getData()

	if address then
		local proxy = componentProxy(address)

		if proxy then
			clearScreen()
			status("Booting from " .. address:sub(1, 8) .. "…")

			if bootFrom(proxy) then
				return true
			end
		end
	end

	-- Fall back to trying everything we can find, most recently added first.
	for address in componentList("filesystem") do
		local proxy = componentProxy(address)

		if proxy and bootFrom(proxy) then
			computer.shutdown()
		end
	end

	return false
end

--------------------------------------------------------------------------------
--- Disk utility
--------------------------------------------------------------------------------

local function deviceKind(proxy)
	local total = proxy.spaceTotal()

	if total > 1048575 then
		return "HDD"
	elseif total > 65535 then
		return "FDD"
	end

	return "SYS"
end

local function diskList(redraw)
	local elements = {header("Disks"), back(redraw)}

	for address in componentList("filesystem") do
		local proxy = componentProxy(address)
		local label = proxy.getLabel() or "Unnamed"
		local readOnly = proxy.isReadOnly()
		local total = proxy.spaceTotal()
		local used = proxy.spaceUsed()
		local percent = total > 0 and math.ceil(used / total * 100) or 0

		local isBoot = address == eepromProxy.getData()
		local suffix = isBoot and "  ← boot" or ""

		table.insert(elements, item(
			(isBoot and "▶ " or "  ") .. label .. suffix,
			function()
				local actions = {
					header(label .. "  " .. address:sub(1, 8) .. "…"),
					item("Set as boot device", function()
						setBootAddress(address)
						diskList(redraw)
					end),
				}

				if not readOnly then
					table.insert(actions, #actions + 1, item("Rename volume", function()
						-- The BIOS has no keyboard text entry of its own, so this
						-- cycles a small set of names rather than prompting.
						local suggestions = {"TheanOS", "System", "Data", "Backup"}
						local index = 1

						for candidate = 2, #suggestions do
							if suggestions[candidate] == label then
								index = candidate
								break
							end
						end

						index = index % #suggestions + 1
						pcall(proxy.setLabel, suggestions[index])

						status("Volume renamed to " .. suggestions[index])
						diskList(redraw)
					end))

					table.insert(actions, #actions + 1, item("Erase all data", function()
						drawPanel("Erase " .. label, {
							{"This destroys everything on", address:sub(1, 8) .. "…"},
							{"There is no undo.", ""},
						}, "Press Y to confirm, any other key to cancel")

						local code = waitForKey()

						if code == 89 then -- Y
							status("Erasing " .. label)
							local ok, reason = pcall(function() proxy.remove("") end)

							status(ok and "Erased" or ("Erase failed: " .. tostring(reason)))
							waitForKey()
						else
							status("Cancelled")
						end

						diskList(redraw)
					end))
				end

				table.insert(actions, #actions + 1, back(redraw))

				drawMenu("Disk: " .. label, actions)
			end
		))

		table.insert(elements, #elements, item("    " .. deviceKind(proxy) ..
			"  " .. percent .. "% used  " .. humanBytes(total) .. "  " ..
			(readOnly and "read-only" or "writable"), nil,
			nil))
	end

	drawMenu("Disk utility", elements)
end

--------------------------------------------------------------------------------
--- Diagnostics
--------------------------------------------------------------------------------

local function diagnostics()
	local elements = {
		header("Diagnostics"),

		item("Memory", function()
			local total = computer.totalMemory()
			local architecture = computer.getArchitecture()

			drawPanel("Memory", {
				{"Installed", humanBytes(total)},
				{"Architecture", architecture or "unknown"},
				{"Eeprom", hasComponent("eeprom") and "present" or "MISSING"},
			}, "Press any key")
			waitForKey()
			diagnostics()
		end),

		item("Graphics", function()
			local lines = {
				{"Bound screen", screenProxy and "yes" or "no"},
				{"Resolution", screenWidth .. " x " .. screenHeight},
				{"Colour depth", tostring(gpuProxy.getDepth())},
				{"Max resolution", (function()
					local w, h = gpuProxy.maxResolution()
					return w .. " x " .. h
				end)()},
			}

			drawPanel("Graphics", lines, "Press any key")
			waitForKey()
			diagnostics()
		end),

		item("Eeprom", function()
			local label = eepromProxy.getLabel() or "(none)"
			local data = eepromProxy.getData()
			local bootloader = eepromProxy.getBootloader and eepromProxy.getBootloader() or "(unknown)"

			drawPanel("Eeprom", {
				{"Label", label},
				{"Boot address", data or "(unset)"},
				{"Bootloader size", humanBytes(#(bootloader or ""))},
				{"Config version", bootloader and #bootloader > 0 and "present" or "empty"},
			}, "Press any key")
			waitForKey()
			diagnostics()
		end),

		item("Components", function()
			local kinds = {"cpu", "ram", "gpu", "screen", "filesystem", "eeprom", "internet", "keyboard", "crafting", "robot", "modem"}
			local lines = {}

			for _, kind in ipairs(kinds) do
				table.insert(lines, {kind, componentCount(kind)})
			end

			drawPanel("Components", lines, "Press any key")
			waitForKey()
			diagnostics()
		end),

		item("Self test", function()
			local results = {}

			table.insert(results, {"Screen", screenProxy and "pass" or "FAIL"})
			table.insert(results, {"Gpu", gpuProxy and "pass" or "FAIL"})
			table.insert(results, {"Eeprom", eepromProxy and "pass" or "FAIL"})
			table.insert(results, {"Boot address", computer.getBootAddress() and "pass" or "unset"})
			table.insert(results, {"Architecture", computer.getArchitecture() or "unknown"})

			local writable = false

			for address in componentList("filesystem") do
				local proxy = componentProxy(address)

				if proxy and not proxy.isReadOnly() then
					writable = true
					break
				end
			end

			table.insert(results, {"Writable disk", writable and "pass" or "FAIL"})

			drawPanel("Self test", results, "Press any key")
			waitForKey()
			diagnostics()
		end),

		item("Energy", function()
			local energy = computer.energy()
			local maximum = computer.maxEnergy()

			drawPanel("Energy", {
				{"Charge", energy == math.huge and "unlimited" or ("" .. tostring(energy))},
				{"Capacity", maximum == math.huge and "unlimited" or ("" .. tostring(maximum))},
				{"Uptime", tostring(math.floor(uptime())) .. " s"},
			}, "Press any key")
			waitForKey()
			diagnostics()
		end),

		back(function() mainMenu() end),
	}

	drawMenu("Diagnostics", elements)
end

--------------------------------------------------------------------------------
--- Maintenance
--------------------------------------------------------------------------------

local function maintenance()
	local elements = {
		header("Maintenance"),

		item("Clear boot device", function()
			-- Empty string, not nil: the EEPROM has to keep holding a string.
			setBootAddress("")
			status("Boot device cleared; the next boot will scan all disks")
			maintenance()
		end),

		item("Restore bootloader from disk", function()
			-- Reads /EFI/Stub.lua and writes it back. This is the recovery path if
			-- the EEPROM is left without a working bootloader.
			local path = "/EFI/Stub.lua"
			local data = proxyRead(path)

			if not data then
				status("Cannot read " .. path)
				maintenance()
				return
			end

			local written = eepromProxy.set(data)

			if written == false then
				status("EEPROM cannot hold " .. #data .. " bytes")
			else
				eepromProxy.setLabel("TheanOS EFI")

				local stored = eepromProxy.get()

				if type(stored) == "string" and #stored == #data then
					status("Bootloader restored and verified")
				else
					status("Written but not readable. Do not reboot.")
				end
			end

			maintenance()
		end),

		item("Reset bootloader", function()
			drawPanel("Reset bootloader", {
				{"Clears the stored bootloader script."},
				{"The disk copy is untouched, so a", "recovery boot can still find it."},
			}, "Press Y to confirm")

			if waitForKey() == 89 then
				pcall(function() eepromProxy.setBootloader("") end)
				pcall(function() eepromProxy.setLabel(nil) end)
				status("Bootloader reset. Reflash from Settings if needed.")
			else
				status("Cancelled")
			end

			maintenance()
		end),

		item("Boot order", function()
			local address = eepromProxy.getData()

			drawPanel("Boot order", {
				{"Current device", address or "(unset — scan all)"},
				{"", ""},
				{"Disks are tried in component order", "when no device is set."},
			}, "Press any key")
			waitForKey()
			maintenance()
		end),

		back(function() mainMenu() end),
	}

	drawMenu("Maintenance", elements)
end

--------------------------------------------------------------------------------
--- Tools
--------------------------------------------------------------------------------

local function urlBoot()
	local url = ""

	clearScreen()
	drawCentered(2, COLOR.title, "URL boot")
	drawRectangle(1, 3, screenWidth, 3, COLOR.title)
	drawText(3, 5, COLOR.dim, "https://")
	drawText(12, 5, COLOR.text, url .. "_")

	local internetProxy = componentProxy(componentList("internet")())

	if not internetProxy then
		drawText(3, 7, COLOR.error, "No internet component available.")
		drawText(3, screenHeight - 1, COLOR.dim, "Press any key")
		waitForKey()
		return
	end

	local ok = true

	while true do
		local event = {pullSignal(0.5)}

		if event[1] == "key_down" then
			local code, char = event[4], event[3]

			if code == 28 then
				break
			elseif code == 14 then
				url = url:sub(1, -2)
			elseif code == 27 then
				ok = false
				break
			else
				local character = unicode.char(char or 32)

				if character:match("^[%w%d%p/%:%.%-%_~+]+$") and #url < 60 then
					url = url .. character
				end
			end

			drawText(3, 5, COLOR.dim, "https://")
			drawText(12, 5, COLOR.text, url .. "_")
		end
	end

	if not ok or url == "" then
		return
	end

	clearStatus()
	status("Downloading")

	local connection, reason = internetProxy.request("https://" .. url, nil, nil)

	if not connection then
		status("Request failed: " .. tostring(reason))
		waitForKey()
		return
	end

	local data = ""
	local chunk

	while true do
		chunk = connection.read(math.huge)

		if chunk then
			data = data .. chunk
		else
			break
		end
	end

	connection.close()

	local loaded, loadReason = load(data, url)

	if not loaded then
		status("Syntax error: " .. tostring(loadReason))
		waitForKey()
		return
	end

	clearScreen()
	status("Running " .. url)

	local ran, runReason = xpcall(loaded, debug.traceback)

	if not ran then
		status("Failed: " .. tostring(runReason))
		print(tostring(runReason))
		waitForKey()
	end
end

local function memoryTest()
	local results = {}
	local step = 64

	clearScreen()
	drawCentered(2, COLOR.title, "Memory test")
	drawRectangle(1, 3, screenWidth, 3, COLOR.title)

	local y = 5

	for _, size in ipairs({1024, 4096, 16384, 65536}) do
		local blocks = {}

		status("Testing " .. humanBytes(size * step) .. "…")

		local ok = true

		for _ = 1, step do
			local block = {}

			for i = 1, size do
				block[i] = i
			end

			blocks[#blocks + 1] = block
		end

		for index = 1, step do
			for i = 1, size do
				if blocks[index][i] ~= i then
					ok = false
					break
				end
			end

			if not ok then break end
		end

		blocks = nil

		table.insert(results, {humanBytes(size * step), ok and "pass" or "FAIL"})
		drawText(3, y, COLOR.dim, humanBytes(size * step))
		drawText(20, y, ok and COLOR.accent or COLOR.error, ok and "pass" or "FAIL")
		y = y + 1
	end

	drawText(3, screenHeight - 1, COLOR.dim, "Press any key")
	waitForKey()
end

local function tools()
	local elements = {
		header("Tools"),
		item("Boot from URL", urlBoot),
		item("Memory test", memoryTest),
		back(function() mainMenu() end),
	}

	drawMenu("Tools", elements)
end

--------------------------------------------------------------------------------
--- About
--------------------------------------------------------------------------------

local function about()
	local lines = {
		{"TheanOS bootloader"},
		"",
		{"Version", "1.7.0"},
		{"Loaded from", "/EFI/Boot.lua"},
		{"Flashed stub", "/EFI/Stub.lua"},
		{"", ""},
		{"Memory", humanBytes(computer.totalMemory())},
		{"Graphics", screenWidth .. " x " .. screenHeight .. " @ " .. tostring(gpuProxy.getDepth()) .. "bpp"},
		{"Architecture", computer.getArchitecture() or "unknown"},
		{"Uptime", tostring(math.floor(uptime())) .. " s"},
		{"", ""},
		{"Run diagnostics for a full report."},
	}

	drawPanel("About", lines, "Press any key")
	waitForKey()
	mainMenu()
end

--------------------------------------------------------------------------------
--- Main menu
--------------------------------------------------------------------------------

function mainMenu()
	local address = eepromProxy.getData()
	local booted = "not attempted"

	local elements = {
		header("TheanOS bootloader  ·  v1.7.0"),

		item("Continue boot", function()
			if continueBoot() then
				return false
			end

			booted = "failed"
			mainMenu()
		end, booted),

		item("Boot menu", function()
			local devices = {header("Boot from"), back(function() mainMenu() end)}

			for deviceAddress in componentList("filesystem") do
				local proxy = componentProxy(deviceAddress)
				local label = proxy.getLabel() or "Unnamed"
				local isBoot = deviceAddress == eepromProxy.getData()

				table.insert(devices, item(
					(isBoot and "▶ " or "  ") .. label,
					function()
						bootDevice(deviceAddress)
					end,
					deviceAddress:sub(1, 8) .. "…"
				))
			end

			if #devices == 2 then
				table.insert(devices, item("  (no disks found)", nil))
			end

			drawMenu("Boot menu", devices)
		end),

		item("Disk utility", function() diskList(function() mainMenu() end) end),
		item("Diagnostics", diagnostics),
		item("Maintenance", maintenance),
		item("Tools", tools),
		item("About", about),

		item("Reboot", function() computer.shutdown() end),
		item("Power off", function() computer.shutdown() end),
	}

	drawMenu("TheanOS", elements)
end

--------------------------------------------------------------------------------
--- Entry point
--------------------------------------------------------------------------------

eepromProxy = componentProxy(componentList("eeprom")())
gpuProxy = componentProxy(componentList("gpu")())
pcall(function() gpuProxy = gpuProxy or component.gpu end)

if not gpuProxy then
	print("TheanOS bootloader: no GPU, cannot draw.")
	return
end

bindScreen()

local function waitForBootKey()
	-- A short window, because nobody wants a menu on every boot. Two seconds is
	-- long enough to hit a key and short enough not to be in the way.
	local deadline = uptime() + 2

	while uptime() < deadline do
		local event = {pullSignal(deadline - uptime())}

		if event[1] == "key_down" then
			local code = event[4]

			-- Alt, or Esc to be discoverable without knowing the shortcut.
			if code == 56 or code == 27 then
				return true
			end
		end
	end

	return false
end

if waitForBootKey() then
	mainMenu()
else
	if not continueBoot() then
		clearScreen()
		drawCentered(2, COLOR.title, "TheanOS bootloader")
		drawCentered(5, COLOR.error, "No bootable disk found.")
		drawCentered(7, COLOR.dim, "Press Alt for the boot menu.")

		while true do
			local event = {pullSignal()}

			if event[1] == "component_added" and event[3] == "filesystem" then
				if continueBoot() then return end
			elseif event[1] == "key_down" and event[4] == 56 then
				mainMenu()
			end
		end
	end
end