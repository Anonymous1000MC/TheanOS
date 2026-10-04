-- Runs Applications/Monitor.app/Main.lua against GUI/event stubs, then drives
-- the periodic handler to check the app behaves and cleans up after itself.
--
-- The stub signatures below are transcribed from Libraries/GUI.lua on purpose.
-- An earlier stub used GUI.label(x, y, color, text), which silently accepted a
-- 4-argument call and let a string reach the real .height field, which panicked
-- the kernel at GUI.lua:1684. addChild now refuses non-numeric geometry so that
-- class of mistake fails here instead of on a computer.

-- Run from the repository root:  lua5.3 Tools/tests/monitor_test.lua
local rootPath = os.getenv("THEANOS_ROOT") or "."
local root = rootPath
package.path = rootPath .. "/Libraries/?.lua;" .. package.path

CHART_ARGS = {}

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
-- GUI stubs (signatures from Libraries/GUI.lua)
--------------------------------------------------------------------------------

local drawn, windowDrawn = 0, 0
local workspace = {draw = function() drawn = drawn + 1 end}

local function object(x, y, w, h)
	return {x = x, y = y, width = w, height = h, children = {}, color = 0}
end

local GUI = {}

function GUI.object(x, y, w, h)
	local o = object(x, y, w, h)
	function o:addChild(child)
		-- The real layout does math.max(childrenHeight, child.height); a string
		-- there is the exact panic that shipped.
		if type(child.width) ~= "number" then
			error("child width is " .. type(child.width) .. ": " .. tostring(child.width), 2)
		end
		if type(child.height) ~= "number" then
			error("child height is " .. type(child.height) .. ": " .. tostring(child.height), 2)
		end
		child.y = self.y
		self.children[#self.children + 1] = child
		child.parent = self
		self.height = self.height + 1
		return child
	end
	function o:remove() self.removed = true end
	function o:update() end
	function o:moveToFront() end
	o.setAlignment = function() return o end
	return o
end

function GUI.container(x, y, w, h) return GUI.object(x, y, w, h) end
function GUI.filledWindow(x, y, w, h) return GUI.object(x, y, w, h) end
function GUI.panel(x, y, w, h) return GUI.object(x, y, w, h) end
function GUI.layout(x, y, w, h) return GUI.object(x, y, w, h) end

function GUI.image(x, y, img)
	local o = GUI.object(x, y, img[1], img[2])
	o.image = img
	return o
end

-- GUI.label(x, y, width, height, textColor, text)
function GUI.label(x, y, w, h, c, str)
	local o = GUI.object(x, y, w, h)
	o.text, o.color = str, c
	return o
end

-- GUI.text(x, y, color, text, transparency)
function GUI.text(x, y, c, str)
	local o = GUI.object(x, y, 1, 1)
	o.text, o.color = str, c
	return o
end

-- GUI.keyAndValue(x, y, keyColor, valueColor, key, value)
function GUI.keyAndValue(x, y, kc, vc, key, value)
	local o = GUI.object(x, y, 1, 1)
	o.key, o.value = key, value
	o.keyColor, o.valueColor = kc, vc
	return o
end

-- GUI.chart(x, y, width, height, axisColor, axisValueColor, axisHelpersColor,
--            chartColor, xAxisValueInterval, yAxisValueInterval,
--            xAxisPostfix, yAxisPostfix, fillChartArea, values)
-- Captures the real series Monitor passes, so the chart-shape assertions can run
-- against actual data rather than a hand-built stand-in.
CHART_ARGS = {}

function GUI.chart(x, y, w, h, ...)
	local o = GUI.object(x, y, w, h)
	-- GUI.chart(x, y, width, height, axisColor, axisValueColor, axisHelpersColor,
	--            chartColor, xAxisValueInterval, yAxisValueInterval, xAxisPostfix,
	--            yAxisPostfix, fillChartArea, values)
	-- so with (x, y, w, h) already consumed, vararg N is argument N + 4.
	o.xAxisValueInterval = select(5, ...)
	o.yAxisValueInterval = select(6, ...)
	o.xAxisPostfix = select(7, ...)
	o.yAxisPostfix = select(8, ...)
	o.values = select(10, ...)
	CHART_ARGS[#CHART_ARGS + 1] = {
		values = o.values,
		xInterval = o.xAxisValueInterval,
		yInterval = o.yAxisValueInterval,
		height = h,
	}
	return o
end

function GUI.adaptiveRoundedButton(x, y, w, h, a, b, c, d, str)
	local o = GUI.object(x, y, w, h)
	o.text = str
	return o
end

function GUI.actionButtons(x, y)
	local c = GUI.object(x, y, 5, 1)
	c.close = GUI.object(1, 1, 1, 1)
	c.minimize = GUI.object(3, 1, 1, 1)
	c.maximize = GUI.object(5, 1, 1, 1)
	return c
end

GUI.ALIGNMENT_HORIZONTAL_LEFT = 1
GUI.ALIGNMENT_HORIZONTAL_CENTER = 2
GUI.ALIGNMENT_VERTICAL_TOP = 1
GUI.ALIGNMENT_VERTICAL_CENTER = 2

--------------------------------------------------------------------------------
-- Event / filesystem / system stubs
--------------------------------------------------------------------------------

local handlers = {}
local event = {}
function event.addHandler(callback, interval, times)
	local h = {callback = callback, interval = interval, times = times}
	handlers[h] = true
	return h
end
function event.removeHandler(h) handlers[h] = nil return true end

local FILES = {
	["/Users/t/notes.txt"] = "hello",
	["/Users/t/docs/a.txt"] = "aaaa",
	["/Users/t/docs/deep/b.txt"] = "bbbbbb",
}
local DIR = {["/Users/t/"] = true, ["/Users/t/docs/"] = true, ["/Users/t/docs/deep/"] = true}

local filesystem = {}

-- faithful to Libraries/Filesystem.lua: returns the PARENT directory
function filesystem.path(p) return p:match("^(.+%/).") or "" end
function filesystem.removeSlashes(p) return (p:gsub("/+", "/")) end
function filesystem.getCurrentScript() return "/System/Applications/Monitor.app/Main.lua" end
function filesystem.exists(p) return FILES[p] ~= nil or DIR[p] == true end
function filesystem.isDirectory(p) return DIR[p] == true or DIR[p .. "/"] == true end

function filesystem.list(p)
	if p:sub(-1) ~= "/" then p = p .. "/" end
	local out = {}
	for f in pairs(FILES) do
		if f:sub(1, #p) == p and not f:sub(#p + 1):find("/") then out[#out + 1] = f:match("[^/]*$") end
	end
	for d in pairs(DIR) do
		if d ~= p and d:sub(1, #p) == p and not d:sub(#p + 1, #d - 1):find("/") then
			out[#out + 1] = d:match("([^/]*)/$")
		end
	end
	table.sort(out)
	return out
end

function filesystem.size(p) return FILES[p] and #FILES[p] or 0 end

local paths = {user = {home = "/Users/t/"}}

local mounts = {"/Users/t/", "/rom/", "/tmp/"}
function filesystem.mounts()
	local at = 0
	return function()
		at = at + 1
		if at <= #mounts then return {proxy = true}, mounts[at] end
	end
end

local addedWindow, removed = nil, false
local system = {}
function system.getLocalization() return {} end
function system.getCurrentScript() return "/System/Applications/Monitor.app/Main.lua" end
function system.addWindow(w)
	addedWindow = w
	w.actionButtons = GUI.actionButtons(1, 1)
	w.backgroundPanel = GUI.panel(1, 1, w.width, w.height)
	w.remove = function() removed = true end
	-- the real GUI.window exposes draw (windowDraw); Monitor repaints itself
	-- rather than the whole desktop
	w.draw = function() windowDrawn = windowDrawn + 1 end
	return workspace, w
end

local uptime = 1000
_G.computer = {uptime = function() return uptime end, pullSignal = function() end}
-- a loaded OCIF image: numeric width/height at [1] and [2]
_G.image = {load = function() return {25, 25} end}
_G.color = {to8Bit = function() return 0 end}
_G.unicode = {len = function(v) return #v end, wlen = function(v) return #v end}

local realRequire = require
_G.require = function(n)
	if n == "GUI" then return GUI end
	if n == "Event" then return event end
	if n == "Filesystem" then return filesystem end
	if n == "Paths" then return paths end
	if n == "Image" then return image end
	if n == "System" then return system end
	return realRequire(n)
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

print("== load ==")
local ok, err = pcall(dofile, rootPath .. "/Applications/Monitor.app/Main.lua")
check("app loads without error", ok, err)
if not ok then os.exit(1) end

check("a window was added", addedWindow ~= nil)
check("a periodic handler was registered", next(handlers) ~= nil)

local h = next(handlers)
-- The interval is read from the source rather than hardcoded, because it was
-- deliberately raised from 1s to 2s after this app was found to exhaust memory.
local srcText = assert(io.open(rootPath .. "/Applications/Monitor.app/Main.lua")):read("*a")
local declaredRefresh = tonumber(srcText:match("local REFRESH = (%d+)"))
check("refresh interval matches the source", h and h.interval == declaredRefresh,
	("%s vs %s"):format(tostring(h and h.interval), tostring(declaredRefresh)))

print("== child geometry ==")
-- Every child the app put in the window must have numeric width/height, which is
-- exactly what the real layout's math.max requires.
local root = addedWindow.children[1]
local bad = {}
for i, c in ipairs(root.children) do
	if type(c.width) ~= "number" or type(c.height) ~= "number" then
		bad[#bad + 1] = ("#%d %s w=%s h=%s"):format(i, tostring(c.text or c.key or "?"), tostring(c.width), tostring(c.height))
	end
end
check("all " .. #root.children .. " children have numeric geometry", #bad == 0, table.concat(bad, "; "))

local charts = {}
for _, c in ipairs(root.children) do
	if c.values then charts[#charts + 1] = c end
end
check("two charts present", #charts == 2, #charts)

print("== ticking ==")
for i = 1, 5 do uptime = uptime + 1 h.callback() end
check("memory chart filled", #charts[1].values == 6, #charts[1].values)
check("frame chart filled", #charts[2].values == 6, #charts[2].values)
check("window repainted on every tick", windowDrawn >= 5, windowDrawn)
check("desktop not fully repainted every tick", drawn <= 2, drawn)

local values = {}
for _, c in ipairs(root.children) do
	if c.key then values[c.key] = c.value end
end
do
	local parts = {}
	for k, v in pairs(values) do parts[#parts + 1] = k .. "=" .. tostring(v) end
	table.sort(parts)
	print("     values: " .. table.concat(parts, "  "))
end

check("heap is reported", type(values["Lua heap"]) == "string" and #values["Lua heap"] > 0, values["Lua heap"])
check("refresh cost is reported", values["Average refresh"]:match("ms$") ~= nil, values["Average refresh"])
check("monitor uptime counted", values["Monitor uptime"] == "00:00", values["Monitor uptime"])
check("system uptime formatted", values["System uptime"] ~= nil, values["System uptime"])
check("mounts counted", values["Mounted volumes"] == "3", values["Mounted volumes"])

print("== history bound ==")
local declaredHistory = tonumber(srcText:match("local HISTORY = (%d+)"))
for i = 1, 200 do uptime = uptime + 1 h.callback() end
check("memory history capped at HISTORY", #charts[1].values == declaredHistory, #charts[1].values)
check("frame history capped at HISTORY", #charts[2].values == declaredHistory, #charts[2].values)

print("== storage scan ==")
local button, storage
for _, c in ipairs(root.children) do
	if c.key == "Home directory" then storage = c end
	if c.onTouch and (c.text == "Measure home" or c.text == "Cancel") then button = c end
end
check("measure button found", button ~= nil)

button.onTouch()
check("button switches to Cancel", button.text == "Cancel", button.text)
check("scan reports progress", tostring(storage.value):match("measuring") ~= nil, storage.value)

for i = 1, 10 do uptime = uptime + 1 h.callback() end
check("scan finishes", tostring(storage.value):match("files") ~= nil, storage.value)
check("scan found 3 files", storage.value:match("^3 files") ~= nil, storage.value)
check("scan found no directories as files", storage.value:match("^3 files") ~= nil, storage.value)
check("button back to Measure", button.text == "Measure home", button.text)

print("== cancel ==")
button.onTouch()
button.onTouch()
check("cancel resets the label", storage.value == "cancelled", storage.value)

print("== chart data shape ==")
-- These are the assertions that were missing when two chart bugs shipped. The
-- chart stub used to discard everything it was given, so nothing checked that
-- Monitor was handing GUI.chart something drawable.
check("two charts were created", #CHART_ARGS == 2, #CHART_ARGS)

for i = 1, #CHART_ARGS do
	local chart = CHART_ARGS[i]
	local points = chart.values
	local label = "chart " .. i

	check(label .. ": y interval is non-zero", (chart.yInterval or 0) > 0, tostring(chart.yInterval))
	check(label .. ": x interval is non-zero", (chart.xInterval or 0) > 0, tostring(chart.xInterval))

	-- Every element must be an {x, y} point table, not a bare number.
	local bad = nil
	for k = 1, #points do
		local p = points[k]
		if type(p) ~= "table" then bad = "element " .. k .. " is " .. type(p); break end
		if type(p[1]) ~= "number" or type(p[2]) ~= "number" then
			bad = ("element %d is not {number, number}"):format(k); break
		end
	end
	check(label .. ": every value is an {x, y} point", bad == nil, bad)

	-- x must increase, since drawChart sorts on it and computes deltas from it
	local monotonic = true
	for k = 2, #points do
		if points[k][1] <= points[k - 1][1] then monotonic = false break end
	end
	check(label .. ": x increases monotonically", monotonic or #points < 2, "x not increasing")
end

print("== the real drawChart accepts what Monitor produces ==")
do
	local gui = assert(io.open(rootPath .. "/Libraries/GUI.lua")):read("*a")
	local getAxisValue = assert(gui:match("(local function getAxisValue.-\nend)\n"))
	local drawChartSrc = assert(gui:match("(local function drawChart.-\nend)\n"))

	local drawn = 0
	local stub = setmetatable({}, {__index = function()
		return function() drawn = drawn + 1 end
	end})

	local env = setmetatable({
		screen = stub,
		unicode = {wlen = function(s) return #s end, len = function(s) return #s end},
		number = {round = function(v) return math.floor(v + 0.5) end, shorten = function(v) return tostring(v) end},
	}, {__index = _G})

	local drawChart = assert(load(getAxisValue .. "\n" .. drawChartSrc .. "\nreturn drawChart\n", "g", "t", env))()

	for i = 1, #CHART_ARGS do
		local chart = CHART_ARGS[i]
		drawn = 0
		local ok, err = pcall(drawChart, {
			x = 1, y = 1, width = 44, height = chart.height or 6,
			colors = {axis = 0, chart = 0, axisValue = 0, helpers = 0},
			values = chart.values,
			xAxisPostfix = "", yAxisPostfix = " KB",
			fillChartArea = true, showYAxisValues = true, showXAxisValues = true,
			xAxisValueInterval = chart.xInterval,
			yAxisValueInterval = chart.yInterval,
		})
		check(("chart %d draws with the real drawChart"):format(i), ok, err)
		check(("chart %d drew something"):format(i), ok and drawn > 0, drawn)
	end
end

print("== sample caps match the declared HISTORY ==")
do
	local src = assert(io.open(rootPath .. "/Applications/Monitor.app/Main.lua")):read("*a")
	local history = tonumber(src:match("local HISTORY = (%d+)"))
	local refresh = tonumber(src:match("local REFRESH = (%d+)"))
	check("HISTORY parsed from source", history ~= nil, tostring(history))
	check("both charts capped at HISTORY", #charts[1].values <= history and #charts[2].values <= history,
		#charts[1].values .. "/" .. #charts[2].values)
	check("refresh is no faster than 2s", refresh ~= nil and refresh >= 2, tostring(refresh))
	print(("     HISTORY=%d REFRESH=%ds -> %ds of history")
		:format(history, refresh, history * refresh))
end

print("== memory growth ==")
-- Does anything accumulate without bound? The stub workspace draws nothing, so
-- this isolates Monitor's own allocations (sample arrays, string churn, the
-- storage-scan queue) from the cost of a real GUI repaint.
local function kb() return collectgarbage("count") end

local tick = h.callback
collectgarbage("collect")
local baseline = kb()

for i = 1, 200 do uptime = uptime + 1 tick() end
collectgarbage("collect")
local after200 = kb()

for i = 1, 800 do uptime = uptime + 1 tick() end
collectgarbage("collect")
local after1000 = kb()

print(("     baseline %.1f KB, after 200 ticks %.1f KB, after 1000 ticks %.1f KB")
	:format(baseline, after200, after1000))
print(("     charts: %d + %d samples (capped at 90 each)"):format(#charts[1].values, #charts[2].values))

check("sample arrays stay capped", #charts[1].values <= 90 and #charts[2].values <= 90,
	#charts[1].values .. "/" .. #charts[2].values)

-- The real question is whether growth stops. 200 -> 1000 ticks is 800 more ticks;
-- if it were leaking, that delta would dwarf the first 200.
local firstPhase = after200 - baseline
local secondPhase = after1000 - after200
print(("     growth over first 200 ticks: %.1f KB, over next 800: %.1f KB")
	:format(firstPhase, secondPhase))
check("growth does not scale with tick count (no leak)",
	secondPhase <= math.max(firstPhase, 1) * 1.5 + 4,
	("first %.1f KB then %.1f KB"):format(firstPhase, secondPhase))

print("== storage scan queue is bounded ==")
-- Build a wide, shallow tree: one directory holding many subdirectories. Without
-- the cap the scan queues every one of them, which on a small machine is the
-- only structure here whose size is set by the user's data.
local WIDE = 400
local wideFiles, wideDir = {}, {}
wideFiles["/Users/wide/seed.txt"] = "x"
for i = 1, WIDE do wideDir["/Users/wide/d" .. i .. "/"] = true end

local savedFiles, savedDir = FILES, DIR
FILES, DIR = wideFiles, wideDir
paths.user.home = "/Users/wide/"

collectgarbage("collect")
local beforeWide = collectgarbage("count")

button.onTouch() -- start the scan
for i = 1, 400 do h.callback() end

collectgarbage("collect")
local afterWide = collectgarbage("count")
local peakKB = afterWide - beforeWide

storage = nil
for _, c in ipairs(root.children) do if c.key == "Home directory" then storage = c end end
local report = tostring(storage.value)

print(("     wide tree: %d dirs, peak growth %.1f KB, report: %s"):format(WIDE, peakKB, report))
check("scan completed", report:match("files") ~= nil, report)
check("scan reports itself as partial when it truncates",
	report:match("partial") ~= nil, report)
check("peak growth stays modest", peakKB < 256, ("%.1f KB"):format(peakKB))

FILES, DIR = savedFiles, savedDir
paths.user.home = "/Users/t/"

print("== closing ==")
addedWindow.actionButtons.close.onTouch()
check("timer handler removed on close", next(handlers) == nil, next(handlers))
check("window removed on close", removed, removed)

print(("\n== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)