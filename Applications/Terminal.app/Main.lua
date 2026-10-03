
local GUI = require("GUI")
local system = require("System")
local keyboard = require("Keyboard")
local screen = require("Screen")
local text = require("Text")
local filesystem = require("Filesystem")
local paths = require("Paths")

local currentScriptDirectory = filesystem.path(system.getCurrentScript())
local localization = system.getLocalization(currentScriptDirectory .. "Localizations/")

--------------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------------

local COLOR = {
	text    = 0xD0D0D0,
	dim     = 0x878787,
	user    = 0x66DB80,
	host    = 0x66B6FF,
	path    = 0x66B6FF,
	prompt  = 0xF0F0F0,
	error   = 0xFF6B6B,
	accent  = 0x66B6FF,
	heading = 0xFFFFFF,
	ok      = 0x66DB80,
	warn    = 0xFFCC66,
	cursor  = 0x00A8FF,
}

--------------------------------------------------------------------------------
-- Command set lives next to this file
--------------------------------------------------------------------------------

local COMMANDS = assert(loadfile(currentScriptDirectory .. "Commands.lua"))()
COMMANDS.localization = localization
COMMANDS.COLOR = COLOR

--------------------------------------------------------------------------------
-- Shell state
--------------------------------------------------------------------------------

local shell = {
	cwd = "/",
	lines = {},
	input = "",
	lineFrom = 1,
	history = {},
	historyIndex = 0,
	scrollOffset = 0,
	elevated = false,
	ephemeral = nil,
	exit = false,
}

local userName = paths.user.home:match("^/Users/([^/]+)/") or "user"
local hostName = (computer.getComputerLabel and computer.getComputerLabel()) or "theanos"

local function shortPath(path)
	if path == paths.user.home then
		return "~"
	elseif path:sub(1, #paths.user.home) == paths.user.home then
		return "~" .. path:sub(#paths.user.home + 1)
	end

	return path
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local workspace, window = system.addWindow(GUI.filledWindow(1, 1, 82, 26, 0x000000))

window.titleLabel = window:addChild(
	GUI.label(1, 1, window.width, 1, COLOR.dim, " " .. (localization.terminal or "Terminal"))
):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)

window.actionButtons.localY = 1

local display = window:addChild(GUI.object(2, 4, 1, 1))

--------------------------------------------------------------------------------
-- Output helpers
--------------------------------------------------------------------------------

local function visibleRows()
	return math.max(1, display.height - 2)
end

local function appendLine(value, color)
	for _, wrapped in ipairs(text.wrap(tostring(value), display.width)) do
		shell.lines[#shell.lines + 1] = {text = wrapped, color = color or COLOR.text}
	end
end

function shell.out(value, color)
	appendLine(value, color)
end

function shell.err(value)
	appendLine(value, COLOR.error)
end

function shell.warn(value)
	appendLine(value, COLOR.warn)
end

function shell.clear()
	shell.lines, shell.lineFrom, shell.scrollOffset = {}, 1, 0
end

function shell.terminate()
	shell.exit = true
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local function promptSegments()
	return {
		{userName, COLOR.user},
		{"@", COLOR.dim},
		{hostName, COLOR.host},
		{":", COLOR.dim},
		{shortPath(shell.cwd), COLOR.path},
		{shell.elevated and " # " or " $ ", COLOR.prompt},
	}
end

local function promptText()
	local parts = {}
	for _, segment in ipairs(promptSegments()) do
		parts[#parts + 1] = segment[1]
	end
	return table.concat(parts)
end

display.draw = function()
	local x, originY = display.x, display.y
	local y = originY

	local first = math.max(1, shell.lineFrom - shell.scrollOffset)
	local last = math.min(#shell.lines, first + visibleRows() - 2)

	for i = first, last do
		local line = shell.lines[i]
		screen.drawText(x, y, line.color, line.text)
		y = y + 1
	end

	-- prompt, drawn segment by segment so the colours survive
	local cursorX = x
	for _, segment in ipairs(promptSegments()) do
		screen.drawText(cursorX, y, segment[2], segment[1])
		cursorX = cursorX + unicode.len(segment[1])
	end

	local shown = shell.ephemeral or shell.input
	screen.drawText(cursorX, y, COLOR.text, shown)
	screen.drawText(cursorX + unicode.len(shown), y, COLOR.cursor, "┃")
end

--------------------------------------------------------------------------------
-- Command context
--------------------------------------------------------------------------------

local CONTEXT = {}

function CONTEXT:out(value, color)   appendLine(value, color or COLOR.text) end
function CONTEXT:err(value)          appendLine(value, COLOR.error) end
function CONTEXT:warn(value)         appendLine(value, COLOR.warn) end
function CONTEXT:heading(value)      appendLine(value, COLOR.heading) end
function CONTEXT:ok(value)           appendLine(value, COLOR.ok) end
function CONTEXT:accent(value)       appendLine(value, COLOR.accent) end
function CONTEXT:dim(value)          appendLine(value, COLOR.dim) end
function CONTEXT:clear()             shell.clear() end
function CONTEXT:quit()              shell.terminate() end
function CONTEXT:redraw()            workspace:draw() end
function CONTEXT:isElevated()        return shell.elevated end
function CONTEXT:user()              return userName end
function CONTEXT:host()              return hostName end
function CONTEXT:cwd()               return shell.cwd end
function CONTEXT:setCwd(path)        shell.cwd = path end
function CONTEXT:shell()             return shell end
function CONTEXT:shorten(path)       return shortPath(path) end
function CONTEXT:userHome()          return paths.user.home end
function CONTEXT:colors()            return COLOR end

-- Resolves a path argument against the working directory, honouring ~.
function CONTEXT:resolve(p)
	if not p or p == "" then
		return shell.cwd
	elseif p == "~" then
		return paths.user.home
	elseif p:sub(1, 2) == "~/" then
		return filesystem.path(paths.user.home .. p:sub(3))
	elseif p:sub(1, 1) == "/" then
		return p
	end

	return filesystem.path(shell.cwd .. "/" .. p)
end

function CONTEXT:prompt(question)
	return COMMANDS.readLine(self, question)
end

function CONTEXT:columns()
	return display.width
end

-- Shows a transient line at the prompt (password entry) instead of the buffer.
function CONTEXT:setEphemeral(value)
	shell.ephemeral = value
	workspace:draw()
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

function CONTEXT:run(line)
	local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then return end

	appendLine(promptText() .. trimmed, COLOR.dim)

	local name, rest = trimmed:match("^(%S+)%s*(.*)$")
	if not name then return end

	local command = COMMANDS.commands[name] or COMMANDS.commands[name:lower()]
	if not command then
		self:err((localization.notFound or "tpkg: %s: command not found"):format(name))
		self:dim(localization.tryHelp or "Type 'help' for the command list.")
		return
	end

	local previousElevation = shell.elevated
	local ok, reason = pcall(command.run, self, COMMANDS.tokenize(rest), rest)

	shell.elevated = previousElevation

	if not ok then
		self:err((localization.failed or "error: %s"):format(tostring(reason)))
	end
end

--------------------------------------------------------------------------------
-- Tab completion over command names
--------------------------------------------------------------------------------

local function complete()
	local fragment = shell.input:match("(%S*)$") or ""
	local head = shell.input:sub(1, #shell.input - #fragment)

	local names = {}
	for name in pairs(COMMANDS.commands) do
		names[#names + 1] = name
	end
	table.sort(names)

	local matches = {}
	for _, name in ipairs(names) do
		if name:sub(1, #fragment) == fragment then
			matches[#matches + 1] = name
		end
	end

	if #matches == 1 then
		shell.input = head .. matches[1] .. " "
	elseif #matches > 1 then
		local prefix = matches[1]
		for i = 2, #matches do
			while #prefix > 0 and matches[i]:sub(1, #prefix) ~= prefix do
				prefix = prefix:sub(1, #prefix - 1)
			end
		end

		appendLine(table.concat(matches, "   "), COLOR.dim)
		shell.input = head .. prefix
	end
end

--------------------------------------------------------------------------------
-- Input handling
--------------------------------------------------------------------------------

local overrideWindowEventHandler = window.eventHandler

window.eventHandler = function(ws, win, ...)
	local e = {...}
	local handled = false

	if e[1] == "scroll" then
		local maximum = math.max(0, #shell.lines - visibleRows() + 1)
		shell.scrollOffset = math.max(0, math.min(maximum, shell.scrollOffset + (e[5] > 0 and -1 or 1)))
		handled = true

	elseif e[1] == "key_down" and ws.focusedObject == win then
		local code = e[4]

		if code == 28 then -- return
			shell.scrollOffset = 0
			shell.history[#shell.history + 1] = shell.input
			shell.historyIndex = #shell.history + 1

			CONTEXT:run(shell.input)
			shell.input, shell.ephemeral = "", nil
			handled = true

		elseif code == 14 then -- backspace
			shell.input = unicode.sub(shell.input, 1, -2)
			handled = true

		elseif code == 29 then -- ctrl+c abandons the line
			appendLine(promptText() .. shell.input .. "^C", COLOR.dim)
			shell.input = ""
			handled = true

		elseif code == 200 then -- history back
			if #shell.history > 0 then
				shell.historyIndex = math.max(1, shell.historyIndex - 1)
				shell.input = shell.history[shell.historyIndex]
			end
			handled = true

		elseif code == 208 then -- history forward
			if #shell.history > 0 then
				shell.historyIndex = math.min(#shell.history, shell.historyIndex + 1)
				shell.input = shell.history[shell.historyIndex] or ""
			end
			handled = true

		elseif code == 15 then -- tab
			complete()
			handled = true

		elseif code == 27 then -- escape clears the line
			shell.input = ""
			handled = true

		elseif not keyboard.isControl(e[3]) then
			if not shell.ephemeral then
				shell.input = shell.input .. unicode.char(e[3])
			end
			handled = true
		end
	end

	if handled then
		ws:draw()
	else
		overrideWindowEventHandler(ws, win, ...)
	end
end

window.onResize = function(newWidth, newHeight)
	window.backgroundPanel.width, window.backgroundPanel.height = newWidth, newHeight
	window.titleLabel.width = newWidth
	display.width, display.height = newWidth - 2, newHeight - 4
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

window.onResize(window.width, window.height)

appendLine(localization.banner or "TheanOS terminal -- type 'help' for commands.", COLOR.heading)
appendLine("")

workspace:draw()
