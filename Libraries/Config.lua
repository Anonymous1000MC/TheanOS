-- Centralized configuration store.
--
-- All appearance and behavior values are read through get()/set() and persisted
-- to disk as a single serialized table, so they live in one place instead of
-- being hardcoded across the codebase. Values survive reboots.
--
-- Intended for incremental adoption: new code reads preferences through Config,
-- while the legacy userSettings table in System.lua keeps working unchanged.

local filesystem = require("Filesystem")
local paths = require("Paths")

local Config = {}

local settings = {}
local loaded = false

local function load()
	if loaded then return settings end
	local ok, data = pcall(function()
		return filesystem.readTable(paths.user.settings)
	end)
	if ok and type(data) == "table" then
		settings = data
	else
		settings = {}
	end
	loaded = true
	return settings
end

local function save()
	load()
	local ok, reason = pcall(function()
		filesystem.writeTable(paths.user.settings, settings, true)
	end)
	return ok, reason
end

-- Returns the value for key, or default when unset.
function Config.get(key, default)
	load()
	local value = settings[key]
	if value == nil then return default end
	return value
end

-- Stores key/value in memory; call Config.save() to persist.
function Config.set(key, value)
	load()
	settings[key] = value
end

-- Persists all in-memory changes to disk.
function Config.save() return save() end

-- Discards the in-memory cache and reloads from disk.
function Config.reload()
	loaded = false
	return load()
end

-- Returns the entire settings table (loads first if needed).
function Config.all()
	load()
	return settings
end

return Config
