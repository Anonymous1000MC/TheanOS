
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
local COMMANDS = assert(loadfile(currentScriptDirectory .. "Commands.lua"))(
	strings, COLOR, currentScriptDirectory .. "Modules/"
)

--------------------------------------------------------------------------------
-- Persistent state: history, aliases, environment
--
-- Kept in the user's own application data so it survives reboots and is per-user.
--------------------------------------------------------------------------------

local statePath = paths.user.applicationData .. "Terminal/"

local function loadState()
	local state = {}

	if filesystem.exists(statePath .. "state.cfg") then
		local ok, data = pcall(filesystem.readTable, statePath .. "state.cfg")
		if ok and type(data) == "table" then state = data end
	end

	state.history = type(state.history) == "table" and state.history or {}
	state.aliases = type(state.aliases) == "table" and state.aliases or {}
	state.environment = type(state.environment) == "table" and state.environment or {}
	state.tldr = type(state.tldr) == "table" and state.tldr or {}

	return state
end

local state = loadState()

local function saveState()
	filesystem.makeDirectory(statePath)
	filesystem.writeTable(statePath .. "state.cfg", {
		history = state.history,
		aliases = state.aliases,
		environment = state.environment,
		tldr = state.tldr,
	}, true)
end

-- Reads aliases and environment from ~/.theanrc. Intentionally a tiny format:
--   alias name=value
--   export NAME=value
-- Anything unrecognised is ignored rather than being a syntax error.
local function loadRC()
	local path = paths.user.home .. ".theanrc"

	local content = filesystem.read(path)
	if not content then return end

	local aliases, environment = {}, {}

	for line in (content .. "\n"):gmatch("(.-)\n") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")

		local name, value = line:match("^alias%s+([%w_%-]+)%s*=%s*(.+)$")
		if name then
			aliases[name] = value:gsub("^%\"(.*)\"$", "%1")
		end

		-- `value` above belongs to the alias match, which did not fire here, so
		-- the export value has to be captured in its own match.
		local exported, exportedValue = line:match("^export%s+([%w_]+)%s*=%s*(.+)$")
		if exported then
			environment[exported] = exportedValue:gsub("^%\"(.*)\"$", "%1")
		end
	end

	-- Command line wins over the rc file, which wins over the defaults.
	for name, value in pairs(aliases) do
		if state.aliases[name] == nil then state.aliases[name] = value end
	end

	for name, value in pairs(environment) do
		if state.environment[name] == nil then state.environment[name] = value end
	end
end

loadRC()

local MAX_HISTORY = 200

-- Let the command modules share this state, so `alias` / `export` / `tldr`
-- mutate exactly what the shell reads.
COMMANDS.state = state
COMMANDS.saveState = saveState

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
	value = tostring(value):gsub("\r", "")

	for line in (value .. "\n"):gmatch("(.-)\n") do
		shell.lines[#shell.lines + 1] = {text = line, color = color or COLOR.text}
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
--
-- A line is a sequence of stages joined by |, with optional redirection and && / ;
-- Each stage runs to completion and its stdout becomes the next stage's stdin.
-- Nothing streams: output is collected per stage, which is the right trade here
-- because the VM is cooperative and only one stage can run at a time anyway.
--------------------------------------------------------------------------------

local OPERATORS = {["|"] = true, [">"] = true, [">>"] = true, ["&&"] = true, [";"] = true}

-- Expands $NAME and ${NAME} from the shell environment.
local function expand(tokens, environment)
	local out = {}

	for i = 1, #tokens do
		local token = tokens[i]
		local pieces, cursor, matched = {}, 1, false

		while cursor <= #token do
			local dollar = token:find("%$", cursor)
			if not dollar or dollar == #token then break end

			pieces[#pieces + 1] = token:sub(cursor, dollar - 1)

			local braced = token:match("^${([%w_]+)}", dollar)
			local bare = braced or token:match("^%$([%w_]+)", dollar)

			if bare then
				pieces[#pieces + 1] = tostring(environment[bare] or "")
				cursor = dollar + (braced and (#bare + 2) or (#bare + 1))
				matched = true
			else
				pieces[#pieces + 1] = "$"
				cursor = dollar + 1
			end
		end

		if not matched then
			out[#out + 1] = token
		else
			pieces[#pieces + 1] = token:sub(cursor)
			out[#out + 1] = table.concat(pieces)
		end
	end

	return out
end

-- Runs one stage. With `capture` set, anything it prints is collected for the
-- next stage instead of going to the screen.
local function runStage(context, argv, stdin, capture)
	local captured = {}

	local stageContext = capture and setmetatable({}, {__index = context}) or context

	if capture then
		function stageContext:out(value)
			captured[#captured + 1] = tostring(value)
		end
	end

	if stdin then
		-- Expose the previous stage's output so filters like cat/sort/grep can
		-- read a pipe instead of a file. It must NOT also go into `captured`,
		-- which is what this stage RETURNS: seeding it made every capturing stage
		-- emit its own input, so `cat f | grep x > out` wrote the file plus the
		-- matches instead of just the matches.
		stageContext.stdin = stdin
	end

	local name = argv[1]
	local command = name and (COMMANDS.commands[name] or COMMANDS.commands[name:lower()])

	if not command then
		context:err((strings.notFound or "%s: command not found"):format(tostring(name)))
		return false, nil
	end

	local previousCwd = shell.cwd
	local previousElevation = shell.elevated
	local ok, reason = pcall(command.run, stageContext, COMMANDS.tokenize(table.concat(argv, " ", 2)), table.concat(argv, " ", 2))

	-- A stage must not leave the shell pointed somewhere else, or `a | cd /x` would
	-- silently change the directory for everything after it.
	if shell.cwd ~= previousCwd then shell.cwd = previousCwd end
	shell.elevated = previousElevation

	if not ok then
		context:err((strings.failed or "error: %s"):format(tostring(reason)))
		return false, nil
	end

	return true, table.concat(captured, "\n")
end

function CONTEXT:run(line, noEcho)
	local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then return true end

	if not noEcho then
		appendLine(promptText() .. trimmed, COLOR.dim)
	end

	-- Split into stages, keeping the operator that follows each one. A redirect
	-- target is a stage of its own, so `> out.txt` lands in segments too.
	local segments, operators = {}, {}
	local current = {}

	for _, token in ipairs(COMMANDS.tokenize(trimmed)) do
		if OPERATORS[token] then
			if #current > 0 then
				segments[#segments + 1] = current
				current = {}
			end

			operators[#operators + 1] = token
		else
			current[#current + 1] = token
		end
	end

	if #current > 0 then segments[#segments + 1] = current end
	if #segments == 0 then return true end

	local environment = {
		USER = userName, HOME = paths.user.home, PWD = shell.cwd,
		SHELL = "/TheanOS", TERM = "theanos-tty",
	}

	-- ~/.theanrc and saved exports, with the live values taking precedence.
	for name, value in pairs(state.environment) do
		environment[name] = value
	end

	environment.PWD = shell.cwd
	environment.HOME = paths.user.home
	environment.USER = userName

	-- Aliases are expanded once, before splitting, so an alias may itself
	-- contain pipes or redirects.
	if state.aliases[segments[1][1]] then
		local expanded = state.aliases[segments[1][1]] .. " " .. table.concat(segments[1], " ", 2)

		return self:run(expanded, true)
	end

	-- operators[i] is the operator that FOLLOWS segment i, so a redirect consumes
	-- the segment after it as its target. Getting this backwards made `echo hi > f`
	-- treat the command itself as the redirect target and try to run `f`.
	local carried, ok, index = nil, true, 1

	while index <= #segments do
		local operator = operators[index]
		local nextOperator = operators[index + 1]

		-- A stage must capture when it feeds another stage or feeds a redirect.
		local capturing = operator == "|" or operator == ">" or operator == ">>"
			or nextOperator == ">" or nextOperator == ">>"

		if operator == "&&" and not ok then
			return false
		end

		-- This stage is fed by a pipe when the PREVIOUS operator was one. Testing
		-- its own operator instead meant `cat x | grep a > out` gave grep no stdin,
		-- because grep's operator is the redirect, not the pipe.
		local fedByPipe = operators[index - 1] == "|"

		local argv = expand(segments[index], environment)
		ok, carried = runStage(self, argv, fedByPipe and carried or nil, capturing)

		if operator == "|" then
			carried = carried or ""
		elseif operator == ">" or operator == ">>" then
			local target = expand(segments[index + 1] or {}, environment)[1]

			if target and target ~= "" then
				local path = self:resolve(target)
				local previous = (operator == ">>") and filesystem.read(path) or nil
				local body = (carried or "") .. "\n"

				filesystem.write(path, previous and (previous .. body) or body)
			end

			carried = nil
			index = index + 1
		end

		-- A failed stage ends the chain unless the user asked to carry on.
		if not ok and (operator == "|" or operator == "&&") then
			return false
		end

		index = index + 1
		environment.PWD = shell.cwd
	end

	return ok
end

--------------------------------------------------------------------------------
-- Tab completion
--
-- First token completes command names; later tokens complete paths, and expand a
-- partial "~" into the home directory first.
--------------------------------------------------------------------------------

local function pathMatches(fragment)
	local resolved, prefix = fragment, ""

	if fragment:sub(1, 1) == "~" then
		prefix = "~"
		resolved = paths.user.home .. fragment:sub(2)
	end

	local parent, leaf = resolved:match("^(.*/)([^/]*)$")
	if not parent then
		parent, leaf = "", resolved
	end

	if parent == "" then parent = shell.cwd end
	parent = filesystem.path(parent)

	if not filesystem.exists(parent) or not filesystem.isDirectory(parent) then
		return {}
	end

	local matches = {}
	for _, name in ipairs(filesystem.list(parent) or {}) do
		if name:sub(1, #leaf) == leaf then
			local suffix = filesystem.isDirectory(parent .. name) and "/" or ""
			matches[#matches + 1] = prefix .. (resolved:match("^(.*/)") or "") .. name .. suffix
		end
	end

	return matches
end

local function complete()
	local before = shell.input:match("^(.*%S)%s(%S*)$")
	local fragment = shell.input:match("%s(%S*)$")

	-- No trailing token: completing the word already being typed.
	if not before or not fragment then
		fragment = shell.input:match("(%S*)$") or ""
		before = shell.input:sub(1, #shell.input - #fragment)
	end

	local matches

	-- First word on the line: a command name.
	if before == "" or before:match("[|;&<]%s*$") then
		local names = {}
		for name in pairs(COMMANDS.commands) do names[#names + 1] = name end
		for name in pairs(state.aliases) do names[#names + 1] = name end
		table.sort(names)

		matches = {}
		for _, name in ipairs(names) do
			if name:sub(1, #fragment) == fragment then matches[#matches + 1] = name end
		end
	else
		matches = pathMatches(fragment)
	end

	if #matches == 0 then
		return
	elseif #matches == 1 then
		-- Leave a trailing space only when it is a real file, not a directory
		-- being continued.
		local chosen = matches[1]
		if chosen:sub(-1) == "/" then
			shell.input = before .. chosen
		else
			shell.input = before .. chosen .. " "
		end
	else
		local prefix = matches[1]
		for i = 2, #matches do
			while #prefix > 0 and matches[i]:sub(1, #prefix) ~= prefix do
				prefix = prefix:sub(1, #prefix - 1)
			end
		end

		if #prefix > #fragment then
			shell.input = before .. prefix
		end

		-- Offer completions in columns; the path may be long.
		local width = display.width - 1
		local column = math.max(10, math.floor(width / 3))
		local row = {}

		for i = 1, #matches do
			local name = matches[i]:match("[^/]*$")
			row[#row + 1] = ("%-*" .. column):format(name)

			if i % 3 == 0 or i == #matches then
				appendLine(table.concat(row):gsub("%s+$", ""), COLOR.dim)
				row = {}
			end
		end
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
			-- Skip repeats of the same entry, like a real shell does.
			if state.history[#state.history] ~= shell.input then
				state.history[#state.history + 1] = shell.input
			end

			while #state.history > MAX_HISTORY do
				table.remove(state.history, 1)
			end

			shell.historyIndex = #state.history + 1
			saveState()

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
