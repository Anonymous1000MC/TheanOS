-- Regression test for the Monitor charts, driving the REAL GUI.chart draw.
--
-- Why this exists: Monitor's unit test stubs GUI.chart out, so it happily accepted
-- two bugs that made the app unusable on hardware.
--   1. values were a flat array of numbers; GUI.chart reads values[i][1]/[2], i.e.
--      {x, y} points, and failed on the first comparison
--   2. yAxisValueInterval was 0. GUI.chart uses it as a loop-step multiplier, so a
--      zero step never advances the control variable and the axis loop runs
--      forever, allocating per pass, until the machine is out of memory
--
-- Bug 2 is the kernel panic. This test loads the real drawChart and runs it with
-- Monitor's real arguments, so neither can come back unnoticed.
--
-- Run from the repository root:  lua5.3 Tools/tests/monitor_chart_test.lua

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
-- Load the real drawChart out of GUI.lua
--------------------------------------------------------------------------------

local src = assert(io.open(rootPath .. "/Libraries/GUI.lua")):read("*a")
local getAxisValue = assert(src:match("(local function getAxisValue.-\nend)\n"))
local drawChart = assert(src:match("(local function drawChart.-\nend)\n"))

local drawn = 0
local screenStub = setmetatable({}, {__index = function()
	return function() drawn = drawn + 1 end
end})

local env = setmetatable({
	screen = screenStub,
	unicode = {wlen = function(s) return #s end, len = function(s) return #s end},
	number = {
		round = function(v) return math.floor(v + 0.5) end,
		shorten = function(v) return tostring(math.floor(v)) end,
	},
}, {__index = _G})

local chart = assert(load(getAxisValue .. "\n" .. drawChart .. "\nreturn drawChart\n",
	"gui", "t", env))()

--------------------------------------------------------------------------------
-- Read Monitor's actual chart arguments from its source
--------------------------------------------------------------------------------

local monitor = assert(io.open(rootPath .. "/Applications/Monitor.app/Main.lua")):read("*a")

-- Grab the two GUI.chart(...) calls verbatim and pull the arguments out.
local calls = {}
for call in monitor:gmatch("(AXIS_INTERVAL, AXIS_INTERVAL, \"[^\"]*\", \"[^\"]*\", true, samples%.[%a]+)") do
	calls[#calls + 1] = call
end
check("found both GUI.chart value arguments", #calls == 2, #calls)

local interval = tonumber(assert(monitor:match("AXIS_INTERVAL = ([%d%.]+)")))

-- Rebuild the series the way refresh() does, straight from the source's own shape.
local HISTORY = tonumber(assert(monitor:match("local HISTORY = (%d+)")))

local function buildSeries(count)
	local series = {}
	for i = 1, count do
		series[i] = {i, 90 + (i % 7)}
	end
	return series
end

local function runChart(values)
	drawn = 0

	local object = {
		x = 1, y = 1, width = 44, height = 6,
		colors = {axis = 0x969696, chart = 0x4A9BE8, axisValue = 0x969696, helpers = 0x3A3A3A},
		values = values,
		xAxisPostfix = "", yAxisPostfix = " KB",
		fillChartArea = true, showYAxisValues = true, showXAxisValues = true,
		xAxisValueInterval = intervalStep,
		yAxisValueInterval = intervalStep,
	}

	local ok, err = pcall(chart, object)
	return ok, err, drawn
end

--------------------------------------------------------------------------------
-- Cases
--------------------------------------------------------------------------------

print("== the zero-step trap ==")
check("AXIS_INTERVAL is non-zero", interval ~= nil and interval > 0, tostring(interval))

-- Run the axis loop under a step counter so an infinite loop is reported rather
-- than hanging the suite.
local function runChartGuarded(values, budget, intervalOverride)
	local calls = 0
	local realScreen = env.screen
	env.screen = setmetatable({}, {__index = function()
		return function()
			calls = calls + 1
			if calls > budget then error("chart drew over budget: loop is not terminating", 0) end
		end
	end})

	local ok, err = pcall(chart, {
		x = 1, y = 1, width = 44, height = 6,
		colors = {axis = 0, chart = 0, axisValue = 0, helpers = 0},
		values = values, xAxisPostfix = "", yAxisPostfix = " KB",
		fillChartArea = true, showYAxisValues = true, showXAxisValues = true,
		xAxisValueInterval = intervalOverride or interval,
		yAxisValueInterval = intervalOverride or interval,
	})

	env.screen = realScreen
	return ok, err, calls
end

print("== Monitor's real configuration draws and terminates ==")
local series = buildSeries(HISTORY)
local ok, err, budget = runChartGuarded(series, 20000)
check("chart draws without error", ok, err)
check("chart terminates within a sane draw budget", budget < 20000, budget)
check("chart actually drew something", budget > 0, budget)

print("== the exact shapes Monitor used to pass ==")
local okFlat, errFlat = runChart({98.1, 98.5, 99.0})
check("flat numbers are rejected (this was bug 1)", not okFlat, "flat numbers unexpectedly accepted")
check("  and the failure is the index error, not a silent wrong chart",
	tostring(errFlat):find("index a number") ~= nil, errFlat)

-- Bug 2 cannot be demonstrated by running it: the axis loop calls table.insert
-- but never screen.drawText, so a draw budget cannot break out of it and the loop
-- simply hangs until the machine dies -- which is exactly the failure being
-- guarded against. So it is checked structurally instead, by reproducing the
-- arithmetic drawChart does and proving the resulting step is non-zero.
--
-- drawChart:  chartHeight = height - 1 - (showXAxisValues and 1 or 0)
--             for y = y + height - 3, y + 1, -chartHeight * yAxisValueInterval
local HEIGHT = 6
local chartHeight = HEIGHT - 1 - 1
local step = -chartHeight * interval
check("the y axis loop step is non-zero", step ~= 0, step)
check("the y axis loop step actually descends", step < 0, step)

-- And prove a zero step really is non-terminating, with a counter inside the loop
-- so the demonstration itself is bounded.
local iterations = 0
local terminated = pcall(function()
	for i = 1, 3 do
		for y = 4, 2, 0 do
			iterations = iterations + 1
			if iterations > 1000 then error("bounded", 0) end
		end
	end
end)
check("a zero step does not terminate (bounded proof)", not terminated, iterations)
check("  it had already looped thousands of times", iterations > 1000, iterations)

print("== empty series, which is what the very first draw sees ==")
local okEmpty, errEmpty, callsEmpty = runChartGuarded({}, 20000)
check("empty series still draws", okEmpty, errEmpty)
check("empty series terminates", callsEmpty < 20000, callsEmpty)

print("== single point ==")
local okOne, errOne = runChartGuarded({{1, 98.5}}, 20000)
check("single point draws", okOne, errOne)

print("== flat series across a full window ==")
local flat = {}
for i = 1, HISTORY do flat[i] = {i, 90 + (i % 11)} end
local okFull, errFull, callsFull = runChartGuarded(flat, 20000)
check("full-length series draws", okFull, errFull)
check("full-length series terminates", callsFull < 20000, callsFull)

print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)