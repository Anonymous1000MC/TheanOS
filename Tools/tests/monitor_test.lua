-- Runs Applications/Monitor.app/Main.lua against GUI/event stubs, then drives
-- the periodic handler to check the app behaves and cleans up after itself.
--
-- The stub signatures below are transcribed from Libraries/GUI.lua on purpose.
-- An earlier stub used GUI.label(x, y, color, text), which silently accepted a
-- 4-argument call and let a string reach the real .height field, which panicked
-- the kernel at GUI.lua:1684. addChild now refuses non-numeric geometry so that
-- class of mistake fails here instead of on a computer.

-- Run from the repository root:  lua5.3 Tools/tests/monitor_test.lua
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
-- GUI stubs (signatures from Libraries/GUI.lua)
--------------------------------------------------------------------------------

local drawn = 0
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
function GUI.chart(x, y, w, h, ...)
	local o = GUI.object(x, y, w, h)
	o.yAxisPostfix = select(9, ...)
	o.values = select(10, ...)
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
local ok, err = pcall(dofile, root .. "/Applications/Monitor.app/Main.lua")
check("app loads without error", ok, err)
if not ok then os.exit(1) end

check("a window was added", addedWindow ~= nil)
check("a periodic handler was registered", next(handlers) ~= nil)

local h = next(handlers)
check("refresh interval is 1s", h and h.interval == 1, h and h.interval)

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
check("workspace redrawn on every tick", drawn >= 5, drawn)

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
for i = 1, 200 do uptime = uptime + 1 h.callback() end
check("memory history capped at 90", #charts[1].values == 90, #charts[1].values)
check("frame history capped at 90", #charts[2].values == 90, #charts[2].values)

print("== storage scan ==")
local button, storage
for _, c in ipairs(root.children) do
	if c.key == "Home directory" then storage = c end
	if c.onTouch and c.text == "Measure home" then button = c end
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

print("== closing ==")
addedWindow.actionButtons.close.onTouch()
check("timer handler removed on close", next(handlers) == nil, next(handlers))
check("window removed on close", removed, removed)

print(("\n== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)