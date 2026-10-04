-- Checks that Monitor's window is actually big enough for what it puts in it.
--
-- Every child goes into one layout cell, and that cell stacks them vertically, so
-- the window height has to cover the sum. It did not: a 22-row window held about
-- 30 rows of content and the bottom was clipped away on screen.
--
-- This re-adds the heights up from the source rather than trusting the number in
-- the source, so editing the layout without resizing the window fails here.
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

local f = assert(io.open(rootPath .. "/Applications/Monitor.app/Main.lua"))
local src = f:read("*a")
f:close()

local function declared(name)
	return tonumber(assert(src:match("local " .. name .. " = (%d+)")))
end

local width = declared("WINDOW_WIDTH")
local declaredHeight = declared("CONTENT_HEIGHT")

print(("== declared geometry: %d x %d"):format(width, declaredHeight))

--------------------------------------------------------------------------------
-- Reconstruct the content height independently of the source's own claim
--------------------------------------------------------------------------------

-- The icon is the one child whose height is not a literal, so measure it from the
-- actual Icon.pic rather than assuming.
local iconFile = assert(io.open(rootPath .. "/Applications/Monitor.app/Icon.pic"))
local iconBytes = iconFile:read("*a")
iconFile:close()
check("Icon.pic has the OCIF signature", iconBytes:sub(1, 4) == "OCIF", iconBytes:sub(1, 8))
-- the icon is used for the desktop shortcut only, not inside the window
check("Monitor does not put an icon in its own window",
	not src:find("GUI%.image"), "GUI.image is still in the layout")
local iconMethod = iconBytes:byte(5)
-- methods 6/7/8 store width-1/height-1 for 8
local iconW, iconH = iconBytes:byte(6), iconBytes:byte(7)
if iconMethod == 8 then
	iconW, iconH = iconW + 1, iconH + 1
end

print(("== Icon.pic is %d x %d (method %d)"):format(iconW, iconH, iconMethod))

-- Count the children and their heights the way the layout stacks them.
local chartCount = 0
for _ in src:gmatch("GUI%.chart%(") do chartCount = chartCount + 1 end
local sectionCount = 0
for _ in src:gmatch("section%(t%(") do sectionCount = sectionCount + 1 end
local rowCount = 0
for _ in src:gmatch("row%(t%(") do rowCount = rowCount + 1 end
local buttonCount = 0
for _ in src:gmatch("GUI%.adaptiveRoundedButton%(") do buttonCount = buttonCount + 1 end

local CHART_HEIGHT = 6
local LABEL_HEIGHT = 1
local BUTTON_HEIGHT = 2
local TITLE_BAR = 1 -- the window's own action-button row

local expected = LABEL_HEIGHT         -- heading
	+ sectionCount * LABEL_HEIGHT -- "Memory", "Performance", "Storage"
	+ chartCount * CHART_HEIGHT
	+ rowCount * LABEL_HEIGHT
	+ buttonCount * BUTTON_HEIGHT
	+ TITLE_BAR

print(("== content: heading %d + sections %d + charts %d + rows %d + buttons %d + titlebar %d = %d")
	:format(LABEL_HEIGHT, sectionCount, chartCount * CHART_HEIGHT, rowCount,
		buttonCount * BUTTON_HEIGHT, TITLE_BAR, expected))
print(("   found %d charts, %d sections, %d rows, %d buttons")
	:format(chartCount, sectionCount, rowCount, buttonCount))

check("content fits the window", expected <= declaredHeight,
	("needs %d rows, window is %d"):format(expected, declaredHeight))
check("the window is not needlessly oversized", declaredHeight - expected <= 2,
	("%d rows of slack"):format(declaredHeight - expected))

-- A window taller than the screen cannot be shown at all.
check("window fits a 50-row display", declaredHeight <= 50, declaredHeight)

--------------------------------------------------------------------------------
-- Width: keyAndValue draws the value straight after the key, so the window has
-- to be wide enough for the longest key plus its longest value.
--------------------------------------------------------------------------------

local lang = assert(io.open(rootPath .. "/Applications/Monitor.app/Localizations/English.lang")):read("*a")

local function longest(strings)
	local best = 0
	for _, s in ipairs(strings) do
		if #s > best then best = #s end
	end
	return best
end

-- labels are the first argument of row(t("...", "..."))
local labels, values = {}, {}

-- row(t("key", "Label")) -- the first argument of each row is its label
local labelPattern = 'row%(t%("[^"]*", "([^"]*)"%)%)'
for fallback in src:gmatch(labelPattern) do
	labels[#labels + 1] = fallback
end

-- every t("key", "fallback") pair, for the value side of the budget
local fallbackPattern = 't%("[^"]*", "([^"]*)"%)'
for v in src:gmatch(fallbackPattern) do
	values[#values + 1] = v
end

local widestLabel = longest(labels)
local widestValue = longest(values)

print(("== widest label %d, widest value %d (+2 indent = %d needed, window %d)")
	:format(widestLabel, widestValue, widestLabel + widestValue + 2, width))

-- rows sit at x = 2, and keyAndValue puts no gap between key and value, so the
-- pair starts at column 2. One column of slack is required on top of that, or an
-- exact fit still reads as run-together text.
local needed = 2 + widestLabel + widestValue
check("window is wide enough for label + value", needed < width,
	("needs %d, window is %d"):format(needed, width))

--------------------------------------------------------------------------------
-- The values that get assigned at runtime must fit too
--------------------------------------------------------------------------------

-- Format templates expand at runtime, so the window has to survive the widest of
-- them too, not just the widest literal.
local templates = {}
for v in src:gmatch('"([^"]*%%[^"]*)"') do templates[#templates + 1] = v end

local widestTemplate = longest(templates)
print(("== widest format template: %d (%s)"):format(widestTemplate, tostring(templates[1])))
-- guard against the check going vacuous, which is how it hid the original bug
check("format templates were actually found", #templates > 0, #templates)
check("runtime templates fit the window", 2 + widestLabel + widestTemplate < width,
	("needs %d, window is %d"):format(2 + widestLabel + widestTemplate, width))

print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)