-- Pizda
---------------------------------------- System initialization ----------------------------------------

-- Obtaining boot filesystem component proxy
local bootFilesystemProxy = component.proxy(component.invoke(component.list("eeprom")(), "getData"))

-- Executes file from boot HDD during OS initialization (will be overriden in filesystem library later)
function dofile(path)
	local stream, reason = bootFilesystemProxy.open(path, "r")
	
	if stream then
		local data, chunk = ""
		
		while true do
			chunk = bootFilesystemProxy.read(stream, math.huge)
			
			if chunk then
				data = data .. chunk
			else
				break
			end
		end

		bootFilesystemProxy.close(stream)

		local result, reason = load(data, "=" .. path)
		
		if result then
			return result()
		else
			error(reason)
		end
	else
		error(reason)
	end
end

-- Initializing global package system
package = {
	paths = {
		["/Libraries/"] = true
	},
	loaded = {},
	loading = {}
}

-- Checks existense of specified path. It will be overriden after filesystem library initialization
local requireExists = bootFilesystemProxy.exists

-- Works the similar way as native Lua require() function
function require(module)
	-- For non-case-sensitive filesystems
	local lowerModule = unicode.lower(module)

	if package.loaded[lowerModule] then
		return package.loaded[lowerModule]
	elseif package.loading[lowerModule] then
		error("recursive require() call found: library \"" .. module .. "\" is trying to require another library that requires it\n" .. debug.traceback())
	else
		local errors = {}

		local function checkVariant(variant)
			if requireExists(variant) then
				return variant
			else
				table.insert(errors, "  variant \"" .. variant .. "\" not exists")
			end
		end

		local function checkVariants(path, module)
			return
				checkVariant(path .. module .. ".lua") or
				checkVariant(path .. module) or
				checkVariant(module)
		end

		local modulePath
		for path in pairs(package.paths) do
			modulePath =
				checkVariants(path, module) or
				checkVariants(path, unicode.upper(unicode.sub(module, 1, 1)) .. unicode.sub(module, 2, -1))
			
			if modulePath then
				package.loading[lowerModule] = true
				local result = dofile(modulePath)
				package.loaded[lowerModule] = result or true
				package.loading[lowerModule] = nil
				
				return result
			end
		end

		error("unable to locate library \"" .. module .. "\":\n" .. table.concat(errors, "\n"))
	end
end

local GPUAddress = component.list("gpu")()
local screenWidth, screenHeight = component.invoke(GPUAddress, "getResolution")

-- Displays title and currently required library when booting OS
local UIRequireTotal, UIRequireCounter = 14, 1

local function centrize(width)
	return math.floor(screenWidth / 2 - width / 2)
end

local function UIRequire(module)
	local title, width = "TheanOS", 26
	local x, y = centrize(width), math.floor(screenHeight / 2 - 1)
	local part = math.ceil(width * UIRequireCounter / UIRequireTotal)
	UIRequireCounter = UIRequireCounter + 1

	-- Title. White, because the background is black.
	component.invoke(GPUAddress, "setForeground", 0xFFFFFF)
	component.invoke(GPUAddress, "set", centrize(#title), y, title)

	-- Progressbar: white for the part already loaded, dim grey for the rest.
	component.invoke(GPUAddress, "setForeground", 0xFFFFFF)
	component.invoke(GPUAddress, "set", x, y + 2, string.rep("─", part))

	component.invoke(GPUAddress, "setForeground", 0x3A3A3A)
	component.invoke(GPUAddress, "set", x + part, y + 2, string.rep("─", width - part))

	return require(module)
end

-- Preparing screen for loading libraries
component.invoke(GPUAddress, "setBackground", 0x000000)
component.invoke(GPUAddress, "fill", 1, 1, screenWidth, screenHeight, " ")

-- Loading libraries
bit32 = bit32 or UIRequire("Bit32")
local paths = UIRequire("Paths")
local event = UIRequire("Event")
local filesystem = UIRequire("Filesystem")

-- Setting main filesystem proxy to what are we booting from
filesystem.setProxy(bootFilesystemProxy)

-- Replacing requireExists function after filesystem library initialization
requireExists = filesystem.exists

-- Loading other libraries
UIRequire("Component")
UIRequire("Keyboard")
UIRequire("Color")
UIRequire("Text")
UIRequire("Number")
local image = UIRequire("Image")
local screen = UIRequire("Screen")

-- Setting currently chosen GPU component as screen buffer main one
screen.setGPUAddress(GPUAddress)

local GUI = UIRequire("GUI")
local system = UIRequire("System")
UIRequire("Network")

-- Filling package.loaded with default global variables for OpenOS bitches
package.loaded.bit32 = bit32
package.loaded.computer = computer
package.loaded.component = component
package.loaded.unicode = unicode

---------------------------------------- Main loop ----------------------------------------

-- Creating OS workspace, which contains every window/menu/etc.
local workspace = GUI.workspace()
system.setWorkspace(workspace)

-- "double_touch" event handler
local doubleTouchInterval, doubleTouchX, doubleTouchY, doubleTouchButton, doubleTouchUptime, doubleTouchcomponentAddress = 0.3
event.addHandler(
	function(signalType, componentAddress, x, y, button, user)
		if signalType == "touch" then
			local uptime = computer.uptime()
			
			if doubleTouchX == x and doubleTouchY == y and doubleTouchButton == button and doubleTouchcomponentAddress == componentAddress and uptime - doubleTouchUptime <= doubleTouchInterval then
				computer.pushSignal("double_touch", componentAddress, x, y, button, user)
				event.skip("touch")
			end

			doubleTouchX, doubleTouchY, doubleTouchButton, doubleTouchUptime, doubleTouchcomponentAddress = x, y, button, uptime, componentAddress
		end
	end
)

-- Screen component attaching/detaching event handler
event.addHandler(
	function(signalType, componentAddress, componentType)
		if (signalType == "component_added" or signalType == "component_removed") and componentType == "screen" then
			local GPUAddress = screen.getGPUAddress()

			local function bindScreen(address)
				screen.setScreenAddress(address, false)
				screen.setColorDepth(8)

				workspace:draw()
			end

			if signalType == "component_added" then
				if not component.invoke(GPUAddress, "getScreen") then
					bindScreen(componentAddress)
				end
			else
				if not component.invoke(GPUAddress, "getScreen") then
					local address = component.list("screen")()
					
					if address then
						bindScreen(address)
					end
				end
			end
		end
	end
)

--------------------------------------------------------------------------------
-- Kernel panic
--
-- Deliberately avoids the GUI library. The usual reason to land here is a fault
-- inside GUI.lua or one of its widgets, and a crash screen that depends on the
-- crashed subsystem cannot report the crash -- the old handler built a
-- GUI.addBackgroundContainer dialog, so a GUI fault took the reporter down with
-- it. Everything below talks to the GPU directly, like the boot splash does.
--------------------------------------------------------------------------------

local PANIC_BACKGROUND = 0x0000AA
local PANIC_TEXT = 0xFFFFFF
local PANIC_DIM = 0x55AAAA
local PANIC_FAULT = 0xFFFF99

local function panicWrite(x, y, color, value)
	value = tostring(value)

	if y < 1 or y > screenHeight or x > screenWidth then return end

	component.invoke(GPUAddress, "setForeground", color)
	component.invoke(GPUAddress, "set", x, y, value)
end

local function panicCentered(y, color, value)
	value = tostring(value)
	panicWrite(math.max(1, centrize(#value)), y, color, value)
end

-- Keeps a value inside the screen; a panic must never itself draw off-screen.
local function panicFit(value, width)
	value = tostring(value)
	width = width or (screenWidth - 4)

	if #value <= width then return value end
	if width <= 3 then return value:sub(1, math.max(1, width)) end

	return value:sub(1, width - 3) .. "..."
end

local function panicRow(y, label, value, color)
	panicWrite(3, y, PANIC_DIM, label)
	panicWrite(3 + #label + 1, y, color or PANIC_TEXT, panicFit(value))
end

local function panicUptime(seconds)
	return ("%d:%02d:%02d"):format(
		math.floor(seconds / 3600),
		math.floor(seconds / 60) % 60,
		math.floor(seconds) % 60
	)
end

-- Anything that touches a library goes through pcall: a panic must not become a
-- second panic while trying to describe the first one.
local function panicDiagnostics()
	local info = {}

	local okVersion, data = pcall(function()
		if filesystem and filesystem.exists and filesystem.exists("/Version.cfg") then
			return filesystem.readTable("/Version.cfg")
		end
	end)

	if okVersion and data and data.version then
		info[#info + 1] = {"Version", data.version}
	end

	local okLabel, label = pcall(function()
		return computer.getComputerLabel and computer.getComputerLabel()
	end)

	if okLabel and type(label) == "string" then info[#info + 1] = {"Computer", label} end

	local okMemory, memory = pcall(function()
		return computer.totalMemory()
	end)

	if okMemory and type(memory) == "number" then
		info[#info + 1] = {"Memory", ("%.1f MB"):format(memory / 1024 / 1024)}
	end

	info[#info + 1] = {"Display", screenWidth .. "x" .. screenHeight}
	info[#info + 1] = {"Uptime", panicUptime(computer.uptime())}

	return info
end

local function kernelPanic(path, line, traceback)
	component.invoke(GPUAddress, "setDepth", 8)
	component.invoke(GPUAddress, "setBackground", PANIC_BACKGROUND)
	component.invoke(GPUAddress, "fill", 1, 1, screenWidth, screenHeight, " ")

	local moduleName = "unknown"
	if type(path) == "string" and path ~= "" then
		moduleName = path:match("[^/]+$") or path
	end

	-- system.call builds its traceback as the error message, a newline, then the
	-- stack. Take the first line as the fault and keep the rest as the stack,
	-- otherwise the message row would spill over the rows below it.
	local fault, stack = "unknown error", ""

	if type(traceback) == "string" and traceback ~= "" then
		fault = traceback:match("^[^\n]*") or traceback
		stack = traceback:sub(#fault + 1):gsub("^\n", "")
	end

	panicCentered(2, PANIC_TEXT, "THEANOS KERNEL PANIC")
	panicCentered(3, PANIC_DIM, panicFit("Not syncing: fatal error in " .. moduleName, screenWidth - 2))

	local y = 5
	panicRow(y, "Fault", fault, PANIC_FAULT); y = y + 1
	panicRow(y, "Module", moduleName); y = y + 1
	panicRow(y, "Line", line or "?")

	-- Diagnostics, then the traceback in whatever room is left.
	y = y + 2
	for _, entry in ipairs(panicDiagnostics()) do
		if y > screenHeight - 6 then break end
		panicRow(y, entry[1], entry[2])
		y = y + 1
	end

	local footerTop = screenHeight - 3
	local traceTop, traceBottom = y + 1, footerTop - 1

	if traceBottom > traceTop and stack ~= "" then
		local shown = 0

		for piece in (stack .. "\n"):gmatch("(.-)\n") do
			if shown >= traceBottom - traceTop + 1 then break end

			piece = piece:gsub("^%s+", "")
			if piece ~= "" then
				panicWrite(3, traceTop + shown, PANIC_DIM, panicFit(piece))
				shown = shown + 1
			end
		end
	end

	if footerTop > 0 then
		panicCentered(footerTop, PANIC_TEXT, "[R] Reboot      [S] Shutdown")
		panicCentered(footerTop + 1, PANIC_DIM, "Press R to reboot, S to power off")
	end

	component.invoke(GPUAddress, "setForeground", PANIC_TEXT)
	component.invoke(GPUAddress, "set", 1, screenHeight, " ")

	-- Raw input, so recovery works even with the GUI out of action.
	-- Payloads differ per signal: touch carries (x, y), key_down carries
	-- (type, character, code), so they are read positionally, not by name.
	while true do
		local signal, second, third, fourth = computer.pullSignal()

		if signal == "key_down" then
			if fourth == 28 then return end

			local pressed = type(third) == "number" and unicode.lower(unicode.char(third)) or ""

			if pressed == "r" then
				computer.shutdown(true)
				return
			elseif pressed == "s" then
				computer.shutdown()
				return
			end

		elseif signal == "touch" then
			-- Upper half reboots, lower half shuts down. third is y here.
			if type(third) == "number" and third <= math.floor(screenHeight / 2) then
				computer.shutdown(true)
			else
				computer.shutdown()
			end

			return

		elseif signal == "terminate" then
			return
		end
	end
end

-- Logging in
system.authorize()

-- Main loop. A fault ends in the panic screen rather than a rebuilt desktop,
-- because the fault is regularly inside the code that would do the rebuilding.
while true do
	local success, path, line, traceback = system.call(workspace.start, workspace, 0)

	if success then
		break
	end

	kernelPanic(path, line, traceback)
end
