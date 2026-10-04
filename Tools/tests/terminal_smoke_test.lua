-- Smoke test for the terminal shell: boots it against stubs, types a line, and
-- checks the basics still work.
--
-- Run from the repository root:  lua5.3 Tools/tests/terminal_smoke_test.lua
--
-- This is deliberately small. The exhaustive pipeline/filter/diff suites lived in
-- /tmp and were lost; this exists so a change to Main.lua or Commands.lua cannot
-- silently stop the shell from booting at all.

local root = os.getenv("THEANOS_ROOT") or "."
package.path = root .. "/Libraries/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then
		pass = pass + 1
		print("  ok   " .. name)
	else
		fail = fail + 1
		print("  FAIL " .. name .. "  " .. tostring(extra))
	end
end

--------------------------------------------------------------------------------
-- Screen model
--------------------------------------------------------------------------------

local DRAWN = {}
local WINDOW

local function screen()
	return {
		getWidth = function() return 80 end,
		getHeight = function() return 25 end,
		clear = function() end,
		setColor = function() end,
		setForegroundColor = function() end,
		setBackgroundColor = function() end,
		drawText = function(x, y, _, text)
			DRAWN[#DRAWN + 1] = {x = x, y = y, text = text}
		end,
		drawRectangle = function() end,
		drawImage = function() end,
		rawSet = function() end,
		rawGet = function() return 0 end,
		getIndex = function() return 1 end,
		setDrawLimit = function() end,
		resetDrawLimit = function() end,
		invertColor = function() end,
	}
end

local function output()
	local rows = {}
	for i = 1, #DRAWN do
		local e = DRAWN[i]
		rows[e.y] = rows[e.y] or {}
		rows[e.y][#rows[e.y] + 1] = {x = e.x, text = e.text}
	end

	-- rows is sparse: the shell draws only the visible band, so iterate the keys
	local ys = {}
	for y in pairs(rows) do ys[#ys + 1] = y end
	table.sort(ys)

	local out = {}
	for _, y in ipairs(ys) do
		local parts = rows[y]
		table.sort(parts, function(a, b) return a.x < b.x end)
		local line = {}
		for _, p in ipairs(parts) do line[#line + 1] = p.text end
		out[#out + 1] = table.concat(line)
	end

	return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- Stubs
--------------------------------------------------------------------------------

local FILES = {["/Users/t/words.txt"] = "alpha\nbeta\ngamma\n"}

local FS = {}
function FS.path(p) return p:match("^(.+%/).") or "" end
function FS.removeSlashes(p) return (p:gsub("/+", "/")) end
function FS.exists(p) return FILES[p] ~= nil end
function FS.isDirectory(p) return p == "/Users/t/" or p == "/rom/" end
function FS.list(p)
	if p:sub(-1) ~= "/" then p = p .. "/" end
	local out = {}
	for f in pairs(FILES) do
		if f:sub(1, #p) == p and not f:sub(#p + 1):find("/") then out[#out + 1] = f:match("[^/]*$") end
	end
	table.sort(out)
	return out
end
function FS.size(p) return FILES[p] and #FILES[p] or 0 end
function FS.read(p) return FILES[p] end
function FS.readLines(p)
	local lines = {}
	for line in (FILES[p] or ""):gmatch("(.-)\n") do lines[#lines + 1] = line end
	return lines
end
function FS.write(p, ...)
	FILES[p] = table.concat({...})
	return true
end
function FS.writeTable(p, t)
	local function ser(v)
		if type(v) ~= "table" then return tostring(v) end
		local o = {}
		for i = 1, #v do o[i] = ser(v[i]) end
		for k in pairs(v) do
			if type(k) ~= "number" then o[#o + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) end
		end
		return "{" .. table.concat(o, ",") .. "}"
	end
	local o = {}
	for k, v in pairs(t) do o[#o + 1] = tostring(k) .. "=" .. ser(v) end
	FILES[p] = "return {" .. table.concat(o, ",") .. "}"
	return true
end
function FS.remove() return true end
function FS.copy() return true end
function FS.rename() return true end
function FS.makeDirectory() return true end
function FS.lastModified() return 0 end
function FS.mounts() local at = 0 return function() at = at + 1 if at <= 2 then return {proxy = true}, "/rom/" end end end
function FS.name(p) return p:match("[^/]+$") end
function FS.extension(p) return p:match("%.([^%.]+)$") end
function FS.hideExtension(p) return p end
function FS.isHidden() return false end
function FS.get() return setmetatable({}, {__index = FS}) end
function FS.getProxy() return nil end

local HANDLER

local event = {}
function event.addHandler(cb, ...) HANDLER = cb return {callback = cb} end
function event.removeHandler() HANDLER = nil end
function event.skip() end
function event.pull() end
function event.sleep() end
function event.interruptingFunction() end

local paths = {user = {home = "/Users/t/", applicationData = "/Users/t/Application data/"}}

local SYSTEM = {}
function SYSTEM.getLocalization() return {} end
function SYSTEM.getCurrentScript() return root .. "/Applications/Terminal.app/Main.lua" end
function SYSTEM.getUser() return "tester" end
function SYSTEM.getCurrentScriptLocalization() return {} end
function SYSTEM.getTemporaryPath() return "/tmp/" end
function SYSTEM.getLocalizationKeys() return {} end

-- Capture the window the shell builds so keys can be driven at it.
local capturedWindow
function SYSTEM.addWindow(w)
	local workspace = {draw = function() end, addChild = function(self, c) return c end}
	w.backgroundPanel = w.backgroundPanel or {width = w.width, height = w.height}
	w.children = w.children or {}
	-- the real GUI.window always has a handler; Main.lua wraps and calls it
	w.eventHandler = function() end
	capturedWindow = w
	return workspace, w
end

local NETWORK = {isOnline = function() return false end}

local uptime = 0
_G.computer = {
	uptime = function() uptime = uptime + 0.01 return uptime end,
	pullSignal = function() end,
	getArchitecture = function() return "Lua 5.3" end,
	energy = function() return 1 end,
	maxEnergy = function() return 1 end,
}
_G.term = {getKey = function() return nil end, setCursorPosition = function() end}
_G.unicode = {
	len = function(v) return #v end,
	wlen = function(v) return #v end,
	sub = function(v, a, b) return string.sub(v, a, b) end,
	char = function(c) return string.char(c) end,
	-- 28 is return, 15 tab, 27 escape; everything else is a printable character
	charInString = function(v) return tostring(v) end,
}
_G.keyboard = {isControl = function() return false end, isKeyDown = function() return false end}
_G.bit32 = {rshift = function(a, b) return a >> b end, band = function(a, b) return a & b end, bxor = function(a, b) return a ~ b end}

local realRequire = require
_G.require = function(n)
	if n == "Filesystem" then return FS end
	if n == "Keyboard" then return _G.keyboard end
	if n == "Event" then return event end
	if n == "Paths" then return paths end
	if n == "System" then return SYSTEM end
	if n == "Network" then return NETWORK end
	if n == "Screen" then return screen() end
	if n == "Internet" then
		return {request = function() return nil, "offline" end, download = function() return false end}
	end
	if n == "SHA-256" then return {hash = function(s) return "h" .. #s end} end
	return realRequire(n)
end

_G.UIRequire = function(name)
	local module = realRequire(name)
	if type(module) == "table" and module.useAPI then module.useAPI("GUI", screen()) end
	return module
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

print("== boot ==")
local ok, err = pcall(dofile, root .. "/Applications/Terminal.app/Main.lua")
check("shell loads without error", ok, err)
if not ok then os.exit(1) end

check("window captured", capturedWindow ~= nil)
check("key handler installed", capturedWindow and type(capturedWindow.eventHandler) == "function",
	capturedWindow and type(capturedWindow.eventHandler))

-- Main.lua ignores key events unless the window is focused. The real GUI.lua is
-- loaded here (not stubbed), so walking the tree is what actually reaches
-- screen.drawText and fills DRAWN.
local function drawTree(o)
	if not o then return end
	if type(o.draw) == "function" then pcall(o.draw, o) end
	for _, c in ipairs(o.children or {}) do drawTree(c) end
end

local WORKSPACE = {draw = function() drawTree(capturedWindow) end}
WORKSPACE.focusedObject = capturedWindow

local function typeLine(line)
	DRAWN = {}
	for i = 1, #line do
		capturedWindow.eventHandler(WORKSPACE, capturedWindow, "key_down", 0, line:byte(i), 0)
	end
	capturedWindow.eventHandler(WORKSPACE, capturedWindow, "key_down", 0, 0, 28) -- return
end

-- find() with a pattern would trip over "-" in these strings
local function shows(text) return output():find(text, 1, true) ~= nil end

print("== basic commands ==")
typeLine("echo hello")
check("echo works", shows("hello"))

typeLine("pwd")
check("pwd prints a prompt path", shows("/"), output())

typeLine("nosuchcommand")
check("unknown command is reported", shows("not found"))

print("== pipelines and redirection ==")
typeLine("echo piped | wc")
check("pipe into wc", shows("1 lines"), output())

-- the shell starts in /, so a relative redirect lands at the root
local OUT = "/out.txt"

typeLine("echo redirected > " .. OUT)
check("redirect creates the file", FILES[OUT] ~= nil, (function()
	local keys = {} for k in pairs(FILES) do keys[#keys+1] = k end table.sort(keys) return table.concat(keys, ", ") end)())
check("redirect wrote the text", tostring(FILES[OUT]):find("redirected", 1, true) ~= nil, tostring(FILES[OUT]))

typeLine("echo second >> " .. OUT)
check("append adds to the file", tostring(FILES[OUT]):find("second", 1, true) ~= nil, tostring(FILES[OUT]))
check("append keeps the first write", tostring(FILES[OUT]):find("redirected", 1, true) ~= nil, tostring(FILES[OUT]))

print("== variables and aliases ==")
typeLine("export MYVAR=abc123")
typeLine("echo $MYVAR")
check("exported variable expands", shows("abc123"), output())

typeLine("alias greet=echo hello-alias")
typeLine("greet")
check("alias expands", shows("hello-alias"), output())

print("== text tools ==")
FILES["/Users/t/a.txt"] = "one\ntwo\n"
FILES["/Users/t/b.txt"] = "one\nthree\n"
typeLine("diff /Users/t/a.txt /Users/t/b.txt")
check("diff reports a change", shows("-two"), output())

typeLine("grep two /Users/t/a.txt")
check("grep finds a line", shows("two"), output())

print("== persistence ==")
local state = FILES["/Users/t/Application data/Terminal/state.cfg"]
check("state file written", state ~= nil)
check("history recorded", state and state:find("echo hello", 1, true) ~= nil, tostring(state))
check("alias persisted", state and state:find("greet", 1, true) ~= nil, tostring(state))

print(("\n== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
