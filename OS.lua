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

-- Boot splash: a block "T" slides to the left while "heanOS" is revealed after
-- it, over a black background with a white progress bar.
-- Deliberately cheap: the whole splash is 6 rows tall and is redrawn once per
-- library load (14 frames), because the VM is throttled and cooperative.
local BOOT_STEPS = UIRequireTotal
local bootStep = 0

local LOGO_HEIGHT = 3
local BAR_WIDTH = 34
local LETTERS = "heanOS"

local function centrize(width)
	return math.floor(screenWidth / 2 - width / 2)
end

local function drawBootSplash(step)
	step = math.min(step, BOOT_STEPS)

	local bandTop = math.max(1, math.floor(screenHeight / 2) - 2)
	local bandHeight = LOGO_HEIGHT + 3

	-- black background, painted once
	if step == 1 then
		component.invoke(GPUAddress, "setDepth", 8)
		component.invoke(GPUAddress, "setBackground", 0x000000)
		component.invoke(GPUAddress, "fill", 1, 1, screenWidth, screenHeight, " ")
	end

	-- clear only the animated band, not the whole screen
	component.invoke(GPUAddress, "fill", 1, bandTop, screenWidth, bandHeight, " ")

	-- the T travels left over the first few frames, then parks
	local finalX = math.max(2, centrize(24) - 2)
	local startX = math.min(screenWidth - 6, finalX + 16)
	local travel = math.min(step, 5)
	local tX = startX - math.floor((startX - finalX) * (travel - 1) / 4)

	component.invoke(GPUAddress, "setForeground", 0xFFFFFF)

	-- block T
	component.invoke(GPUAddress, "set", tX, bandTop, "███")
	component.invoke(GPUAddress, "set", tX + 1, bandTop + 1, " █ ")
	component.invoke(GPUAddress, "set", tX + 1, bandTop + 2, " █ ")

	-- "heanOS" is revealed one character per frame once the T has parked
	local revealed = math.min(#LETTERS, math.max(0, step - 5))
	if revealed > 0 then
		component.invoke(GPUAddress, "set", tX + 4, bandTop + 1, LETTERS:sub(1, revealed))
	end

	-- white progress bar underneath
	local barX, barY = centrize(BAR_WIDTH), bandTop + LOGO_HEIGHT + 1
	local done = math.ceil(BAR_WIDTH * step / BOOT_STEPS)

	component.invoke(GPUAddress, "setForeground", 0xFFFFFF)
	component.invoke(GPUAddress, "set", barX, barY, string.rep("█", done))

	component.invoke(GPUAddress, "setForeground", 0x3A3A3A)
	component.invoke(GPUAddress, "set", barX + done, barY, string.rep("█", BAR_WIDTH - done))
end

local function UIRequire(module)
	UIRequireCounter = UIRequireCounter + 1
	drawBootSplash(UIRequireCounter)

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

-- Logging in
system.authorize()

-- Main loop with UI regeneration after errors 
while true do
	local success, path, line, traceback = system.call(workspace.start, workspace, 0)
	
	if success then
		break
	else
		system.updateWorkspace()
		system.updateDesktop()
		workspace:draw()
		
		system.error(path, line, traceback)
		workspace:draw()
	end
end
