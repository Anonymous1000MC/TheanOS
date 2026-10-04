-- Copyright (c) 2026 TheanOS contributors
-- SPDX-License-Identifier: MIT
--
-- Live system monitor.
--
-- Everything shown here is measured, not estimated. MineOS exposes no CPU
-- percentage to read, so rather than invent one this window tracks the figures
-- the runtime can actually report: the Lua heap, how long a refresh costs, how
-- long the machine has been up, what is mounted, and -- on request -- how much
-- the home directory holds.
--
-- Refreshing runs from an event handler rather than a `while true` loop, so the
-- desktop stays responsive and closing the window really stops the work.

local system = require("System")
local GUI = require("GUI")
local event = require("Event")
local filesystem = require("Filesystem")
local paths = require("Paths")

local currentScriptDirectory = filesystem.path(system.getCurrentScript())
local localization = system.getLocalization(currentScriptDirectory .. "Localizations/")

-- system.getLocalization marks every key it does not have as "$" .. key, so
-- `localization.x or fallback` never falls back -- it would render "$x". Reading
-- through this view hides the sentinel. Translations other than English will not
-- have these keys, which is exactly the case it handles.
local function t(key, fallback)
	local value = localization[key]

	if value == nil or value == "$" .. key then
		return fallback
	end

	return value
end

local COLOR = {
	background = 0x1E1E1E,
	text = 0xE1E1E1,
	dim = 0x969696,
	heading = 0xFFFFFF,
	ok = 0x66DB80,
	accent = 0x4A9BE8,
	grid = 0x3A3A3A,
}

-- Samples kept per chart, and how often a sample is taken.
--
-- Both were reduced after this app was found to be able to exhaust memory on a
-- 2 MB machine. The arrays themselves are tiny; the cost was the repaint. Each
-- GUI draw allocates strings and small tables, and doing that for the whole
-- desktop once a second left the collector no headroom, so the transient peak
-- could exceed free RAM before a collection ran -- which is what produced
-- "not enough memory" rather than an outright leak.
--
-- 60 samples at 2 seconds is two minutes of history, the same span as before.
local HISTORY = 60

local REFRESH = 2 -- seconds between samples

-- Axis label interval, used by GUI.chart as a multiplier on its axis loop step.
--
-- This must never be 0. drawChart steps its y axis by
-- -chartHeight * yAxisValueInterval, and a numeric for with a step of zero never
-- advances its control variable, so the axis loop runs forever, inserting a table
-- and a string per pass, until the machine is out of memory. A quarter of the
-- chart per label is what the existing chart in 3D Test uses.
local AXIS_INTERVAL = 0.25

-- Directories visited per refresh while measuring storage. Walking a tree on an
-- Open Computers machine takes seconds, so it is spread across ticks to keep the
-- window responsive and the cancel button honest.
local SCAN_BATCH = 6

-- Hard cap on directories waiting to be visited. The queue is the only structure
-- here whose size is set by the user's data rather than by us, so without a cap a
-- home directory with thousands of folders would allocate thousands of pending
-- entries on a machine with 2 MB of RAM. Past this the scan stops and says so,
-- rather than reporting a total that is quietly wrong.
local SCAN_QUEUE_LIMIT = 128

local startedAt = computer.uptime()

--------------------------------------------------------------------------------
--- Formatting
--------------------------------------------------------------------------------

-- Live memory reading.
--
-- OpenComputers does NOT expose collectgarbage -- it is nil there, so calling it
-- raises "attempt to call a nil value" and takes the app down with a red error
-- box. The usable sources are on the computer table, and which ones exist varies
-- by OpenComputers version, so every read is guarded and simply returns nil when
-- unavailable rather than failing.
--
-- computer.getMemory() is bytes in use; computer.totalMemory() is the installed
-- size and is the one this codebase already relies on (see OS.lua). Returns
-- kilobytes, or nil if neither is available.
local function readMemoryUsed()
	if type(computer.getMemory) == "function" then
		local ok, value = pcall(computer.getMemory)

		if ok and type(value) == "number" then
			return value
		end
	end

	return nil
end

-- Total installed memory, in kilobytes, or nil.
local function readMemoryTotal()
	if type(computer.totalMemory) == "function" then
		local ok, value = pcall(computer.totalMemory)

		if ok and type(value) == "number" then
			return value
		end
	end

	return nil
end

local function formatBytes(kilobytes)
	if kilobytes >= 1024 * 1024 then
		return ("%.2f GB"):format(kilobytes / 1024 / 1024)
	elseif kilobytes >= 1024 then
		return ("%.1f MB"):format(kilobytes / 1024)
	end

	return ("%.0f KB"):format(kilobytes)
end

local function formatUptime(seconds)
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds / 3600) % 24
	local minutes = math.floor(seconds / 60) % 60

	if days > 0 then
		return ("%dd %02d:%02d"):format(days, hours, minutes)
	end

	return ("%02d:%02d"):format(hours, minutes)
end

--------------------------------------------------------------------------------
--- State
--------------------------------------------------------------------------------

-- GUI.chart wants an array of {x, y} POINTS, not an array of bare numbers. It
-- reads values[i][1] and values[i][2], so handing it plain numbers fails on the
-- first comparison.
local samples = {
	memory = {},
	frame = {},
}

-- Declared up front because refresh() below updates them, and a local first seen
-- inside a function would be a different (global) variable.
local memoryText, peakText, frameTimeText, uptimeText, systemUptimeText
local mountsText, storageText, measureButton

local frameCount, frameTotal = 0, 0
local sampleIndex = 0

local measure = nil

local function push(values, x, y)
	values[#values + 1] = {x, y}

	while #values > HISTORY do
		table.remove(values, 1)
	end
end

-- Highest y in a sample series.
local function peak(values)
	local highest = 0

	for i = 1, #values do
		if values[i][2] > highest then
			highest = values[i][2]
		end
	end

	return highest
end

--------------------------------------------------------------------------------
--- Storage scan
--------------------------------------------------------------------------------

local function startMeasure()
	measure = {
		queue = {{path = paths.user.home, depth = 0}},
		files = 0,
		total = 0,
		truncated = false,
	}

	storageText.value = t("measuring", "measuring...")
	measureButton.text = t("cancel", "Cancel")
end

local function stepMeasure()
	if not measure then return end

	for _ = 1, SCAN_BATCH do
		if #measure.queue == 0 then break end

		local job = table.remove(measure.queue, 1)

		for _, entry in ipairs(filesystem.list(job.path) or {}) do
			-- removeSlashes, not filesystem.path: path() returns the *parent*
			-- directory, which would send every child back to where it came from.
			-- This is only needed because job.path may already end in a slash.
			local child = filesystem.removeSlashes(job.path .. "/" .. entry)

			if filesystem.isDirectory(child) then
				-- Guard against symlink loops and absurd nesting.
				if job.depth < 8 and #measure.queue < SCAN_QUEUE_LIMIT then
					measure.queue[#measure.queue + 1] = {path = child, depth = job.depth + 1}
				elseif job.depth < 8 then
					measure.truncated = true
				end
			else
				measure.files = measure.files + 1
				measure.total = measure.total + (filesystem.size(child) or 0)
			end
		end
	end

	if #measure.queue > 0 then
		storageText.value = t("measuringCount", "measuring... %d files"):format(measure.files)
	else
		if measure.truncated then
			-- Say plainly that this is a partial answer. A total that silently omits
			-- most of a directory tree is worse than no total.
			storageText.value = t("measuredPartial", "partial: %d files, %s so far")
				:format(measure.files, formatBytes(measure.total / 1024))
		else
			storageText.value = t("measured", "%d files, %s"):format(measure.files, formatBytes(measure.total / 1024))
		end

		measureButton.text = t("measure", "Measure home")
		measure = nil
	end
end

local function cancelMeasure()
	measure = nil
	measureButton.text = t("measure", "Measure home")
	storageText.value = t("cancelled", "cancelled")
end

--------------------------------------------------------------------------------
--- Window
--------------------------------------------------------------------------------

-- Every child below goes into the same layout cell, and that cell stacks its
-- children vertically, so the window has to be tall enough for the sum of all of
-- them. It was not: the window was 22 rows against roughly 30 rows of content, so
-- the bottom of the window was simply cut off.
--
-- The heights are therefore declared here rather than guessed, and
-- Tools/tests/monitor_layout_test.lua re-adds them up from this file and fails if
-- they ever exceed the window again.
--
-- There is deliberately no icon in here. Every child lands in the same layout
-- cell and that cell stacks its children top to bottom, so an icon cannot sit
-- beside the title without a second cell -- it would stack under it and quietly
-- add rows. The window's own title bar already says which app this is.
-- Every child stacks in one cell and MineOS puts cell.spacing (1 by default)
-- BETWEEN each pair, so the height needed is the sum of the children plus one
-- blank row per gap. With 14 children that is 13 extra rows, which is what made
-- an earlier 27-row window overflow: the layout then centres its content, pushing
-- the first children above the window and the last ones below it, so the top
-- heading and the bottom rows vanished rather than being cleanly clipped.
local SPACING = 1
local CHILD_COUNT = 14
local CONTENT_SUM = 26 -- sum of the individual child heights

local CONTENT_HEIGHT = CONTENT_SUM + (CHILD_COUNT - 1) * SPACING + 1 -- + title bar

local WINDOW_WIDTH = 54

local workspace, window = system.addWindow(
	GUI.filledWindow(1, 1, WINDOW_WIDTH, CONTENT_HEIGHT, COLOR.background)
)

local layout = window:addChild(GUI.layout(1, 1, window.width, window.height, 1, 1))

-- GUI.label takes (x, y, width, height, textColor, text). Passing the text in
-- the height slot is what put a string into .height and took the kernel down.
local title = layout:addChild(GUI.label(
	2, 1, layout.width - 3, 1, COLOR.heading, t("title", "System monitor")
))
title:setAlignment(GUI.ALIGNMENT_HORIZONTAL_LEFT, GUI.ALIGNMENT_VERTICAL_CENTER)

local function section(title)
	return layout:addChild(GUI.label(1, 1, layout.width - 2, 1, COLOR.heading, title))
end

-- Returns the key/value object itself, not its text: refresh() assigns to
-- `.value` on every tick, so it needs a handle rather than a copy of the string.
--
-- keyAndValue draws the value immediately after the key with no gap, so a short
-- window runs the two together. WINDOW_WIDTH is sized for the longest pair,
-- "Mounted volumes" plus its value.
local function row(label)
	return layout:addChild(GUI.keyAndValue(2, 1, COLOR.dim, COLOR.text, label, ""))
end

section(t("memoryHeading", "Memory"))

-- The two interval arguments are multipliers on the loop step, not label counts.
-- A y interval of 0 makes the step zero, and a numeric for with a zero step never
-- advances its control variable: the axis loop then runs forever, allocating a
-- table and a string per pass, until the machine runs out of memory.
layout:addChild(GUI.chart(
	1, 1, layout.width - 2, 6,
	COLOR.dim, COLOR.dim, COLOR.grid, COLOR.accent,
	AXIS_INTERVAL, AXIS_INTERVAL, "", " KB", true, samples.memory
))

memoryText = row(t("heap", "Lua heap"))
peakText = row(t("peak", "Peak in window"))

section(t("performanceHeading", "Performance"))

layout:addChild(GUI.chart(
	1, 1, layout.width - 2, 6,
	COLOR.dim, COLOR.dim, COLOR.grid, COLOR.ok,
	AXIS_INTERVAL, AXIS_INTERVAL, "", " ms", true, samples.frame
))

frameTimeText = row(t("refresh", "Average refresh"))
uptimeText = row(t("monitorUptime", "Monitor uptime"))
systemUptimeText = row(t("systemUptime", "System uptime"))

section(t("storageHeading", "Storage"))

mountsText = row(t("mounts", "Mounted volumes"))
storageText = row(t("home", "Home directory"))

measureButton = layout:addChild(GUI.adaptiveRoundedButton(
	1, 1, 0, 2, 0x66DB80, 0xFFFFFF, 0x33B65C, 0xFFFFFF, t("measure", "Measure home")
))
measureButton.height = 1

measureButton.onTouch = function()
	if measure then
		cancelMeasure()
	else
		startMeasure()
	end

	workspace:draw()
end

--------------------------------------------------------------------------------
--- Periodic refresh
--------------------------------------------------------------------------------

local function refresh()
	local drawBegan = computer.uptime()

	sampleIndex = sampleIndex + 1

	local memoryUsed = readMemoryUsed()
	push(samples.memory, sampleIndex, memoryUsed or 0)

	-- Only this window, not workspace:draw(). The latter repaints every window,
	-- the desktop icon field and the menus on every tick, which on a small
	-- machine is what pushed the transient allocation peak past free RAM.
	-- window:draw() is the established idiom for a self-contained redraw.
	window:draw()

	-- Cost of the refresh itself. On a healthy machine this is a couple of
	-- milliseconds; when the system is struggling it climbs into the tens, which
	-- makes it the most useful "is the machine loaded" signal available here.
	local cost = computer.uptime() - drawBegan

	frameCount = frameCount + 1
	frameTotal = frameTotal + cost

	local average = frameTotal / frameCount

	push(samples.frame, sampleIndex, math.floor(average * 1000) / 1000)
	frameTimeText.value = ("%.1f ms"):format(average * 1000)

	if memoryUsed then
		memoryText.value = formatBytes(memoryUsed)
	else
		-- Say so rather than showing a flat, meaningless line.
		memoryText.value = t("memoryUnavailable", "not reported by this computer")
	end

	peakText.value = formatBytes(peak(samples.memory))
	uptimeText.value = formatUptime(computer.uptime() - startedAt)
	systemUptimeText.value = formatUptime(computer.uptime())

	local mounted = 0
	for proxy, path in filesystem.mounts() do
		mounted = mounted + 1
	end

	mountsText.value = tostring(mounted)

	stepMeasure()
end

refresh()

-- An interval handler keeps being serviced alongside everything else on the
-- desktop, unlike a `while true` loop which would block until the window closed.
local handler = event.addHandler(refresh, REFRESH)

workspace:draw()

--------------------------------------------------------------------------------
--- Closing
--------------------------------------------------------------------------------

-- MineOS closes a window by removing it, with no event to hang cleanup off, so
-- the close button is wrapped: without this the timer would keep sampling into
-- a window that is no longer on screen.
window.actionButtons.close.onTouch = function()
	event.removeHandler(handler)
	window:remove()
	workspace:draw()
end

window.onResize = function(width, height)
	window.backgroundPanel.width = width
	window.backgroundPanel.height = height

	layout.width = width
	layout.height = height
end