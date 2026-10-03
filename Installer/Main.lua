
-- Checking for required components
local function getComponentAddress(name)
	return component.list(name)() or error("Required " .. name .. " component is missing")
end

local EEPROMAddress, internetAddress, GPUAddress = 
	getComponentAddress("eeprom"),
	getComponentAddress("internet"),
	getComponentAddress("gpu")

-- Binding GPU to screen in case it's not done yet
component.invoke(GPUAddress, "bind", getComponentAddress("screen"))
local screenWidth, screenHeight = component.invoke(GPUAddress, "getResolution")

local repositoryURL = "https://raw.githubusercontent.com/Anonymous1000MC/TheanOS/master/"
local installerURL = "Installer/"
local EFIURL = "EFI/Minified.lua"

local installerPath = "/TheanOS installer/"
local installerPicturesPath = installerPath .. "Installer/Pictures/"
local OSPath = "/"

local temporaryFilesystemProxy, selectedFilesystemProxy

--------------------------------------------------------------------------------

-- Appearance themes. These affect the installer wizard only -- the installed
-- system always boots with its own default look.
local themes = {
	light = {
		background = 0x1E1E1E,
		window = 0xE1E1E1,
		windowText = 0x2D2D2D,
		title = 0x2D2D2D,
		heading = 0x696969,
		muted = 0x969696,
		disabled = 0xA5A5A5,
		border = 0xD2D2D2,
		field = 0xF0F0F0,
		fieldText = 0x787878,
		fieldPlaceholder = 0xC3C3C3,
		menuBackground = 0xF0F0F0,
		menuText = 0x787878,
		menuSelectedBackground = 0x3366CC,
		menuSelectedText = 0xE1E1E1,
		buttonBackground = 0xC3C3C3,
		buttonText = 0x878787,
		buttonPressedBackground = 0xA5A5A5,
		buttonPressedText = 0x696969,
		buttonDisabledBackground = 0xD2D2D2,
		buttonDisabledText = 0xB4B4B4,
		accent = 0x66B6FF,
		accentPassive = 0xD2D2D2,
		accentValue = 0xA5A5A5,
		error = 0xCC0040,
		warning = 0x878787,
		danger = 0xCC4940,
		dangerText = 0xE1E1E1,
		dangerPressed = 0x990000,
		cursor = 0x00A8FF,
		onAccent = 0xFFFFFF,
		switchPipe = 0xF0F0F0,
		progressDone = 0x878787,
		progressLeft = 0xC3C3C3,
	},
	dark = {
		background = 0x0F0F0F,
		window = 0x212121,
		windowText = 0xE1E1E1,
		title = 0xE1E1E1,
		heading = 0xB4B4B4,
		muted = 0x787878,
		disabled = 0x5A5A5A,
		border = 0x2F2F2F,
		field = 0x1A1A1A,
		fieldText = 0xD2D2D2,
		fieldPlaceholder = 0x5A5A5A,
		menuBackground = 0x2A2A2A,
		menuText = 0xB4B4B4,
		menuSelectedBackground = 0x3366CC,
		menuSelectedText = 0xFFFFFF,
		buttonBackground = 0x3A3A3A,
		buttonText = 0xD2D2D2,
		buttonPressedBackground = 0x4A4A4A,
		buttonPressedText = 0xF0F0F0,
		buttonDisabledBackground = 0x2A2A2A,
		buttonDisabledText = 0x5A5A5A,
		accent = 0x66B6FF,
		accentPassive = 0x2F2F2F,
		accentValue = 0x787878,
		error = 0xFF6B6B,
		warning = 0xC3C3C3,
		danger = 0xB33A3A,
		dangerText = 0xE1E1E1,
		dangerPressed = 0x8F2B2B,
		cursor = 0x00A8FF,
		onAccent = 0xFFFFFF,
		switchPipe = 0xB4B4B4,
		progressDone = 0xC3C3C3,
		progressLeft = 0x4A4A4A,
	},
}

local themeName, theme = "light", themes.light

--------------------------------------------------------------------------------

-- Working with components directly before system libraries are downloaded & initialized
local function centrize(width)
	return math.floor(screenWidth / 2 - width / 2)
end

local function centrizedText(y, color, text)
	component.invoke(GPUAddress, "fill", 1, y, screenWidth, 1, " ")
	component.invoke(GPUAddress, "setForeground", color)
	component.invoke(GPUAddress, "set", centrize(#text), y, text)
end

local function title()
	local y = math.floor(screenHeight / 2 - 1)
	centrizedText(y, theme.title, "TheanOS")

	return y + 2
end

local function progress(value)
	local width = 26
	local x, y, part = centrize(width), title(), math.ceil(width * value)
	
	component.invoke(GPUAddress, "setForeground", theme.progressDone)
	component.invoke(GPUAddress, "set", x, y, string.rep("─", part))
	component.invoke(GPUAddress, "setForeground", theme.progressLeft)
	component.invoke(GPUAddress, "set", x + part, y, string.rep("─", width - part))
end

local function filesystemPath(path)
	return path:match("^(.+%/).") or ""
end

local function filesystemName(path)
	return path:match("%/?([^%/]+%/?)$")
end

local function filesystemHideExtension(path)
	return path:match("(.+)%..+") or path
end

local function rawRequest(url, chunkHandler)
	local internetHandle, reason = component.invoke(internetAddress, "request", repositoryURL .. url:gsub("([^%w%-%_%.%~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))

	if internetHandle then
		local chunk, reason
		while true do
			chunk, reason = internetHandle.read(math.huge)	
			
			if chunk then
				chunkHandler(chunk)
			else
				if reason then
					error("Internet request failed: " .. tostring(reason))
				end

				break
			end
		end

		internetHandle.close()
	else
		error("Connection failed: " .. url)
	end
end

local function request(url)
	local data = ""
	
	rawRequest(url, function(chunk)
		data = data .. chunk
	end)

	return data
end

local function download(url, path)
	selectedFilesystemProxy.makeDirectory(filesystemPath(path))

	local fileHandle, reason = selectedFilesystemProxy.open(path, "wb")
	if fileHandle then	
		rawRequest(url, function(chunk)
			selectedFilesystemProxy.write(fileHandle, chunk)
		end)

		selectedFilesystemProxy.close(fileHandle)
	else
		error("File opening failed: " .. tostring(reason))
	end
end

local function deserialize(text)
	local result, reason = load("return " .. text, "=string")
	if result then
		return result()
	else
		error(reason)
	end
end

-- Clearing screen
component.invoke(GPUAddress, "setDepth", 8)
component.invoke(GPUAddress, "setBackground", theme.window)
component.invoke(GPUAddress, "fill", 1, 1, screenWidth, screenHeight, " ")

-- Checking minimum system requirements
do
	local function warning(text)
		centrizedText(title(), theme.warning, text)

		local signal
		repeat
			signal = computer.pullSignal()
		until signal == "key_down" or signal == "touch"

		computer.shutdown()
	end

	if component.invoke(GPUAddress, "getDepth") < 8 then
		warning("At least Tier 3 GPU and screen are required")
	end

	if computer.totalMemory() < 1024 * 1024 * 2 then
		warning("At least 2x Tier 3.5 RAM modules are required")
	end

	-- Searching for appropriate temporary filesystem for storing libraries, images, etc
	for address in component.list("filesystem") do
		local proxy = component.proxy(address)
		if proxy.spaceTotal() >= 2 * 1024 * 1024 then
			temporaryFilesystemProxy, selectedFilesystemProxy = proxy, proxy
			break
		end
	end

	-- If there's no suitable HDDs found - then meow
	if not temporaryFilesystemProxy then
		warning("At least Tier 2 HDD is required")
	end
end

-- First, we need a big ass file list with localizations, applications, wallpapers
progress(0)
local files = deserialize(request(installerURL .. "Files.cfg"))

-- After that we could download required libraries for installer from it
for i = 1, #files.installerFiles do
	progress(i / #files.installerFiles)
	download(files.installerFiles[i], installerPath .. files.installerFiles[i])
end

-- Initializing simple package system for loading system libraries
package = {loading = {}, loaded = {}}

function require(module)
	if package.loaded[module] then
		return package.loaded[module]
	elseif package.loading[module] then
		error("already loading " .. module .. ": " .. debug.traceback())
	else
		package.loading[module] = true

		local handle, reason = temporaryFilesystemProxy.open(installerPath .. "Libraries/" .. module .. ".lua", "rb")
		if handle then
			local data, chunk = ""
			repeat
				chunk = temporaryFilesystemProxy.read(handle, math.huge)
				data = data .. (chunk or "")
			until not chunk

			temporaryFilesystemProxy.close(handle)
			
			local result, reason = load(data, "=" .. module)
			if result then
				package.loaded[module] = result() or true
			else
				error(reason)
			end
		else
			error("File opening failed: " .. tostring(reason))
		end

		package.loading[module] = nil

		return package.loaded[module]
	end
end

-- Initializing system libraries
local filesystem = require("Filesystem")
filesystem.setProxy(temporaryFilesystemProxy)

bit32 = bit32 or require("Bit32")
local image = require("Image")
local text = require("Text")
local number = require("Number")

local screen = require("Screen")
screen.setGPUAddress(GPUAddress)

local GUI = require("GUI")
local system = require("System")
local paths = require("Paths")

--------------------------------------------------------------------------------

-- Creating main UI workspace
local workspace = GUI.workspace()
local workspacePanel = workspace:addChild(GUI.panel(1, 1, workspace.width, workspace.height, theme.background))

-- Main installer window
local window = workspace:addChild(GUI.window(1, 1, 80, 24))
window.localX, window.localY = math.ceil(workspace.width / 2 - window.width / 2), math.ceil(workspace.height / 2 - window.height / 2)
local windowPanel = window:addChild(GUI.panel(1, 1, window.width, window.height, theme.window))

-- Top menu
local menu = workspace:addChild(GUI.menu(1, 1, workspace.width, theme.menuBackground, theme.menuText, theme.menuSelectedBackground, theme.menuSelectedText))
local installerMenu = menu:addContextMenuItem("TheanOS", theme.windowText)

installerMenu:addItem("🗘", "Reboot").onTouch = function()
	computer.shutdown(true)
end

installerMenu:addItem("⏻", "Shutdown").onTouch = function()
	computer.shutdown()
end

-- Main vertical layout
local layout = window:addChild(GUI.layout(1, 1, window.width, window.height - 2, 1, 1))

local stageButtonsLayout = window:addChild(GUI.layout(1, window.height - 1, window.width, 1, 1, 1))
stageButtonsLayout:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
stageButtonsLayout:setSpacing(1, 1, 3)

local function loadImage(name)
	return image.load(installerPicturesPath .. name .. ".pic")
end

local function newInput(width, ...)
	return GUI.input(1, 1, width, 1, theme.field, theme.fieldText, theme.fieldPlaceholder, theme.field, theme.fieldText, "", ...)
end

local function newSwitchAndLabel(width, color, text, state)
	return GUI.switchAndLabel(1, 1, width, 6, color, theme.border, theme.switchPipe, theme.windowText, text .. ":", state)
end

local function addTitle(role, text)
	return layout:addChild(GUI.text(1, 1, theme[role], text))
end

local function addImage(before, after, name)
	if before > 0 then
		layout:addChild(GUI.object(1, 1, 1, before))
	end

	local picture = layout:addChild(GUI.image(1, 1, loadImage(name)))
	picture.height = picture.height + after

	return picture
end

local function newThemedButton(text)
	local button = GUI.adaptiveRoundedButton(1, 1, 2, 0,
		theme.buttonBackground, theme.buttonText,
		theme.buttonPressedBackground, theme.buttonPressedText,
		text)

	button.colors.disabled.background = theme.buttonDisabledBackground
	button.colors.disabled.text = theme.buttonDisabledText

	return button
end

local function addStageButton(text)
	return stageButtonsLayout:addChild(newThemedButton(text))
end

local prevButton = addStageButton("<")
local nextButton = addStageButton(">")

local localization
local stage = 1
local stages = {}

local usernameInput = newInput(30, "")
local passwordInput = newInput(30, "", false, "•")
local passwordSubmitInput = newInput(30, "", false, "•")
local usernamePasswordText = GUI.text(1, 1, theme.error, "")
local withoutPasswordSwitchAndLabel = newSwitchAndLabel(30, 0x66DB80, "", false)

local wallpapersSwitchAndLabel = newSwitchAndLabel(30, 0xFF4980, "", true)
local applicationsSwitchAndLabel = newSwitchAndLabel(30, 0x33DB80, "", true)
local localizationsSwitchAndLabel = newSwitchAndLabel(30, 0x33B6FF, "", true)

local acceptSwitchAndLabel = newSwitchAndLabel(30, 0x9949FF, "", false)

local localizationComboBox = GUI.comboBox(1, 1, 26, 1, theme.field, theme.muted, theme.border, theme.disabled)
for i = 1, #files.localizations do
	localizationComboBox:addItem(filesystemHideExtension(filesystemName(files.localizations[i]))).onTouch = function()
		-- Obtaining localization table
		localization = deserialize(request(installerURL .. files.localizations[i]))

		-- Appearance keys are English-only until translators catch up
		localization.appearance = localization.appearance or "Appearance"
		localization.themeLight = localization.themeLight or "Light"
		localization.themeDark = localization.themeDark or "Dark"
		localization.themeInstallerOnly = localization.themeInstallerOnly or "Appearance applies to the installer only. The installed system always boots with its default look."

		-- Filling widgets with selected localization data
		usernameInput.placeholderText = localization.username
		passwordInput.placeholderText = localization.password
		passwordSubmitInput.placeholderText = localization.submitPassword
		withoutPasswordSwitchAndLabel.label.text = localization.withoutPassword
		wallpapersSwitchAndLabel.label.text = localization.wallpapers
		applicationsSwitchAndLabel.label.text = localization.applications
		localizationsSwitchAndLabel.label.text = localization.languages
		acceptSwitchAndLabel.label.text = localization.accept
	end
end

-- Every widget above is created once and reused across stages, so a theme change
-- has to repaint them in place. Widgets built inside a stage body are recreated
-- from `theme` each time that stage loads, so they need no patching.
local switchAndLabels = {
	withoutPasswordSwitchAndLabel, wallpapersSwitchAndLabel,
	applicationsSwitchAndLabel, localizationsSwitchAndLabel,
	acceptSwitchAndLabel,
}

local function patchInput(input)
	input.colors.default.background = theme.field
	input.colors.default.text = theme.fieldText
	input.colors.focused.background = theme.field
	input.colors.focused.text = theme.fieldText
	input.colors.placeholderText = theme.fieldPlaceholder
	input.colors.cursor = theme.cursor
end

local function patchSwitchAndLabel(switchAndLabel)
	switchAndLabel.label.colors.text = theme.windowText
	switchAndLabel.switch.colors.passive = theme.border
	switchAndLabel.switch.colors.pipe = theme.switchPipe
end

local function addStage(onTouch)
	table.insert(stages, function()
		layout:removeChildren()
		onTouch()
		workspace:draw()
	end)
end

local function loadStage()
	if stage < 1 then
		stage = 1
	elseif stage > #stages then
		stage = #stages
	end

	stages[stage]()
end

local function applyTheme(name)
	if not themes[name] then
		return
	end

	themeName, theme = name, themes[name]

	workspacePanel.colors.background = theme.background
	windowPanel.colors.background = theme.window

	menu.colors.default.background = theme.menuBackground
	menu.colors.default.text = theme.menuText
	menu.colors.selected.background = theme.menuSelectedBackground
	menu.colors.selected.text = theme.menuSelectedText

	patchInput(usernameInput)
	patchInput(passwordInput)
	patchInput(passwordSubmitInput)

	usernamePasswordText.color = theme.error

	for i = 1, #switchAndLabels do
		patchSwitchAndLabel(switchAndLabels[i])
	end

	localizationComboBox.colors.default.background = theme.field
	localizationComboBox.colors.default.text = theme.muted
	localizationComboBox.colors.selected.background = theme.menuSelectedBackground
	localizationComboBox.colors.selected.text = theme.menuSelectedText
	localizationComboBox.colors.arrow.background = theme.border
	localizationComboBox.colors.arrow.text = theme.disabled

	for i = 1, #stageButtonsLayout.children do
		local child = stageButtonsLayout.children[i]
		if child.colors and child.colors.default then
			child.colors.default.background = theme.buttonBackground
			child.colors.default.text = theme.buttonText
			child.colors.pressed.background = theme.buttonPressedBackground
			child.colors.pressed.text = theme.buttonPressedText
			child.colors.disabled.background = theme.buttonDisabledBackground
			child.colors.disabled.text = theme.buttonDisabledText
		end
	end

	loadStage()
	workspace:draw()
end

local function setTheme(name)
	if name == themeName then
		return
	end

	applyTheme(name)
end


local function checkUserInputs()
	local nameEmpty = #usernameInput.text == 0
	local nameVaild = usernameInput.text:match("^%w[%w%s_]+$")
	local passValid = withoutPasswordSwitchAndLabel.switch.state or (#passwordInput.text > 0 and #passwordSubmitInput.text > 0 and passwordInput.text == passwordSubmitInput.text)

	if (nameEmpty or nameVaild) and passValid then
		usernamePasswordText.hidden = true
		nextButton.disabled = nameEmpty or not nameVaild or not passValid
	else
		usernamePasswordText.hidden = false
		nextButton.disabled = true

		if nameVaild then
			usernamePasswordText.text = localization.passwordsArentEqual
		else
			usernamePasswordText.text = localization.usernameInvalid
		end
	end
end

local function checkLicense()
	nextButton.disabled = not acceptSwitchAndLabel.switch.state
end

prevButton.onTouch = function()
	stage = stage - 1
	loadStage()
end

nextButton.onTouch = function(_, _, _, _, _, _, _, username)
	nextButton.lastTouchUsername = username

	stage = stage + 1
	loadStage()
end

acceptSwitchAndLabel.switch.onStateChanged = function()
	checkLicense()
	workspace:draw()
end

withoutPasswordSwitchAndLabel.switch.onStateChanged = function()
	passwordInput.hidden = withoutPasswordSwitchAndLabel.switch.state
	passwordSubmitInput.hidden = withoutPasswordSwitchAndLabel.switch.state
	checkUserInputs()

	workspace:draw()
end

usernameInput.onInputFinished = function()
	checkUserInputs()
	workspace:draw()
end

passwordInput.onInputFinished = usernameInput.onInputFinished
passwordSubmitInput.onInputFinished = usernameInput.onInputFinished

-- Localization selection stage
addStage(function()
	prevButton.disabled = true

	addImage(0, 1, "Languages")
	layout:addChild(localizationComboBox)

	workspace:draw()
	localizationComboBox:getItem(1).onTouch()
end)

-- Appearance stage
addStage(function()
	prevButton.disabled = false
	nextButton.disabled = false

	addImage(0, 1, "Settings")
	addTitle("heading", localization.appearance)

	local function newThemeButton(name, label)
		local selected = themeName == name

		-- adaptiveButtonCreate takes 9 args; disabled colors are patched on after
		local button = GUI.adaptiveRoundedButton(1, 1, 2, 1,
			selected and theme.accent or theme.buttonBackground,
			selected and theme.onAccent or theme.buttonText,
			theme.buttonPressedBackground, theme.buttonPressedText,
			(selected and "● " or "○ ") .. label)

		button.colors.disabled.background = theme.buttonDisabledBackground
		button.colors.disabled.text = theme.buttonDisabledText

		button.onTouch = function()
			setTheme(name)
		end

		return button
	end

	local themeLayout = layout:addChild(GUI.layout(1, 1, layout.width, 3, 1, 1))
	themeLayout:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
	themeLayout:setSpacing(1, 1, 2)

	themeLayout:addChild(newThemeButton("light", localization.themeLight))
	themeLayout:addChild(newThemeButton("dark", localization.themeDark))

	layout:addChild(GUI.object(1, 1, 1, 1))

	local notes = text.wrap({ localization.themeInstallerOnly }, layout.width - 2)
	for i = 1, #notes do
		layout:addChild(GUI.text(1, 1, theme.muted, notes[i]))
	end
end)

-- Filesystem selection stage
addStage(function()
	prevButton.disabled = false
	nextButton.disabled = false

	layout:addChild(GUI.object(1, 1, 1, 1))
	addTitle("heading", localization.select)
	
	local diskLayout = layout:addChild(GUI.layout(1, 1, layout.width, 11, 1, 1))
	diskLayout:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
	diskLayout:setSpacing(1, 1, 1)

	local HDDImage = loadImage("HDD")

	local function select(proxy)
		selectedFilesystemProxy = proxy

		for i = 1, #diskLayout.children do
			diskLayout.children[i].children[1].hidden = diskLayout.children[i].proxy ~= selectedFilesystemProxy
		end
	end

	local function updateDisks()
		local function diskEventHandler(workspace, disk, e1)
			if e1 == "touch" then
				select(disk.proxy)
				workspace:draw()
			end
		end

		local function addDisk(proxy, picture, disabled)
			local disk = diskLayout:addChild(GUI.container(1, 1, 14, diskLayout.height))
			disk.blockScreenEvents = true

			disk:addChild(GUI.panel(1, 1, disk.width, disk.height, theme.border))

			disk:addChild(GUI.button(1, disk.height, disk.width, 1, theme.danger, theme.dangerText, theme.dangerPressed, theme.dangerText, localization.erase)).onTouch = function()
				local list, path = proxy.list("/")
				for i = 1, #list do
					path = "/" .. list[i]

					if proxy.address ~= temporaryFilesystemProxy.address or path ~= installerPath then
						proxy.remove(path)
					end
				end

				updateDisks()
			end

			if disabled then
				picture = image.blend(picture, 0xFFFFFF, 0.4)
				disk.disabled = true
			end

			disk:addChild(GUI.image(4, 2, picture))
			disk:addChild(GUI.label(2, 7, disk.width - 2, 1, disabled and theme.disabled or theme.heading, text.limit(proxy.getLabel() or proxy.address, disk.width - 2))):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)
			disk:addChild(GUI.progressBar(2, 8, disk.width - 2, disabled and theme.accentPassive or theme.accent, disabled and theme.border or theme.field, disabled and theme.disabled or theme.accentValue, math.floor(proxy.spaceUsed() / proxy.spaceTotal() * 100), true, true, "", "% " .. localization.used))

			disk.eventHandler = diskEventHandler
			disk.proxy = proxy
		end

		diskLayout:removeChildren()
		
		for address in component.list("filesystem") do
			local proxy = component.proxy(address)
			if proxy.spaceTotal() >= 1 * 1024 * 1024 then
				addDisk(
					proxy,
					HDDImage,
					proxy.isReadOnly() or proxy.spaceTotal() < 2 * 1024 * 1024
				)
			end
		end

		select(selectedFilesystemProxy)
	end
	
	updateDisks()
end)

-- User profile setup stage
addStage(function()
	checkUserInputs()

	addImage(0, 0, "User")
	addTitle("heading", localization.setup)

	usernameInput.text = nextButton.lastTouchUsername
	layout:addChild(usernameInput)
	layout:addChild(passwordInput)
	layout:addChild(passwordSubmitInput)
	layout:addChild(usernamePasswordText)
	layout:addChild(withoutPasswordSwitchAndLabel)
	
	checkUserInputs()
end)

-- Downloads customization stage
addStage(function()
	nextButton.disabled = false

	addImage(0, 0, "Settings")
	addTitle("heading", localization.customize)

	layout:addChild(wallpapersSwitchAndLabel)
	layout:addChild(applicationsSwitchAndLabel)
	layout:addChild(localizationsSwitchAndLabel)
end)

-- License acception stage
addStage(function()
	checkLicense()

	local lines = text.wrap({request("LICENSE")}, layout.width - 2)
	local textBox = layout:addChild(GUI.textBox(1, 1, layout.width, layout.height - 3, theme.field, theme.heading, lines, 1, 1, 1))

	layout:addChild(acceptSwitchAndLabel)
end)

-- Downloading stage
addStage(function()
	stageButtonsLayout:removeChildren()
	
	-- Creating user profile
	layout:removeChildren()
	addImage(1, 1, "User")
	addTitle("muted", localization.creating)
	workspace:draw()

	-- Renaming if possible
	if not selectedFilesystemProxy.getLabel() then
		selectedFilesystemProxy.setLabel("TheanOS HDD")
	end

	local function switchProxy(runnable)
		filesystem.setProxy(selectedFilesystemProxy)
		runnable()
		filesystem.setProxy(temporaryFilesystemProxy)
	end

	-- Creating system paths
	local userSettings, userPaths
	switchProxy(function()
		paths.create(paths.system)
		userSettings, userPaths = system.createUser(
			usernameInput.text,
			localizationComboBox:getItem(localizationComboBox.selectedItem).text,
			not withoutPasswordSwitchAndLabel.switch.state and passwordInput.text or nil,
			wallpapersSwitchAndLabel.switch.state
		)
	end)

	-- Downloading files
	layout:removeChildren()
	addImage(3, 2, "Downloading")

	local container = layout:addChild(GUI.container(1, 1, layout.width - 20, 2))
	local progressBar = container:addChild(GUI.progressBar(1, 1, container.width, theme.accent, theme.border, theme.accentValue, 0, true, false))
	local cyka = container:addChild(GUI.label(1, 2, container.width, 1, theme.muted, "")):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)

	-- Creating final filelist of things to download
	local downloadList = {}

	local function getData(item)
		if type(item) == "table" then
			return item.path, item.id, item.version, item.shortcut
		else
			return item
		end
	end

	local function addToList(state, key)
		if state then
			local selectedLocalization, path, localizationName = localizationComboBox:getItem(localizationComboBox.selectedItem).text
			
			for i = 1, #files[key] do
				path = getData(files[key][i])

				if filesystem.extension(path) == ".lang" then
					localizationName = filesystem.hideExtension(filesystem.name(path))

					if
						-- If ALL loacalizations need to be downloaded
						localizationsSwitchAndLabel.switch.state or
						-- If it's required localization file
						localizationName == selectedLocalization or
						-- Downloading English "just in case" for non-english localizations
						selectedLocalization ~= "English" and localizationName == "English"
					then
						table.insert(downloadList, files[key][i])
					end
				else
					table.insert(downloadList, files[key][i])
				end
			end
		end
	end

	addToList(true, "required")
	addToList(true, "localizations")
	addToList(true, "requiredWallpapers")
	addToList(applicationsSwitchAndLabel.switch.state, "optional")
	addToList(wallpapersSwitchAndLabel.switch.state, "optionalWallpapers")

	-- Downloading files from created list
	local versions, path, id, version, shortcut = {}
	for i = 1, #downloadList do
		path, id, version, shortcut = getData(downloadList[i])

		cyka.text = text.limit(localization.installing .. " \"" .. path .. "\"", container.width, "center")
		workspace:draw()

		-- Download file
		download(path, OSPath .. path)

		-- Adding system versions data
		if id then
			versions[id] = {
				path = OSPath .. path,
				version = version or 1,
			}
		end

		-- Create shortcut if possible
		if shortcut then
			switchProxy(function()
				system.createShortcut(
					userPaths.desktop .. filesystem.hideExtension(filesystem.name(filesystem.path(path))),
					OSPath .. filesystem.path(path)
				)
			end)
		end

		progressBar.value = math.floor(i / #downloadList * 100)
		workspace:draw()
	end

	-- Flashing EEPROM
	layout:removeChildren()
	addImage(1, 1, "EEPROM")
	addTitle("muted", localization.flashing)
	workspace:draw()
	
	component.invoke(EEPROMAddress, "set", request(EFIURL))
	component.invoke(EEPROMAddress, "setLabel", "TheanOS EFI")
	component.invoke(EEPROMAddress, "setData", selectedFilesystemProxy.address)


	-- Saving system versions
	switchProxy(function()
		filesystem.writeTable(paths.system.versions, versions, true)
	end)

	-- Done info
	layout:removeChildren()
	addImage(1, 1, "Done")
	addTitle("muted", localization.installed)
	addStageButton(localization.reboot).onTouch = function()
		computer.shutdown(true)
	end
	workspace:draw()

	-- Removing temporary installer directory
	temporaryFilesystemProxy.remove(installerPath)
end)

--------------------------------------------------------------------------------

loadStage()
workspace:start()
