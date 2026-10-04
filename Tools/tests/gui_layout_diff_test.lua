-- Differential test for GUI.layoutUpdate and GUI's containerDraw positioning.
--
-- Loads the real GUI.lua twice -- once as it is now, once as it was before the
-- optimisation -- builds an identical tree of layouts in each, forces the update,
-- and compares every resulting coordinate and size.
--
-- This is what makes the localisation safe: the refactor only ever replaces
-- repeated table lookups with locals, so every number it produces must be
-- identical.
--
-- Run from the repository root:
--   lua5.3 Tools/tests/gui_layout_diff_test.lua [path-to-reference-GUI.lua]

local root = os.getenv("THEANOS_ROOT") or "."

-- The reference is the version of GUI.lua from before this optimisation. It can
-- be supplied three ways, in order of preference:
--   1. an explicit path (first command-line argument)
--   2. $THEANOS_GUI_REFERENCE
--   3. git HEAD, which is the pre-change file while the change is uncommitted
-- Anything else and the test skips rather than reporting a false failure.
local function resolveReference()
	if arg[1] then return arg[1] end
	if os.getenv("THEANOS_GUI_REFERENCE") then return os.getenv("THEANOS_GUI_REFERENCE") end

	local handle = io.popen("git -C \"" .. root .. "\" show HEAD:Libraries/GUI.lua 2>/dev/null")
	if not handle then return nil end

	local contents = handle:read("*a")
	handle:close()

	if not contents or contents == "" then return nil end

	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:write(contents)
	file:close()

	return path
end

local referencePath = resolveReference()

--------------------------------------------------------------------------------
-- Stubs, shared by both loads
--------------------------------------------------------------------------------

local function noop() end
local unicode = {
	len = function(s) return #s end,
	sub = function(s, i, j) return string.sub(s, i, j) end,
	wlen = function(s) return #s end,
	char = function(c) return string.char(c) end,
}
_G.unicode = unicode
_G.keyboard = {isControl = function() return false end, isKeyDown = function() return false end}
_G.bit32 = {rshift = function(a, b) return a >> b end, band = function(a, b) return a & b end}

local function colorRGBToInteger(r, g, b) return r << 16 | g << 8 | b end
local color = {
	RGBToInteger = colorRGBToInteger,
	integerToRGB = function(c) return c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF end,
	to8Bit = function() return 0 end,
	from8Bit = function(i) return 0 end,
	blend = function(a) return a end,
	transition = function(a) return a end,
}

local screenCalls = {drawLimit = 0, setLimit = 0}

-- Declared before the screen stubs below: a closure created above a local
-- declaration would capture the global, not this table.
local screenLimits = {1, 1, 80, 25}

local screen = {}
for _, name in ipairs({
	"clear", "setColor", "setForegroundColor", "setBackgroundColor", "drawRectangle",
	"drawImage", "rawSet", "setDrawLimit", "resetDrawLimit", "invertColor",
}) do screen[name] = noop end
screen.drawText = function() end
screen.rawGet = function() return 0 end
screen.getIndex = function() return 1 end
screen.getWidth = function() return 80 end
screen.getHeight = function() return 25 end
screen.getResolution = function() return 80, 25 end
screen.getDrawLimit = function()
	screenCalls.drawLimit = screenCalls.drawLimit + 1
	return screenLimits[1], screenLimits[2], screenLimits[3], screenLimits[4]
end

local event = {addHandler = function() return {} end, removeHandler = noop, skip = noop, pull = noop}
local filesystem = {
	path = function(p) return p:match("^(.+%/).") or "" end,
	removeSlashes = function(p) return (p:gsub("/+", "/")) end,
	isDirectory = function() return false end,
	exists = function() return false end,
	makeDirectory = noop,
	list = function() return {} end,
	size = function() return 0 end,
	lastModified = function() return 0 end,
	name = function(p) return p:match("[^/]+$") end,
	extension = function() return nil end,
	hideExtension = function(p) return p end,
	isHidden = function() return false end,
	get = function() return setmetatable({}, {__index = filesystem}) end,
	mounts = function() return function() end end,
	read = function() return nil end,
	write = noop,
	removeSlashesAlias = noop,
}

_G.component = {invoke = function() return nil end, list = function() return {} end, proxy = function() return noop end}

local Number = {}
function Number.round(v)
	local floor = math.floor(v)
	local fraction = v - floor
	if fraction >= 0.5 then return floor + 1 end
	return floor
end

local stubs = {
	Keyboard = _G.keyboard,
	Event = event,
	Color = color,
	Filesystem = filesystem,
	Screen = screen,
	Paths = {user = {home = "/Users/t/", applicationData = "/Users/t/AppData/"}, path = filesystem.path},
	Number = Number,
	Image = {load = function() return {1, 1, 0} end, new = function(w, h) return {w, h} end},
	Text = {wrap = function(s) return {s} end, encode = function(s) return s end},
	System = nil,
	Network = {isOnline = function() return false end},
}

local realRequire = require
local function stubbedRequire(n)
	if stubs[n] ~= nil then return stubs[n] end
	return realRequire(root .. "/Libraries/" .. n:gsub("%.", "/") .. ".lua")
end

local realLoadfile = loadfile
local function loadGUI(path)
	local env = {
		require = stubbedRequire,
		loadstring = load,
		setfenv = nil,
		_G = nil,
	}
	env._G = env
	env.string = string
	env.table = table
	env.math = math
	env.pairs, env.ipairs, env.type, env.tostring, env.tonumber, env.select = pairs, ipairs, type, tostring, tonumber, select
	env.unicode = unicode
	env.color = color
	env.screen = screen
	env.number = Number
	env.text = stubs.Text
	env.image = stubs.Image
	env.event = event
	env.keyboard = _G.keyboard
	env.filesystem = filesystem
	env.paths = stubs.Paths
	env.bit32 = _G.bit32

	local chunk = assert(loadfile(path, "t", env))
	return chunk()
end

--------------------------------------------------------------------------------
-- Layout scenarios
--------------------------------------------------------------------------------

-- Each scenario builds a tree and returns a flat description of everything the
-- optimiser could have perturbed.
local function buildAndMeasure(GUI, spec)
	local layout = GUI.layout(1, 1, spec.width, spec.height, spec.columns, spec.rows)

	-- Per-cell configuration. Without this every cell keeps the default
	-- direction, which left the DIRECTION_HORIZONTAL branch of layoutUpdate
	-- completely untested -- a mutation there passed silently.
	if spec.cellSetup then
		for row = 1, spec.rows do
			for column = 1, spec.columns do
				spec.cellSetup(layout.cells[row][column], row, column, GUI)
			end
		end
	end

	local children = {}
	for i = 1, spec.childCount do
		local child = GUI.object(1, 1, spec.childWidth or 5, spec.childHeight or 3)
		child.width = child.width + (i % 3) -- vary so aliasing bugs show up
		child.height = child.height + (i % 2)
		if spec.hideEvery and i % spec.hideEvery == 0 then child.hidden = true end
		layout:addChild(child)
		children[#children + 1] = child
	end

	-- draw() rather than update(): layoutDraw calls layoutUpdate and then
	-- containerDraw, so this covers the absolute-positioning code too. Calling
	-- update() alone left containerDraw untested.
	layout:draw()

	local out = {}
	for i, child in ipairs(children) do
		out[#out + 1] = ("child %d: x=%s y=%s w=%s h=%s localX=%s localY=%s")
			:format(i, tostring(child.x), tostring(child.y),
				tostring(child.width), tostring(child.height),
				tostring(child.localX), tostring(child.localY))
	end

	for row = 1, spec.rows do
		for column = 1, spec.columns do
			local cell = layout.cells[row][column]
			out[#out + 1] = ("cell %dx%d: x=%s y=%s cw=%s ch=%s")
				:format(row, column, tostring(cell.x), tostring(cell.y),
					tostring(cell.childrenWidth), tostring(cell.childrenHeight))
		end
	end

	for i, size in ipairs(layout.columnSizes) do
		out[#out + 1] = ("column %d: calculatedSize=%s"):format(i, tostring(size.calculatedSize))
	end

	for i, size in ipairs(layout.rowSizes) do
		out[#out + 1] = ("row %d: calculatedSize=%s"):format(i, tostring(size.calculatedSize))
	end

	return table.concat(out, "\n")
end

local function horizontalCells(cell, row, _, GUI)
	cell.direction = GUI.DIRECTION_HORIZONTAL
	cell.spacing = row % 3
end

local function verticalCells(cell, _, column, GUI)
	cell.direction = GUI.DIRECTION_VERTICAL
	cell.spacing = column % 2
end

local function mixedCells(cell, row, column, GUI)
	cell.direction = (row + column) % 2 == 0 and GUI.DIRECTION_HORIZONTAL or GUI.DIRECTION_VERTICAL
	cell.spacing = (row * column) % 4
end

local function fittingCells(cell, row, column, GUI)
	cell.direction = (row + column) % 2 == 0 and GUI.DIRECTION_HORIZONTAL or GUI.DIRECTION_VERTICAL
	cell.spacing = 1
	cell.horizontalFitting, cell.verticalFitting = row % 2 == 1, column % 2 == 1
	cell.horizontalFittingRemove, cell.verticalFittingRemove = row % 3, column % 3
end

local function marginCells(cell, row, column, GUI)
	cell.direction = GUI.DIRECTION_VERTICAL
	cell.horizontalMargin = (row % 3) - 1
	cell.verticalMargin = (column % 3) - 1
	cell.horizontalAlignment = GUI.ALIGNMENT_HORIZONTAL_CENTER
	cell.verticalAlignment = GUI.ALIGNMENT_VERTICAL_BOTTOM
end

local SPECS = {
	-- defaults
	{width = 80, height = 25, columns = 1, rows = 1, childCount = 1},
	{width = 80, height = 25, columns = 1, rows = 1, childCount = 25},
	{width = 80, height = 25, columns = 1, rows = 5, childCount = 40},
	{width = 80, height = 25, columns = 4, rows = 1, childCount = 30},
	{width = 80, height = 25, columns = 3, rows = 3, childCount = 50},
	{width = 82, height = 26, columns = 7, rows = 4, childCount = 60},
	{width = 40, height = 12, columns = 2, rows = 2, childCount = 0},
	{width = 200, height = 50, columns = 5, rows = 5, childCount = 100},
	{width = 80, height = 25, columns = 1, rows = 1, childCount = 10, childWidth = 13, childHeight = 7},

	-- every cell horizontal: exercises the DIRECTION_HORIZONTAL branch
	{width = 80, height = 25, columns = 1, rows = 4, childCount = 30, cellSetup = horizontalCells},
	{width = 80, height = 25, columns = 6, rows = 2, childCount = 45, cellSetup = horizontalCells},

	-- every cell vertical: exercises the other branch
	{width = 80, height = 25, columns = 1, rows = 4, childCount = 30, cellSetup = verticalCells},
	{width = 80, height = 25, columns = 2, rows = 5, childCount = 55, cellSetup = verticalCells},

	-- mixed, so row/column hoisting bugs cannot cancel out
	{width = 80, height = 25, columns = 3, rows = 3, childCount = 50, cellSetup = mixedCells},
	{width = 120, height = 40, columns = 8, rows = 5, childCount = 90, cellSetup = mixedCells},

	-- auto-fitting: width/height are recomputed from the cell. The odd sizes are
	-- deliberate -- with an integral calculatedSize, number.round and math.floor
	-- agree, so an integral-only fixture cannot tell them apart.
	{width = 80, height = 25, columns = 4, rows = 3, childCount = 40, cellSetup = fittingCells},
	{width = 100, height = 30, columns = 5, rows = 5, childCount = 70, cellSetup = fittingCells},
	{width = 82, height = 25, columns = 3, rows = 3, childCount = 30, cellSetup = fittingCells},
	{width = 101, height = 37, columns = 7, rows = 4, childCount = 60, cellSetup = fittingCells},
	{width = 79, height = 23, columns = 6, rows = 3, childCount = 45, cellSetup = fittingCells},

	-- margins and non-default alignment
	{width = 80, height = 25, columns = 3, rows = 3, childCount = 30, cellSetup = marginCells},

	-- hidden children must be skipped by every loop
	{width = 80, height = 25, columns = 3, rows = 3, childCount = 40, hideEvery = 2, cellSetup = mixedCells},
	{width = 80, height = 25, columns = 2, rows = 2, childCount = 30, hideEvery = 3},
	{width = 80, height = 25, columns = 1, rows = 1, childCount = 20, hideEvery = 1, cellSetup = horizontalCells},
}

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

if not referencePath or not io.open(referencePath) then
	print("SKIP: no reference GUI.lua available.")
	print("  pass one as the first argument, set THEANOS_GUI_REFERENCE, or run inside a git checkout")
	os.exit(0)
end

local GUInew = loadGUI(root .. "/Libraries/GUI.lua")
local GUIold = loadGUI(referencePath)

local pass, fail = 0, 0
for i, spec in ipairs(SPECS) do
	local okA, resultA = pcall(buildAndMeasure, GUInew, spec)
	local okB, resultB = pcall(buildAndMeasure, GUIold, spec)

	if okA ~= okB then
		fail = fail + 1
		print(("  FAIL spec %d: error mismatch new=%s old=%s"):format(i, tostring(resultA), tostring(resultB)))
	elseif not okA then
		fail = fail + 1
		print(("  FAIL spec %d: both errored: %s"):format(i, tostring(resultA)))
	elseif resultA ~= resultB then
		fail = fail + 1
		print("  FAIL spec " .. i .. " (" .. spec.columns .. "x" .. spec.rows ..
			", " .. spec.childCount .. " children)")
		-- report the first differing line to make diagnosis quick
		local function lines(text)
			local out = {}
			for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
			return out
		end

		local diffA, diffB = lines(resultA), lines(resultB)
		for n = 1, math.max(#diffA, #diffB) do
			if diffA[n] ~= diffB[n] then
				print("       first difference at line " .. n)
				print("       new: " .. tostring(diffA[n]))
				print("       old: " .. tostring(diffB[n]))
				break
			end
		end
	else
		pass = pass + 1
	end
end

print(("compared %d layout scenarios"):format(#SPECS))
print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)