-- Boot resilience tests.
--
-- Verifies the firmware and OS degrade gracefully when hardware is missing,
-- instead of crashing or showing a blue kernel-panic screen:
--   * no GPU / screen  -> text fallback, no crash
--   * no filesystems   -> "no bootable device", no crash
--   * OS.lua with no EEPROM and no GPU -> returns cleanly, no crash
--
-- Run from the repository root:  lua5.3 Tools/tests/boot_resilience.lua

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

local function read(path)
	local f = assert(io.open(rootPath .. "/" .. path))
	local text = f:read("*a")
	f:close()
	return text
end

local errHandler = function(m) return debug.traceback(m, 2) end

-- ---------------------------------------------------------------------------
-- Stub environment builder
-- ---------------------------------------------------------------------------

-- kind:
--   "nogpu"        - no gpu/screen, one filesystem with /OS.lua
--   "nofs"         - gpu+screen, no filesystems
--   "noeepromnogpu"- no eeprom, no gpu, no filesystems

local function makeProxy(address, hasOS)
	local proxy = {
		address = address,
		getLabel = function() return "Test Disk" end,
		isReadOnly = function() return false end,
		spaceTotal = function() return 4 * 1024 * 1024 end,
		spaceUsed = function() return 0 end,
		exists = function() return false end,
		read = function() return nil end,
		close = function() end,
	}
	local osContentReturned = false
	if hasOS then
		proxy.exists = function(p) return p == "/OS.lua" or p == "/EFI/Stub.lua" end
		proxy.open = function(p)
			if p == "/OS.lua" then
				return { close = function() end }
			end
			return nil
		end
		proxy.read = function(handle, count)
			if not osContentReturned then
				osContentReturned = true
				return 'print("os loaded")'
			end
			return nil
		end
	end
	return proxy
end

local function buildEnv(kind)
	local pullCount = 0
	local gpu = {
		bind = function() end, setDepth = function() end,
		getResolution = function() return 80, 25 end, getDepth = function() return 8 end,
		maxResolution = function() return 80, 25 end,
		setBackground = function() end, fill = function() end,
		setForeground = function() end, set = function() end,
	}
	local screen = { getResolution = function() return 80, 25 end }
	local eeprom = {
		getLabel = function() return "TheanOS EFI" end, getData = function() return "" end,
		setData = function() end, get = function() return "-- stub" end,
		set = function() return true end, setLabel = function() end,
	}
	local filesystems = {}
	if kind ~= "nofs" and kind ~= "noeepromnogpu" then
		filesystems = { makeProxy("fs0", true) }
	end
	local listResults = {}
	local function singleIterator(value)
		local emitted = false
		return function()
			if not emitted then
				emitted = true
				return value
			end
			return nil
		end
	end
	if kind ~= "nogpu" and kind ~= "noeepromnogpu" then
		listResults.gpu = singleIterator("gpu0")
		listResults.screen = singleIterator("screen0")
	else
		listResults.gpu = singleIterator(nil)
		listResults.screen = singleIterator(nil)
	end
	if kind ~= "noeepromnogpu" then
		listResults.eeprom = singleIterator("eeprom0")
	else
		listResults.eeprom = singleIterator(nil)
	end
	listResults.filesystem = function()
		local i = 0
		return function()
			i = i + 1
			return filesystems[i] and filesystems[i].address or nil
		end
	end

	-- component.list(kind) returns an iterator function (fresh each call).
	local function list(kind)
		local factory = listResults[kind]
		if type(factory) == "function" then
			-- gpu/screen/eeprom are already iterators; filesystem is a factory.
			if kind == "filesystem" then
				return factory()
			end
			return factory
		end
		return function() return nil end
	end

	local proxyMap = { gpu0 = gpu, screen0 = screen, eeprom0 = eeprom }
	for i = 1, #filesystems do proxyMap[filesystems[i].address] = filesystems[i] end

	local pullIndex = 0
	local pullScript = {}
	local function pullSignal(timeout)
		pullCount = pullCount + 1
		pullIndex = pullIndex + 1
		local step = pullScript[pullIndex]
		if type(step) == "table" then return table.unpack(step) end
		return nil
	end

	local computer = {
		pullSignal = pullSignal,
		uptime = function() return pullCount * 0.05 end,
		getBootAddress = function() return "fs0" end,
		setBootAddress = function() end,
		shutdown = function() error("HALTED", 0) end,
		totalMemory = function() return 64 * 1024 end,
		beep = function() end,
	}
	local unicode = {
		char = function(c) return string.char(c) end,
		len = function(s) return #s end,
		sub = function(s, i, j) return string.sub(s, i, j) end,
	}
	local out = {}
	local env = setmetatable({
		component = {
			list = list,
			proxy = function(address) return proxyMap[address] end,
			invoke = function(address, method, ...)
				local p = proxyMap[address]
				if p and p[method] then return p[method](p, ...) end
				return nil
			end,
			isAvailable = function() return false end,
		},
		computer = computer, gpu = gpu, screen = screen, unicode = unicode,
		debug = { traceback = function(m) return tostring(m) end },
		io = nil, os = nil,
	}, { __index = _G })
	env.print = function(text)
		out[#out + 1] = tostring(text)
		print("  [os] " .. tostring(text))
	end
	return env, pullScript, out
end

-- Runs `source` in a custom env with the given pullSignal script. Returns ok.
local function runInEnv(source, name, kind, script)
	local env, pullScript, out = buildEnv(kind)
	pullScript = script
	local chunk, loadReason = load(source, name, "t", env)
	if not chunk then
		print("   compile failed: " .. tostring(loadReason))
		return false, loadReason
	end
	local ok, reason = xpcall(chunk, errHandler)
	print(("   pcall ok: %s"):format(tostring(ok)))
	if not ok then print("   reason: " .. tostring(reason)) end
	if not ok then
		for _, line in ipairs(out) do print("   console: " .. line) end
	end
	return ok, reason
end

print("== Boot.lua: no GPU (text fallback) ==")
do
	local source = read("EFI/Boot.lua")
	-- No GPU, one filesystem: bindScreen fails -> textFallback -> no disks ready
	-- (fs0 has /OS.lua but textFallback lists it). pullSignal(5) -> nil -> exit.
	local ok = runInEnv(source, "Boot", "nogpu", { { nil } })
	check("Boot.lua no-GPU text fallback does not crash", ok)
end

print("== Boot.lua: no filesystems ==")
do
	local source = read("EFI/Boot.lua")
	-- GPU present, no filesystems -> bootNormally -> "No bootable device"
	-- pullSignal() blocks waiting for a key; script returns nil to end it.
	local ok = runInEnv(source, "Boot", "nofs", { { nil } })
	check("Boot.lua no-filesystems does not crash", ok)
end

print("== OS.lua: no EEPROM and no GPU ==")
do
	local source = read("OS.lua")
	-- No eeprom, no gpu, no filesystem: resolveBootProxy returns nil,
	-- then no GPU -> message + pullSignal(5) -> return.
	local ok = runInEnv(source, "OS", "noeepromnogpu", { { nil } })
	check("OS.lua no-EEPROM/no-GPU does not crash", ok)
end

print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
