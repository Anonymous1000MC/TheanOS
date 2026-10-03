-- Diagnostics commands for the TheanOS terminal: crash log and install integrity.
-- Loaded by Commands.lua, which injects `.localization`, `.COLOR` and `.context`.

local Diagnostics = {}

local localization, COLOR, COMMANDS = ...

local filesystem = require("Filesystem")
local internet = require("Internet")
local paths = require("Paths")

local CRASH_LOG_PATH = "/Logs/crash.cfg"
local MANIFEST_URL = "https://raw.githubusercontent.com/Anonymous1000MC/TheanOS/master/Packages/manifest.cfg"
local LOCAL_MANIFEST = "/Manifest.cfg"

local function t(key, fallback)
	local value = localization[key]

	-- system.getLocalization reports missing keys as "$" .. key, so a plain
	-- `or fallback` would render the sentinel instead of the fallback.
	if type(value) ~= "string" or value == "$" .. key then
		return fallback
	end

	return value
end

local function humanSize(bytes)
	local units = {"B", "KB", "MB", "GB"}
	local value, unit = bytes or 0, 1

	while value >= 1024 and unit < #units do
		value = value / 1024
		unit = unit + 1
	end

	return ("%.1f %s"):format(value, units[unit])
end

local function readTable(path)
	local ok, data = pcall(filesystem.readTable, path)

	if ok and type(data) == "table" then
		return data
	end

	return nil
end

Diagnostics.commands = {}

--------------------------------------------------------------------------------
-- thean-log
--------------------------------------------------------------------------------

Diagnostics.commands["thean-log"] = {
	usage = "thean-log [count|show <n>|clear]",
	desc = t("theanLogDesc", "show recorded system crashes"),
	run = function(context, args)
		local entries = readTable(CRASH_LOG_PATH)

		if type(entries) == "table" then entries = entries.entries end
		if type(entries) ~= "table" or #entries == 0 then
			context:dim(t("noCrashes", "No crashes have been recorded."))
			return
		end

		local action = args[1]

		if action == "clear" then
			local proxy, proxyPath = filesystem.get(CRASH_LOG_PATH)
			if proxy then proxy.remove(proxyPath) end

			context:ok(t("logCleared", "Crash log cleared."))
			return
		end

		if action == "show" then
			local index = tonumber(args[2])
			local entry = index and entries[index]

			if not entry then
				context:err(t("noSuchCrash", "No such crash: %s"):format(args[2] or "?"))
				return
			end

			context:heading(("#%d  %s"):format(index, entry.time or "?"))
			context:out(("module   %s"):format(entry.module or "?"))
			context:out(("line     %s"):format(tostring(entry.line or "?")))
			context:out(("uptime   %ds"):format(tostring(entry.uptime or "?")))
			context:out(("fault    %s"):format(entry.fault or "?"))
			context:out("")
			context:dim(entry.traceback or "")
			return
		end

		local limit = tonumber(action) or 10

		context:heading(t("crashHistory", "Recorded crashes (%d total):"):format(#entries))

		-- newest last, matching the order they were appended
		local first = math.max(1, #entries - limit + 1)
		for i = #entries, first, -1 do
			local entry = entries[i]
			context:out(("%3d  %s  up %-6s  %s"):format(
				i, entry.time or "?", tostring(entry.uptime or "?") .. "s", entry.fault or "?"
			), COLOR.error)
		end

		context:dim(t("logHint", "thean-log show <n> for the full traceback"))
	end,
}

--------------------------------------------------------------------------------
-- thean-check
--------------------------------------------------------------------------------

local function classify(context, files, entry)
	local path = entry.path or entry

	if not filesystem.exists(path) then
		return "missing"
	end

	local recorded = files[path]
	if recorded == nil then
		return "unknown"
	end

	return "ok"
end

Diagnostics.commands["thean-check"] = {
	usage = "thean-check [--full]",
	desc = t("theanCheckDesc", "verify the system against the update manifest"),
	run = function(context, args)
		local full = args[1] == "--full"

		local manifest = readTable(LOCAL_MANIFEST)
		if type(manifest) == "table" then manifest = manifest.files end

		if type(manifest) ~= "table" then
			-- No baseline yet: fall back to the published one so the check is
			-- still useful, but say plainly that it is not authoritative.
			context:warn(t("noBaseline", "No local manifest at %s."):format(LOCAL_MANIFEST))
			context:warn(t("fetchingRemote", "Fetching the published manifest instead..."))

			local body, reason = internet.request(MANIFEST_URL)
			if not body then
				context:err(t("checkUnreachable", "Could not fetch the manifest: %s"):format(reason or "?"))
				return
			end

			local chunk = load("return " .. body, "=manifest")
			manifest = chunk and chunk() or nil
			if type(manifest) == "table" then manifest = manifest.files end
		end

		if type(manifest) ~= "table" then
			context:err(t("checkBadManifest", "The manifest could not be read."))
			return
		end

		local missing, unknown, present, bytes = 0, 0, 0, 0

		for path in pairs(manifest) do
			local state = classify(context, manifest, path)

			if state == "missing" then
				missing = missing + 1
				context:out(("  %s  %s"):format(t("stateMissing", "MISSING"), path), COLOR.error)
			elseif state == "unknown" then
				unknown = unknown + 1
			else
				present = present + 1
				bytes = bytes + (filesystem.size(path) or 0)
			end
		end

		-- Files present on disk that the manifest does not mention. Only reported
		-- in --full mode, because user documents legitimately live under /Users.
		if full then
			local function walk(path, depth)
				if depth > 4 then return end

				for _, name in ipairs(filesystem.list(path) or {}) do
					local child = path .. name

					if manifest[child] == nil and child:sub(1, 7) ~= "/Users/" then
						context:dim("  EXTRA  " .. child)
					end

					if filesystem.isDirectory(child) then
						walk(child, depth + 1)
					end
				end
			end

			walk("/", 1)
		end

		context:out("")

		if missing == 0 then
			context:ok(t("checkClean", "All %d manifest files are present (%s)."):format(present, humanSize(bytes)))
		else
			context:err(t("checkBroken", "%d of %d manifest files are missing."):format(missing, present + missing))
			context:dim(t("checkRepair", "Run Settings -> System update to repair them."))
		end

		if unknown > 0 then
			context:dim(t("checkUnknown", "%d extra file(s) on disk are not in the manifest."):format(unknown))
		end

		-- Disk headroom, which is the other thing that quietly breaks a system.
		local proxy = filesystem.getProxy("/")
		if proxy then
			local total, used = proxy.spaceTotal(), proxy.spaceUsed()

			context:out("")
			context:out(t("checkDisk", "Disk: %s used of %s"):format(humanSize(used), humanSize(total)))

			if total > 0 and (total - used) / total < 0.1 then
				context:warn(t("checkLowDisk", "Less than 10% free."))
			end
		end
	end,
}

--------------------------------------------------------------------------------
-- Shell configuration: alias, export, tldr
--------------------------------------------------------------------------------

-- These operate on the same state the shell reads at startup, so they take
-- effect on the next command rather than needing a restart.
Diagnostics.commands.alias = {
	usage = "alias [name=value...]",
	desc = t("aliasDesc", "define a command shortcut"),
	run = function(context, args)
		local shellState = COMMANDS.state

		if #args == 0 then
			local names = {}
			for name in pairs(shellState.aliases) do names[#names + 1] = name end
			table.sort(names)

			if #names == 0 then
				context:dim(t("noAliases", "No aliases defined."))
				return
			end

			for _, name in ipairs(names) do
				context:out(("alias %s='%s'"):format(name, shellState.aliases[name]))
			end

			return
		end

		for _, pair in ipairs(args) do
			local name, value = pair:match("^([%w_%-]+)=(.*)$")

			if name then
				shellState.aliases[name] = value
				context:ok(("alias %s='%s'"):format(name, value))
			else
				local existing = shellState.aliases[pair]
				if existing then
					context:out(("alias %s='%s'"):format(pair, existing))
				else
					context:err(("alias: %s: not a name=value pair"):format(pair))
				end
			end
		end

		COMMANDS.saveState()
	end,
}

Diagnostics.commands.export = {
	usage = "export [NAME=value...]",
	desc = t("exportDesc", "set an environment variable"),
	run = function(context, args)
		local shellState = COMMANDS.state

		if #args == 0 then
			local names = {}
			for name in pairs(shellState.environment) do names[#names + 1] = name end
			table.sort(names)

			for _, name in ipairs(names) do
				context:out(("%s=%s"):format(name, shellState.environment[name]))
			end

			return
		end

		for _, pair in ipairs(args) do
			local name, value = pair:match("^([%w_]+)=(.*)$")

			if name then
				shellState.environment[name] = value
				context:ok(("%s=%s"):format(name, value))
			else
				context:err(("export: %s: not a NAME=value pair"):format(pair))
			end
		end

		COMMANDS.saveState()
	end,
}

-- Short examples, tldr style. Kept small on purpose: a wall of text on a
-- 25-row screen is less useful than one example per command.
Diagnostics.commands.tldr = {
	usage = "tldr <command> [example...]",
	desc = t("tldrDesc", "show a short example for a command"),
	run = function(context, args)
		if not args[1] then
			context:dim(t("tldrUsage", "usage: tldr <command>"))
			return
		end

		local command = COMMANDS.commands[args[1]]
		if not command then
			context:err(("tldr: %s: unknown command"):format(args[1]))
			return
		end

		-- With extra words this records an example rather than showing one, which
		-- avoids a separate write-only command.
		if args[2] then
			local words = {}
			for i = 2, #args do words[#words + 1] = args[i] end

			COMMANDS.state.tldr[args[1]] = table.concat(words, " ")
			COMMANDS.saveState()

			context:ok(t("tldrStored", "Example recorded for %s."):format(args[1]))
			return
		end

		local example = COMMANDS.state.tldr[args[1]]

		context:heading(("%s -- %s"):format(args[1], command.desc or ""))
		context:accent(("usage: %s"):format(command.usage or args[1]))

		if example then
			context:out("")
			context:out(("  %s"):format(example), COLOR.ok)
		else
			context:out("")
			context:dim(t("tldrNone", "No example recorded. Add one with: tldr <command> an example"))
		end
	end,
}

--------------------------------------------------------------------------------

return Diagnostics
