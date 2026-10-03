
local GUI = require("GUI")
local event = require("Event")
local filesystem = require("Filesystem")
local internet = require("Internet")
local system = require("System")

local module = {}

local workspace, window, localization = table.unpack({...})

-- system.getLocalization tags any key it does not have as "$" .. key, so a plain
-- `localization.x or "fallback"` renders "$x" instead of the fallback. This
-- module is newer than the shipped translations, so that would hit every
-- string here; compare against the sentinel to fall back properly.
local function t(key, fallback)
	local value = localization[key]

	if type(value) ~= "string" or value == "$" .. key then
		return fallback
	end

	return value
end

module.name = t("systemUpdate", "System update")
module.margin = 1

--------------------------------------------------------------------------------

local REPOSITORY = "https://raw.githubusercontent.com/Anonymous1000MC/TheanOS/master/"
local LOCAL_VERSION_PATH = "/Version.cfg"
local REMOTE_VERSION_URL = REPOSITORY .. "Version.cfg"
local REMOTE_FILES_URL = REPOSITORY .. "Installer/Files.cfg"
local REMOTE_MANIFEST_URL = REPOSITORY .. "Packages/manifest.cfg"
local LOCAL_MANIFEST_PATH = "/Manifest.cfg"

local COLOR = {
	text = 0x696969,
	heading = 0x2D2D2D,
	ok = 0x2D8B4A,
	warn = 0xB8860B,
	error = 0xCC0040,
	accent = 0x3366CC,
}

--------------------------------------------------------------------------------
-- Versions
--------------------------------------------------------------------------------

-- "1.2.3" -> 1, 2, 3. Missing parts count as zero.
local function parseVersion(value)
	local major, minor, patch = tostring(value or ""):match("^(%d+)%.?(%d*)%.?(%d*)")
	return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

local function isNewerThan(latest, current)
	local latestMajor, latestMinor, latestPatch = parseVersion(latest)
	local currentMajor, currentMinor, currentPatch = parseVersion(current)

	if latestMajor ~= currentMajor then return latestMajor > currentMajor end
	if latestMinor ~= currentMinor then return latestMinor > currentMinor end

	return latestPatch > currentPatch
end

local function readLocalVersion()
	if not filesystem.exists(LOCAL_VERSION_PATH) then
		return nil
	end

	local data = filesystem.readTable(LOCAL_VERSION_PATH)
	return data and data.version
end

local function deserialize(text)
	local chunk, reason = load("return " .. text, "=remote")
	if not chunk then
		return nil, tostring(reason)
	end

	return chunk()
end

local function urlEncode(value)
	return (value:gsub("([^%w%-%_%.%~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--------------------------------------------------------------------------------
-- Overlays
--------------------------------------------------------------------------------

local overlay
local updateHandler

local function stopUpdate()
	if updateHandler then
		event.removeHandler(updateHandler)
		updateHandler = nil
	end
end

local function closeOverlay()
	stopUpdate()

	if overlay then
		overlay:remove()
		overlay = nil
	end
end

-- Full-workspace panel used for both the confirmation and the progress screen.
-- Returns the inner layout, which is where children have to be added.
-- `dismissible` keeps addBackgroundContainer's click-to-close panel handler; the
-- progress overlay must not be dismissable or a stray touch would abort it.
local function openOverlay(title, dismissible, opaque)
	closeOverlay()

	overlay = workspace:addChild(GUI.container(1, 1, workspace.width, workspace.height))
	overlay.blockScreenEvents = true

	if opaque then
		-- addBackgroundContainer's own backdrop is 30% transparent, so without
		-- this the desktop shows through the updater
		overlay:addChild(GUI.panel(1, 1, overlay.width, overlay.height, 0x000000))
	end

	local container = GUI.addBackgroundContainer(overlay, true, true, title)

	if not dismissible and container.panel then
		container.panel.eventHandler = nil
	end

	return container.layout
end

--------------------------------------------------------------------------------
-- What gets updated
--------------------------------------------------------------------------------

-- Core files always, the user's own language, plus any optional app or wallpaper
-- that is actually present -- so optional content is refreshed but nothing new
-- appears that the user never installed.
local function buildUpdateList(remoteFiles, userSettings)
	local list, seen = {}, {}

	local function add(path)
		if type(path) == "table" then
			path = path.path
		end

		if type(path) == "string" and path ~= "" and not seen[path] then
			seen[path] = true
			list[#list + 1] = path
		end
	end

	for _, item in ipairs(remoteFiles.required or {}) do
		add(item)
	end

	for _, item in ipairs(remoteFiles.requiredWallpapers or {}) do
		add(item)
	end

	local wantedLanguage = (userSettings and userSettings.localizationLanguage) or "English"
	local englishFallback = false

	for _, name in ipairs(remoteFiles.localizations or {}) do
		local language = filesystem.hideExtension(filesystem.name(name))

		if language == wantedLanguage then
			add(name)
		elseif language == "English" then
			englishFallback = true
		end
	end

	if englishFallback then
		add("Localizations/English.lang")
	end

	for _, key in ipairs({"optional", "optionalWallpapers"}) do
		for _, item in ipairs(remoteFiles[key] or {}) do
			local path = type(item) == "table" and item.path or item

			if filesystem.exists("/" .. path) then
				add(item)
			end
		end
	end

	return list
end

--------------------------------------------------------------------------------
-- Update plan
--------------------------------------------------------------------------------

-- Reads the hash manifest the device stored when these files were installed.
local function readLocalManifest()
	if not filesystem.exists(LOCAL_MANIFEST_PATH) then
		return nil
	end

	local data = filesystem.readTable(LOCAL_MANIFEST_PATH)
	return data and data.files or nil
end

-- Decides what actually needs downloading.
--
-- The remote manifest maps every installable path to the SHA-256 of its contents.
-- Comparing that against the copy on the device means we only fetch files that
-- genuinely differ. Hashing happens on the build machine, never here: MineOS's
-- SHA-256 is pure Lua and the install set is ~2 MB, so hashing it on the
-- computer would take minutes. The device only ever compares table entries.
--
-- Returns a list plus a little detail for the UI, and whether the manifest
-- should be saved when the run finishes.
local function buildPlan()
	local body, reason = internet.request(REMOTE_MANIFEST_URL)
	if not body then
		return nil, "manifest: " .. tostring(reason or "?")
	end

	local remote = deserialize(body)
	if not remote or type(remote.files) ~= "table" then
		return nil, "manifest: unreadable"
	end

	local installed = readLocalManifest()

	-- Sorted so the run is deterministic and the progress bar advances evenly.
	local paths = {}
	for path in pairs(remote.files) do
		paths[#paths + 1] = path
	end
	table.sort(paths)

	local list, dropped = {}, 0

	for i = 1, #paths do
		local path = paths[i]

		if not installed or installed[path] ~= remote.files[path] or not filesystem.exists(path) then
			list[#list + 1] = path
		end
	end

	-- Files this device installed that the manifest no longer lists. Reported
	-- rather than deleted: removing a file the user may have edited is a worse
	-- failure than leaving a stale one behind.
	if installed then
		for path in pairs(installed) do
			if remote.files[path] == nil then
				dropped = dropped + 1
			end
		end
	end

	return {
		list = list,
		total = #paths,
		dropped = dropped,
		baseline = installed ~= nil,
		manifest = remote,
	}
end

--------------------------------------------------------------------------------
-- The update run
--------------------------------------------------------------------------------

local function runUpdate(plan, onFinished)
	local box = openOverlay(t("updating", "Updating System"), false, true)

	local statusText = box:addChild(GUI.text(1, 1, COLOR.text, t("preparing", "Preparing...")))
	box:addChild(GUI.object(1, 1, 1, 1))

	local progressBar = box:addChild(GUI.progressBar(1, 1, 40, 0x66B6FF, 0xD2D2D2, 0xA5A5A5, 0, true, true, "", "%"))

	box:addChild(GUI.object(1, 1, 1, 1))
	box:addChild(GUI.text(1, 1, COLOR.text, t("updateNote", "Do not switch off the computer.")))

	box:addChild(GUI.object(1, 1, 1, 1))
	local cancelButton = box:addChild(GUI.adaptiveRoundedButton(1, 1, 2, 0,
		0xC3C3C3, 0x878787, 0xA5A5A5, 0x696969, t("cancelUpdate", "Cancel")
	))

	workspace:draw()

	local cancelled = false

	local function finish(ok, message)
		closeOverlay()
		workspace:draw()

		if onFinished and not cancelled then
			onFinished(ok, message)
		end
	end

	cancelButton.onTouch = function()
		cancelled = true
		finish(false, t("updateCancelled", "Update cancelled."))
	end

	local list = plan.list

	if #list == 0 then
		closeOverlay()
		workspace:draw()

		if onFinished then
			onFinished(true, t("nothingToDo", "Everything is already up to date."))
		end

		return
	end

	if plan.baseline then
		statusText.text = t("planSummary", "%d of %d files changed"):format(#list, plan.total)
		workspace:draw()
	end

	local failed, index = {}, 1

	local function step()
		if index > #list then
			return true
		end

		local path = list[index]
		statusText.text = t("installing", "Installing %d/%d: %s"):format(index, #list, filesystem.name(path))

		-- Manifest keys are already absolute, so do not prefix another slash.
		local target = path:sub(1, 1) == "/" and path or ("/" .. path)
		local proxy, proxyPath = filesystem.get(target)
		if proxy then
			proxy.makeDirectory(filesystem.path(proxyPath))
		end

		local ok, why = internet.download(REPOSITORY .. urlEncode(target:sub(2)), target)
		if not ok then
			failed[#failed + 1] = path
		end

		index = index + 1
		progressBar.value = math.floor((index - 1) / #list * 100)

		return index > #list
	end

	-- Each workspace:draw() repaints the entire desktop, including the blurred
	-- panel the Settings window uses, so doing it per file stutters badly. The
	-- handler still runs every pull; only the repaint is rate limited.
	local lastDraw = 0
	local REDRAW_INTERVAL = 0.35

	updateHandler = event.addHandler(function()
		local done = step()

		local now = computer.uptime()
		if done or (now - lastDraw) >= REDRAW_INTERVAL then
			lastDraw = now
			workspace:draw()
		end

		if done then
			-- Keep the marker files in step with what we just wrote, so the next
			-- run can diff against this state instead of downloading everything.
			internet.download(REMOTE_VERSION_URL, LOCAL_VERSION_PATH)
			internet.download(REMOTE_MANIFEST_URL, LOCAL_MANIFEST_PATH)

			if #failed == 0 then
				finish(true, t("updateDone", "The system has been updated."))
			else
				finish(false, t("updatePartial", "Updated with %d error(s). Check the connection and try again."):format(#failed))
			end
		end
	end)

	workspace:draw()
end

--------------------------------------------------------------------------------

local installedLabel, latestLabel, releaseLabel, notesLabel, statusText
local updateButton

local function setStatus(value, color)
	statusText.text = value
	statusText.color = color or COLOR.text
	workspace:draw()
end

local function checkForUpdates()
	closeOverlay()

	setStatus(t("checking", "Checking..."), COLOR.text)
	updateButton.hidden = true

	local body, reason = internet.request(REMOTE_VERSION_URL)
	if not body then
		setStatus(t("checkFailed", "Could not reach the update server: %s"):format(reason or "?"), COLOR.error)
		return
	end

	local remote = deserialize(body)
	if not remote or not remote.version then
		setStatus(t("checkFailed", "The update server sent something unreadable."), COLOR.error)
		return
	end

	local installed = readLocalVersion()

	installedLabel.text = installed or t("unknown", "unknown")
	latestLabel.text = remote.version
	latestLabel.color = (not installed or isNewerThan(remote.version, installed)) and COLOR.accent or COLOR.heading

	releaseLabel.text = remote.released
		.. (remote.channel and ("  (" .. remote.channel .. ")") or "")
	notesLabel.text = remote.notes or "-"

	if not installed then
		setStatus(t("noVersionMarker", "No version marker found. Installing the latest version is safe."), COLOR.warn)
		updateButton.hidden = false
		return
	end

	if isNewerThan(remote.version, installed) then
		setStatus(t("updateAvailable", "An update is available."), COLOR.warn)
		updateButton.hidden = false
	else
		setStatus(t("upToDate", "Your system is up to date."), COLOR.ok)
	end
end

local function confirmUpdate(latestVersion)
	local plan, planReason = buildPlan()

	local box = openOverlay(t("updateTitle", "System update"), true)

	if plan then
		local detail

		if #plan.list == 0 then
			detail = t("planNothing", "All %d files are already current."):format(plan.total)
		elseif plan.baseline then
			detail = t("planSummary", "%d of %d files changed"):format(#plan.list, plan.total)
		else
			detail = t("planFirstRun", "No update record on this system, so all %d files will be fetched."):format(#plan.list)
		end

		if plan.dropped > 0 then
			detail = detail .. "\n" .. t("planDropped", "%d file(s) are no longer part of the system and were left alone."):format(plan.dropped)
		end

		box:addChild(GUI.text(1, 1, COLOR.text, t("updatePrompt", "Update from %s to %s?"):format(
			readLocalVersion() or t("unknown", "unknown"), latestVersion
		)))
		box:addChild(GUI.text(1, 1, COLOR.accent, detail))
	else
		box:addChild(GUI.text(1, 1, COLOR.error, t("planFailed", "Could not work out what changed: %s"):format(planReason)))
	end

	box:addChild(GUI.object(1, 1, 1, 1))

	local buttons = box:addChild(GUI.layout(1, 1, 30, 3, 1, 1))
	buttons:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
	buttons:setSpacing(1, 1, 2)

	buttons:addChild(GUI.adaptiveRoundedButton(1, 1, 2, 0, 0x66DB80, 0xFFFFFF, 0x33B65C, 0xFFFFFF, t("install", "Install"))).onTouch = function()
		if not plan then
			closeOverlay()
			workspace:draw()
			return
		end

		runUpdate(plan, function()
			checkForUpdates()
		end)
	end

	buttons:addChild(GUI.adaptiveRoundedButton(1, 1, 2, 0, 0xC3C3C3, 0x878787, 0xA5A5A5, 0x696969, t("notNow", "Not now"))).onTouch = function()
		closeOverlay()
		workspace:draw()
	end

	workspace:draw()
end

--------------------------------------------------------------------------------

module.onTouch = function()
	closeOverlay()

	window.contentLayout:addChild(GUI.text(1, 1, COLOR.heading, t("updateHeading", "System update")))

	local installed = readLocalVersion()

	-- Version card. Children go on the container so the panel sits behind them.
	local card = window.contentLayout:addChild(GUI.container(1, 1, 44, 8))
	card:addChild(GUI.panel(1, 1, card.width, card.height, 0xEAEAEA))

	card:addChild(GUI.label(2, 1, 20, 1, 0x7A7A7A, t("labelInstalled", "Installed")))
	installedLabel = card:addChild(GUI.label(13, 1, 14, 1, COLOR.heading, installed or t("unknown", "unknown")))

	card:addChild(GUI.label(2, 2, 20, 1, 0x7A7A7A, t("labelLatest", "Latest")))
	latestLabel = card:addChild(GUI.label(13, 2, 14, 1, COLOR.heading, t("unknown", "unknown")))

	card:addChild(GUI.label(2, 3, 20, 1, 0x7A7A7A, t("labelReleased", "Released")))
	releaseLabel = card:addChild(GUI.label(13, 3, 29, 1, COLOR.text, "-"))

	card:addChild(GUI.label(2, 5, 20, 1, 0x7A7A7A, t("labelChanges", "Changes")))
	notesLabel = card:addChild(GUI.label(2, 6, 41, 1, COLOR.text, "-"))

	window.contentLayout:addChild(GUI.object(1, 1, 1, 1))
	statusText = window.contentLayout:addChild(GUI.text(1, 1, COLOR.text, t("checkFirst", "Press the button to look for updates.")))

	window.contentLayout:addChild(GUI.object(1, 1, 1, 1))
	local buttons = window.contentLayout:addChild(GUI.layout(1, 1, 44, 3, 1, 1))
	buttons:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
	buttons:setSpacing(1, 1, 2)

	buttons:addChild(GUI.adaptiveRoundedButton(1, 1, 2, 0, 0xC3C3C3, 0x878787, 0xA5A5A5, 0x696969, t("checkForUpdates", "Check for updates"))).onTouch = function()
		checkForUpdates()
	end

	updateButton = buttons:addChild(GUI.adaptiveRoundedButton(1, 1, 2, 0, 0x66B6FF, 0xFFFFFF, 0x3388DD, 0xFFFFFF, t("updateNow", "Update now")))
	updateButton.hidden = true

	updateButton.onTouch = function()
		local body = internet.request(REMOTE_VERSION_URL)
		local remote = body and deserialize(body)

		if remote and remote.version then
			confirmUpdate(remote.version)
		end
	end

	workspace:draw()
end

--------------------------------------------------------------------------------

return module
