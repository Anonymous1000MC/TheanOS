
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

-- system.getLocalization tags every key it does not have as "$" .. key, so a
-- plain `localization.x or "fallback"` never actually falls back -- it renders
-- "$x". Read through this view instead, which hides the sentinel.
local function localizationValue(key)
	local value = localization[key]

	if type(value) ~= "string" or value == "$" .. key then
		return nil
	end

	return value
end

-- __index is called as (table, key), so the lookup takes both.
local strings = setmetatable({}, {__index = function(_, key)
	return localizationValue(key)
end})

-- Passed as varargs: Commands.lua binds them at load time, so assigning them
-- after the call would be too late.
local COMMANDS = assert(loadfile(currentScriptDirectory .. "Commands.lua"))(strings, COLOR)

--------------------------------------------------------------------------------
-- Shell state
--------------------------------------------------------------------------------

-- Declared up front because appendLine advances it to follow new output.
local lineFrom = 1

local shell = {
	cwd = "/",
	lines = {},
	input = "",
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
	GUI.label(1, 1, window.width, 1, COLOR.dim, " " .. (strings.terminal or "Terminal"))
):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)

window.actionButtons.localY = 1

local display = window:addChild(GUI.object(2, 4, 1, 1))

--------------------------------------------------------------------------------
-- Output helpers
--------------------------------------------------------------------------------

-- Rows available for output. One row is reserved for the prompt.
local function visibleRows()
	return math.max(1, display.height - 1)
end

-- Keeps the newest line inside the viewport by advancing lineFrom, and caps the
-- scrollback so a chatty command cannot exhaust memory on a small computer.
local MAX_SCROLLBACK = 1500

local function trimScrollback()
	local excess = #shell.lines - MAX_SCROLLBACK

	if excess > 0 then
		for i = 1, excess do
			shell.lines[i] = nil
		end

		lineFrom = math.max(1, lineFrom - excess)
		shell.scrollOffset = math.max(0, shell.scrollOffset - excess)
	end
end

local function appendLine(value, color)
	local wrapped = text.wrap(tostring(value), display.width)

	for i = 1, #wrapped do
		shell.lines[#shell.lines + 1] = {text = wrapped[i], color = color or COLOR.text}
	end

	-- follow the tail unless the user has scrolled back
	if shell.scrollOffset == 0 then
		local overflow = #shell.lines - lineFrom + 1 - visibleRows()
		if overflow > 0 then
			lineFrom = lineFrom + overflow
		end
	end

	trimScrollback()
end

-- Appends without wrapping. text.wrap() word-splits on whitespace and strips
-- leading/trailing spaces, which destroys any column-aligned output such as the
-- fastfetch logo.
local function appendRawLine(value, color)
	local lines = tostring(value):gsub("\r", ""):gsub("\n", " \n ")

	for piece in lines:gmatch("(.-) \n ") do
		shell.lines[#shell.lines + 1] = {text = piece, color = color or COLOR.text}
	end
end

function shell.out(value, color)
	appendLine(value, color)
end

function shell.raw(value, color)
	appendRawLine(value, color)
end

function shell.err(value)
	appendLine(value, COLOR.error)
end

function shell.warn(value)
	appendLine(value, COLOR.warn)
end

function shell.clear()
	shell.lines, shell.scrollOffset = {}, 0
	lineFrom = 1
end

function shell.terminate()
	window:remove()
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

	local first = math.max(1, math.min(lineFrom, #shell.lines + 1)) - shell.scrollOffset
	local last = math.min(#shell.lines, first + visibleRows() - 1)

	for i = math.max(1, first), last do
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
function CONTEXT:raw(value, color) appendRawLine(value, color) end
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
		self:err((strings.notFound or "tpkg: %s: command not found"):format(name))
		self:dim(strings.tryHelp or "Type 'help' for the command list.")
		return
	end

	local previousElevation = shell.elevated
	local ok, reason = pcall(command.run, self, COMMANDS.tokenize(rest), rest)

	shell.elevated = previousElevation

	if not ok then
		self:err((strings.failed or "error: %s"):format(tostring(reason)))
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

		-- Returning to the bottom re-anchors on the newest line, because output
		-- produced while scrolled up left lineFrom where it was.
		if shell.scrollOffset == 0 then
			lineFrom = math.max(1, #shell.lines - visibleRows() + 1)
		end

		handled = true

	elseif e[1] == "key_down" and ws.focusedObject == win then
		local code = e[4]

		if code == 28 then -- return
			shell.scrollOffset = 0
			lineFrom = math.max(1, #shell.lines - visibleRows() + 2)
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

appendLine(strings.banner or "TheanOS terminal -- type 'help' for commands.", COLOR.heading)
appendLine("")

workspace:draw()
