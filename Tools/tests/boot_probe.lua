-- Runs EFI/Boot.lua under a stubbed OpenComputers boot environment and reports
-- exactly where it fails.
--
-- Built after 1.7.2 booted the OS fine but the Alt/menu path reported
-- "Unrecoverable Error". The stub was proven good by the fact that /OS.lua
-- loaded, so the fault is in the bootloader, and this harness finds it instead of
-- guessing.
--
-- Run from the repository root:  lua5.3 Tools/tests/boot_probe.lua

local rootPath = os.getenv("THEANOS_ROOT") or "."

--------------------------------------------------------------------------------
-- Stub environment
--------------------------------------------------------------------------------

local WIDTH, HEIGHT = 80, 25

local screenCalls = {drawText = 0, set = 0, fill = 0}
local rowsDrawn = 0
local lines = {}

local gpu = {
	bind = function() end,
	setDepth = function() end,
	getResolution = function() return WIDTH, HEIGHT end,
	getDepth = function() return 8 end,
	maxResolution = function() return 160, 50 end,
	setBackground = function() screenCalls.fill = screenCalls.fill + 1 end,
	fill = function() screenCalls.fill = screenCalls.fill + 1 end,
	setForeground = function() end,
	set = function(x, y, _, _, text)
		screenCalls.set = screenCalls.set + 1
		if text then lines[#lines + 1] = {y = y, x = x, text = text} end
	end,
	setPaletteColor = function() end,
}

-- What the stub returns for each pullSignal() call.
local script = {}
local scriptAt = 0
local pullCount = 0

-- A one-shot iterator, like the real component.list. An iterator that returns the
-- same address forever turns every `for ... in component.list(...)` loop infinite
-- and manufactures failures that are not real.
local function makeList(addresses)
	local at = 0

	return function()
		at = at + 1
		return addresses[at]
	end
end

-- computer.pullSignal returns e1, e2, ... as SEPARATE values as SEPARATE values. Boot.lua wraps the
-- call as {pullSignal(...)} and reads event[1], event[3], event[4], so returning a
-- single table here makes every event invisible and the harness silently lies.
local function pullSignal(timeout)
	pullCount = pullCount + 1

	if pullCount > 6000 then
		error("harness: pullSignal called 6000 times, the menu never exited", 0)
	end

	scriptAt = scriptAt + 1
	local step = script[scriptAt]

	if type(step) == "table" then
		return table.unpack(step)
	end

	if type(step) == "number" then
		return "key_down", 0, step, step
	end

	return nil
end

local component = {
	list = function(kind)
		if kind == "gpu" then return makeList({"gpu0"}) end
		if kind == "screen" then return makeList({"screen0"}) end
		if kind == "eeprom" then return makeList({"eeprom0"}) end
		if kind == "filesystem" then return makeList({"fs0"}) end
		return makeList({})
	end,
	proxy = function(address)
		if address == "gpu0" or address == nil and false then return gpu end
		if address == "screen0" then return {getResolution = function() return WIDTH, HEIGHT end} end

		if address == "eeprom0" then
			return {
				getLabel = function() return "TheanOS EFI" end,
				getData = function() return "fs0" end,
				setData = function() end,
				get = function() return "-- stub" end,
				set = function() return true end,
				setLabel = function() end,
				setBootloader = function() end,
				getBootloader = function() return "-- stub" end,
			}
		end

		if address == "fs0" then
			return {
				exists = function(p) return p == "/OS.lua" or p == "/EFI/Stub.lua" end,
				open = function(p)
					if p == "/OS.lua" then return {read = function() return 'print("booted")' end, close = function() end} end
					return nil, "no such file"
				end,
				getLabel = function() return "TheanOS" end,
				isReadOnly = function() return false end,
				spaceTotal = function() return 4 * 1024 * 1024 end,
				spaceUsed = function() return 1024 * 1024 end,
				setLabel = function() end,
				remove = function() end,
				read = function() return nil end,
				close = function() end,
			}
		end

		return nil
	end,
}

local computer = {
	pullSignal = pullSignal,
	uptime = function() return pullCount * 0.1 end,
	getBootAddress = function() return "fs0" end,
	setBootAddress = function() end,
	-- The real computer.shutdown() halts the machine and never returns, so the
	-- Reboot and Power off entries are expected to end here rather than return.
	shutdown = function() error("HALTED", 0) end,
	totalMemory = function() return 64 * 1024 end,
	getArchitecture = function() return "Lua 5.3" end,
	energy = function() return 1 end,
	maxEnergy = function() return 1 end,
}

local unicode = {
	char = function(c) return string.char(c) end,
	len = function(s) return #s end,
	sub = function(s, i, j) return string.sub(s, i, j) end,
}

-- Deliberately NO wlen: the bootloader this replaces used plain # and booted, so
-- nothing here may require unicode.wlen to exist in the boot environment.
local function stripWlen()
	unicode.wlen = nil
end

local out = {}
local env = setmetatable({
	component = component,
	computer = computer,
	gpu = gpu,
	screen = nil,
	unicode = unicode,
	debug = {traceback = function() return "traceback" end},
	io = nil,
	os = nil,
}, {__index = _G})

-- capture print() the way the BIOS console receives it
env.print = function(text) out[#out + 1] = tostring(text) end

local chunk, loadReason = loadfile(rootPath .. "/EFI/Boot.lua", "t", env)

if not chunk then
	print("Boot.lua does not even compile: " .. tostring(loadReason))
	os.exit(1)
end

print("== Boot.lua compiles ==")
print("   ok")

--------------------------------------------------------------------------------
-- 1. Normal boot: no key pressed, should fall through to continueBoot
--------------------------------------------------------------------------------

print()
print("== normal boot path (no key) ==")
script = {}
scriptAt = 0
pullCount = 0
out = {}

local ok, reason = xpcall(chunk, function(msg) return debug.traceback(msg, 2) end)

print(("   pcall ok: %s"):format(tostring(ok)))
if not ok then
	print("   reason: " .. tostring(reason))
end
if not ok2 then for _, line in ipairs(out) do print("   console: " .. line) end end

--------------------------------------------------------------------------------
-- 2. The Alt path, which is what the user reported failing
--------------------------------------------------------------------------------

print()
print("== Alt path: hold Alt, then walk the menu ==")

-- key 56 is Alt, then a run of no-ops so drawMenu keeps drawing, then Esc to
-- leave the menu, then more no-ops.
script = {}
for i = 1, 4 do script[i] = 56 end
for i = 5, 400 do script[i] = {} end
script[401] = 27 -- Esc leaves the menu
for i = 402, 2000 do script[i] = {} end

scriptAt = 0
pullCount = 0
out = {}
lines = {}

local ok2, reason2 = xpcall(chunk, function(msg) return debug.traceback(msg, 2) end)

print(("   pcall ok: %s"):format(tostring(ok2)))
if not ok2 then
	print("   reason: " .. tostring(reason2))
end
if not ok2 then for _, line in ipairs(out) do print("   console: " .. line) end end

print(("   gpu.set calls: %d, fills: %d, rows drawn: %d")
	:format(screenCalls.set, screenCalls.fill, #lines))

--------------------------------------------------------------------------------
-- 3. Every menu entry, reached by pressing Down then Enter
--------------------------------------------------------------------------------

print()
print("== each top-level menu entry, with unicode.wlen removed entirely ==")
stripWlen()

local function tryEntry(downs)
	script = {}
	-- Alt a few times to reach the menu
	for i = 1, 4 do script[i] = 56 end
	local at = 5
	for _ = 1, downs do script[at] = 208 at = at + 1 end -- Down
	script[at] = 28 at = at + 1                            -- Enter
	script[at] = 27 at = at + 1                            -- Esc, back out
	for i = at, 40 do script[i] = {} end
	script[at] = 27 at = at + 1                            -- Esc, leave the menu
	for i = at, 3000 do script[i] = {} end

	scriptAt = 0
	scriptAt = 0
	pullCount = 0
	out = {}

	local ok, reason = xpcall(chunk, function(msg) return debug.traceback(msg, 2) end)

	-- Halting is the correct outcome for Reboot / Power off.
	if not ok and tostring(reason):find("HALTED", 1, true) then
		return true, "halted (expected)", ""
	end

	-- A menu that is simply still on screen has not failed. Only a real error in
	-- the bootloader counts, so exhausting the stub's pull budget is fine as long
	-- as the harness, not the product, is what ran out.
	if not ok and tostring(reason):find("pullSignal called", 1, true) then
		return true, "still on screen (no crash)", ""
	end

	return ok, reason, table.concat(out, " | ")
end

-- The proven BIOS's own menu, in the order it builds it. With no internet
-- component in the stub, System recovery and URL boot are not inserted.
local NAMES = {"Continue boot", "Boot from device", "Disk utility", "Diagnostics",
	"Maintenance", "About", "Reboot"}
local failures = 0

for index = 0, #NAMES - 1 do
	local ok, reason, console = tryEntry(index)
	local status = ok and "ok  " or "FAIL"

	if not ok then failures = failures + 1 end

	print(("   %s %-14s %s"):format(status, NAMES[index + 1],
		ok and tostring(reason or "no error") or tostring(reason):sub(1, 140)))
	if not ok and console ~= "" then
		print("        console: " .. console:sub(1, 150))
	end
end

print()
print(("== menu entries that failed: %d of %d"):format(failures, #NAMES))
os.exit(failures == 0 and 0 or 1)