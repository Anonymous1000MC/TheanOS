-- Loads Monitor against the REAL GUI library and measures where every child
-- actually lands.
--
-- This replaces an earlier version of this test that scraped child counts out of
-- the source text. That version was wrong: it forgot that MineOS puts
-- cell.spacing between each pair of stacked children, so it under-counted the
-- content by 13 rows and passed a window that was 13 rows too short. Measuring
-- the real layout cannot go wrong that way.
--
-- Run from the repository root:  lua5.3 Tools/tests/monitor_layout_test.lua

local rootPath = os.getenv("THEANOS_ROOT") or "."

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
-- Minimal stubs for Monitor's dependencies. GUI itself is the real library.
--------------------------------------------------------------------------------

local unicode = {
	len = function(s) return #s end, sub = function(s, i, j) return string.sub(s, i, j) end,
	wlen = function(s) return #s end, char = function(c) return string.char(c) end,
}
_G.unicode = unicode
_G.keyboard = {isControl = function() return false end, isKeyDown = function() return false end}
_G.bit32 = {rshift = function(a, b) return a >> b end, band = function(a, b) return a & b end}
_G.component = {invoke = function() return nil end, list = function() return {} end, proxy = function() return noop end}

local drawnText = {}
local screen = {}
for _, name in ipairs({"clear", "setColor", "setForegroundColor", "setBackgroundColor",
	"drawRectangle", "drawImage", "rawSet", "resetDrawLimit", "invertColor", "drawSemiPixelRectangle"}) do
	screen[name] = function() end
end
screen.drawText = function(x, y, _, text) drawnText[#drawnText + 1] = {x = x, y = y, text = text} end
screen.rawGet = function() return 0 end
screen.getIndex = function() return 1 end
screen.getWidth = function() return 160 end
screen.getHeight = function() return 50 end
screen.getResolution = function() return 160, 50 end
screen.getDrawLimit = function() return 1, 1, 160, 50 end
screen.setDrawLimit = function() end

local color = {
	RGBToInteger = function(r, g, b) return r << 16 | g << 8 | b end,
	integerToRGB = function(c) return c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF end,
	to8Bit = function() return 0 end, from8Bit = function() return 0 end,
	blend = function(a) return a end, transition = function(a) return a end,
}

local event = {addHandler = function() return {} end, removeHandler = function() end, skip = function() end, pull = function() end}
local FILES, DIR = {}, {}
local filesystem = {
	path = function(p) return p:match("^(.+%/).") or "" end,
	removeSlashes = function(p) return (p:gsub("/+", "/")) end,
	getCurrentScript = function() return "/Applications/Monitor.app/Main.lua" end,
	exists = function(p) return FILES[p] ~= nil end,
	isDirectory = function(p) return DIR[p] == true end,
	list = function(p) return {} end,
	size = function() return 0 end,
	lastModified = function() return 0 end,
	name = function(p) return p:match("[^/]+$") end,
	extension = function() end,
	hideExtension = function(p) return p end,
	isHidden = function() return false end,
	makeDirectory = function() end,
	mounts = function() local at = 0 return function() at = at + 1 if at <= 3 then return {}, "/m" .. at end end end,
	get = function() return setmetatable({}, {__index = filesystem}) end,
	read = function() return nil end,
	write = function() end,
	readTable = function() return nil end,
}

local Number = {}
function Number.round(v) return v >= 0 and math.floor(v + 0.5) or math.ceil(v - 0.5) end
function Number.shorten() return "999" end

local realRequire = require
local function libRequire(name)
	local path = rootPath .. "/Libraries/" .. name .. ".lua"
	return assert(loadfile(path, "t", _G))()
end

local captured
local system = {}
function system.getLocalization() return {} end
function system.getCurrentScript() return "/Applications/Monitor.app/Main.lua" end
function system.addWindow(w)
	w.backgroundPanel = {width = w.width, height = w.height}
	w.actionButtons = {close = {onTouch = function() end}, minimize = {}, maximize = {}}
	captured = w
	return {draw = function() end, addChild = function(self, c) return c end}, w
end

_G.require = function(name)
	if name == "GUI" then return libRequire("GUI") end
	if name == "System" then return system end
	if name == "Event" then return event end
	if name == "Filesystem" then return filesystem end
	if name == "Paths" then
		return {user = {home = "/Users/t/", applicationData = "/Users/t/AppData/"}, path = filesystem.path}
	end
	if name == "Keyboard" then return _G.keyboard end
	if name == "Color" then return color end
	if name == "Screen" then return screen end
	if name == "Number" then return Number end
	if name == "Text" then return {wrap = function(s) return {s} end} end
	if name == "Image" then return {load = function() return {8, 4} end} end
	return realRequire(rootPath .. "/Libraries/" .. name .. ".lua")
end

_G.computer = {
	uptime = function() return 1 end, pullSignal = function() end,
	getArchitecture = function() return "Lua 5.3" end,
	energy = function() return 1 end, maxEnergy = function() return 1 end,
	totalMemory = function() return 65536 end,
}

local ok, err = pcall(dofile, rootPath .. "/Applications/Monitor.app/Main.lua")
if not ok then
	print("load failed: " .. tostring(err))
	os.exit(1)
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

local window = captured
print(("== window: %d x %d"):format(window.width, window.height))
print(("   window.children = %s, layout = %s")
	:format(tostring(window.children and #window.children), tostring(window.children and window.children[1])))

-- the real GUI.window has its own children (panel, action buttons); the layout is
-- whichever child actually holds the app's widgets
local layout
for _, child in ipairs(window.children) do
	if type(child.children) == "table" and #child.children > 5 then layout = child break end
end
check("layout found among the window's children", layout ~= nil)
if layout then
	print(("   layout.children = %d"):format(#layout.children))
end

print()
print("== children, in layout order (localY outside 1..height means clipped) ==")
print(("   %-3s %-22s %5s %5s %6s %6s %6s"):format("#", "kind", "w", "h", "localX", "localY", "absY"))
local totalBottom = 0
for i, child in ipairs(layout.children) do
	local kind = child.text and ("text:" .. tostring(child.text):sub(1, 18))
		or (child.key and ("key:" .. tostring(child.key))
		or (child.values and "chart" or "object"))

	local absY = child.y or (layout.y + child.localY - 1)
	local bottom = absY + (child.height or 1) - 1
	if bottom > totalBottom then totalBottom = bottom end

	print(("   %-3d %-22s %5s %5s %6s %6s %6s")
		:format(i, kind:sub(1, 22), tostring(child.width), tostring(child.height),
			tostring(child.localX), tostring(child.localY), tostring(absY)))
end

print()
print(("== lowest child bottom: %d, window bottom: %d"):format(totalBottom, window.height))
check("all children fit inside the window vertically", totalBottom <= window.height,
	("content reaches row %d, window is %d"):format(totalBottom, window.height))

-- Anything positioned above the window top is invisible.
local highest = math.huge
for _, child in ipairs(layout.children) do
	local absY = child.y or (layout.y + child.localY - 1)
	if absY < highest then highest = absY end
end
print(("== highest child top: %d, window top: %d"):format(highest, window.y))
check("no child starts above the window", highest >= window.y,
	("child at row %d, window starts at %d"):format(highest, window.y))

-- Width, measured rather than guessed: keyAndValue centres itself in the cell,
-- so a long key plus a long value overflows symmetrically rather than only right.
local widest = 0
local widestChild = ""
for _, child in ipairs(layout.children) do
	local right = (child.localX or 1) + (child.width or 1) - 1
	if right > widest then
		widest = right
		widestChild = tostring(child.key or child.text or "chart")
	end
end
print(("== widest child right edge: %d (%s), window width: %d")
	:format(widest, widestChild, window.width))
check("no child overflows the window horizontally", widest <= window.width,
	("%s reaches column %d of %d"):format(widestChild, widest, window.width))

-- Measuring laid-out geometry is not enough: a too-narrow window simply shrinks
-- everything to fit, so the geometry check still passes while the text no longer
-- fits its allotment. Check the text itself against the space available.
local cellWidth = layout.width - 2
local tooNarrow = {}
for _, child in ipairs(layout.children) do
	if child.key ~= nil then
		local needed = #(child.key or "") + #(child.value or "")
		if needed > cellWidth then
			tooNarrow[#tooNarrow + 1] = ("%s+%s needs %d of %d")
				:format(child.key, child.value, needed, cellWidth)
		end
	elseif child.text ~= nil and child.values == nil then
		local needed = #child.text
		if needed > (child.width or 0) then
			tooNarrow[#tooNarrow + 1] = ("\"%s\" needs %d of %d")
				:format(child.text:sub(1, 20), needed, child.width)
		end
	end
end
check("every row's text fits the window width", #tooNarrow == 0, table.concat(tooNarrow, "; "))

-- The button is declared with width 0, which renders nothing at all.
local button
for _, child in ipairs(layout.children) do
	if type(child.text) == "string" and child.text:find("Measure") then button = child end
end
check("the Measure button exists", button ~= nil)
check("the Measure button has a real width", button and (button.width or 0) > 0,
	button and button.width)

print()
print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)