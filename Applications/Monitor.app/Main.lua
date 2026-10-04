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
local image = require("Image")

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

-- Samples kept per chart. At the default refresh rate this is a little over two
-- minutes of history: enough to read a trend, bounded so the arrays cannot grow
-- without limit while the window stays open.
local HISTORY = 90

local REFRESH = 1 -- seconds between samples

-- Directories visited per refresh while measuring storage. Walking a tree on an
-- Open Computers machine takes seconds, so it is spread across ticks to keep the
-- window responsive and the cancel button honest.
local SCAN_BATCH = 6

local startedAt = computer.uptime()

--------------------------------------------------------------------------------
--- Formatting
--------------------------------------------------------------------------------

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

-- Highest value in a sample array, without assuming a `unpack` alias exists.
local function peak(values)
	local highest = 0

	for i = 1, #values do
		if values[i] > highest then
			highest = values[i]
		end
	end

	return highest
end

--------------------------------------------------------------------------------
--- State
--------------------------------------------------------------------------------

local samples = {
	memory = {},
	frame = {},
}

-- Declared up front because refresh() below updates them, and a local first seen
-- inside a function would be a different (global) variable.
local memoryText, peakText, frameTimeText, uptimeText, systemUptimeText
local mountsText, storageText, measureButton

local frameCount, frameTotal = 0, 0

local measure = nil

local function push(values, value)
	values[#values + 1] = value

	while #values > HISTORY do
		table.remove(values, 1)
	end
end

--------------------------------------------------------------------------------
--- Storage scan
--------------------------------------------------------------------------------

local function startMeasure()
	measure = {
		queue = {{path = paths.user.home, depth = 0}},
		files = 0,
		total = 0,
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
				if job.depth < 8 then
					measure.queue[#measure.queue + 1] = {path = child, depth = job.depth + 1}
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
		storageText.value = t("measured", "%d files, %s"):format(measure.files, formatBytes(measure.total / 1024))
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

local workspace, window = system.addWindow(GUI.filledWindow(1, 1, 46, 22, COLOR.background))

local layout = window:addChild(GUI.layout(1, 1, window.width, window.height, 1, 1))

local icon = layout:addChild(GUI.image(1, 1, image.load(currentScriptDirectory .. "Icon.pic")))
icon.height = icon.height + 1

-- GUI.label takes (x, y, width, height, textColor, text). Passing the text in
-- the height slot is what put a string into .height and took the kernel down.
layout:addChild(GUI.label(3, 1, layout.width - 2, 1, COLOR.heading, t("title", "System monitor")))
	:setAlignment(GUI.ALIGNMENT_HORIZONTAL_LEFT, GUI.ALIGNMENT_VERTICAL_TOP)

local function section(title)
	layout:addChild(GUI.label(1, 1, layout.width - 2, 1, COLOR.heading, title))
end

-- Returns the key/value object itself, not its text: refresh() assigns to
-- `.value` on every tick, so it needs a handle rather than a copy of the string.
local function row(label)
	return layout:addChild(GUI.keyAndValue(2, 1, COLOR.dim, COLOR.text, label, ""))
end

section(t("memoryHeading", "Memory"))

layout:addChild(GUI.chart(
	1, 1, layout.width - 2, 6,
	COLOR.dim, COLOR.dim, COLOR.grid, COLOR.accent,
	20, 0, "", " KB", true, samples.memory
))

memoryText = row(t("heap", "Lua heap"))
peakText = row(t("peak", "Peak in window"))

section(t("performanceHeading", "Performance"))

layout:addChild(GUI.chart(
	1, 1, layout.width - 2, 6,
	COLOR.dim, COLOR.dim, COLOR.grid, COLOR.ok,
	20, 0, "", " ms", true, samples.frame
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

	push(samples.memory, collectgarbage("count"))

	workspace:draw()

	-- Cost of the refresh itself. On a healthy machine this is a couple of
	-- milliseconds; when the system is struggling it climbs into the tens, which
	-- makes it the most useful "is the machine loaded" signal available here.
	local cost = computer.uptime() - drawBegan

	frameCount = frameCount + 1
	frameTotal = frameTotal + cost

	local average = frameTotal / frameCount

	push(samples.frame, math.floor(average * 1000) / 1000)
	frameTimeText.value = ("%.1f ms"):format(average * 1000)

	memoryText.value = formatBytes(samples.memory[#samples.memory])
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