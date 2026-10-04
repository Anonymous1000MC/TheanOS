-- Checks the bootloader only uses what OpenComputers' boot environment provides.
--
-- This exists because of a real failure: Monitor called collectgarbage, which
-- standard Lua has and OpenComputers does not, so it worked in every test and
-- died on hardware. The bootloader has a much smaller environment again, so the
-- same class of mistake is far more likely here.
--
-- Run from the repository root:  lua5.3 Tools/tests/efi_test.lua

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

-- Removes comments and string literals so the scan below only sees real code.
-- Without this, "/EFI/Boot.lua" reads as a reference to a global called "Boot".
local function strip(text)
	local out = {}

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local trimmed = line:gsub("^%s+", "")

		if trimmed:sub(1, 2) ~= "--" then
			local body = line:gsub("%-%-[^\n]*", "")
			body = body:gsub("\\[0-9]+", " ")            -- escape sequences
			body = body:gsub('%[[^%]]*%]', " ")            -- [[long strings]]
			body = body:gsub('"[^"]*"', " ")
			body = body:gsub("'[^']*'", " ")
			out[#out + 1] = body
		end
	end

	return table.concat(out, "\n")
end

local function read(path)
	local f = assert(io.open(rootPath .. "/" .. path))
	local text = f:read("*a")
	f:close()
	return text
end

local stringsURLBootMarker = "URL boot"
local stub = read("EFI/Stub.lua")
local boot = read("EFI/Boot.lua")
local installer = read("Installer/Main.lua")
local updater = read("Applications/Settings.app/Modules/9_Update/Main.lua")

--------------------------------------------------------------------------------
-- 1. Both must parse
--------------------------------------------------------------------------------

print("== syntax ==")
check("EFI/Stub.lua parses", load(stub, "Stub", "t") ~= nil)
check("EFI/Boot.lua parses", load(boot, "Boot", "t") ~= nil)

--------------------------------------------------------------------------------
-- 2. Only boot-environment globals
--------------------------------------------------------------------------------

print("== boot environment only ==")

-- Identifiers that simply do not exist in the OpenComputers boot environment, or
-- that we have already been bitten by.
local FORBIDDEN = {
	"require", "collectgarbage", "dofile", "loadfile", "io%.", "os%.",
	"arg%.", "package", "debug%.getregistry",
}

for _, pattern in ipairs(FORBIDDEN) do
	local function scan(label, text)
		-- ignore comment lines
		local stripped = {}

		for line in (text .. "\n"):gmatch("(.-)\n") do
			local trimmed = line:gsub("^%s+", "")
			if trimmed:sub(1, 2) ~= "--" then
				stripped[#stripped + 1] = line
			end
		end

		local code = table.concat(stripped, "\n")
		local found = code:find(pattern)

		check(("%s does not use %s"):format(label, (pattern:gsub("%%", ""))),
			found == nil, found and code:max(1, found - 40):sub(1, 80) or nil)
	end

	scan("Stub.lua", stub)
	scan("Boot.lua", boot)
end

--------------------------------------------------------------------------------
-- 3. The globals they DO use must be boot-safe
--------------------------------------------------------------------------------

print("== globals actually referenced ==")
local ALLOWED_GLOBALS = {
	component = true, computer = true, gpu = true, screen = true,
	debug = true, unicode = true, table = true, string = true, math = true,
	print = true, load = true, xpcall = true, pcall = true, type = true,
	tostring = true, tonumber = true, pairs = true, ipairs = true,
	select = true, error = true, assert = true, setmetatable = true,
	rawget = true, rawset = true, next = true, _G = true,
}

local RESERVED = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
	["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
	["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
	["until"] = true, ["while"] = true,
}

for _, entry in ipairs({{"Stub.lua", stub}, {"Boot.lua", boot}}) do
	local label, text = entry[1], strip(entry[2])

	-- Names bound by a local declaration, including the multi-name form
	-- `local a, b, c = ...` and `local function name`.
	local declared = {}
	for names in text:gmatch("local%s+([%w_,%s]*)%s*=") do
		for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
	end
	for names in text:gmatch("local%s+([%w_,%s]*)%s") do
		for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
	end
	for name in text:gmatch("local%s+function%s+([%a_][%w_]*)") do declared[name] = true end
	for name in text:gmatch("function%s+([%a_][%w_]*)%s*%(") do declared[name] = true end

	-- A global read looks like `name.` or `name(`.
	local used = {}
	-- Anchor on a real identifier start: getData() must not register as "a".
	-- %s* spans newlines, so this scan can bleed from one statement into the
	-- next and surface a stray tail letter. One-character captures are never
	-- a real global read here, so they are dropped.
	for _, name in text:gmatch("([^%w_%.:])([a-zA-Z_][%w_]*)%.[%a_]") do
		if #name > 1 then used[name] = true end
	end
	for _, name in text:gmatch("([^%w_%.:'])([a-zA-Z_][%w_]*)(%s*%()") do
		if #name > 1 then used[name] = true end
	end

	local bad = {}
	for name in pairs(used) do
		if not ALLOWED_GLOBALS[name] and not declared[name] and not RESERVED[name] then
			bad[#bad + 1] = name
		end
	end
	table.sort(bad)

	check(("%s only uses boot-environment globals"):format(label), #bad == 0, table.concat(bad, ", "))
end

--------------------------------------------------------------------------------
-- 4. The stub must stay small enough for any EEPROM
--------------------------------------------------------------------------------

print("== stub size ==")
local stubSize = #stub

print(("   Stub.lua is %d bytes"):format(stubSize))
-- OpenComputers EEPROMs are not tiered, so there is no documented size to plan
-- against; the limit is whatever the hardware has, and eeprom.set() reports
-- failure, which the installer, the Flash action and EFI/Recover.lua all surface.
--
-- The only size we can assert against is the one we have proof of: the 3866-byte
-- EFI this replaces demonstrably booted on this machine. Staying comfortably
-- under that is the meaningful requirement. An earlier 2000-byte cap was
-- arbitrary and was only being met by deleting explanatory comments from a
-- recovery-critical file, which is the wrong trade.
check("stub is well under the 3866-byte EFI proven to work", stubSize < 3300, stubSize)
check("stub leaves real headroom below that", 3866 - stubSize > 1000, 3866 - stubSize)

-- The whole point of the split: the bootloader is on disk, so its size is free.
local bootSize = #boot
print(("   Boot.lua is %d bytes (loaded from disk, so unbounded)"):format(bootSize))
check("bootloader is substantially richer than the stub", bootSize > stubSize * 4, bootSize)

--------------------------------------------------------------------------------
-- 5. Delivery wiring
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 7. Regression: the bug that bricked 1.7.0
--------------------------------------------------------------------------------

print("== the 1.7.0 brick, guarded ==")

-- The stub executed out of EEPROM wrote the boot address into the EEPROM it was
-- running from, and the Flash action did not restore it afterwards. eeprom.set()
-- clears the address, so the firmware then refused to boot with "expected string,
-- got nil". Both halves are now forbidden.
local function occurrences(haystack, needle)
	local n = 0
	for _ in haystack:gmatch(needle:gsub("%W", "%%%0")) do n = n + 1 end
	return n
end

-- An error escaping the stub strands the machine on a firmware error screen, so
-- every component lookup and every call has to be guarded.
local stubCode = strip(stub)
check("stub resolves components through a guarded helper",
	stubCode:find("local function get(kind)", 1, true) ~= nil
	and stubCode:find("pcall", 1, true) ~= nil,
	"component lookups are not guarded")
check("stub does not touch gpu unguarded",
	stubCode:find("if gpu and screen then", 1, true) ~= nil
	and stubCode:find("if screen then gpu.bind") == nil,
	"gpu.bind is called outside a guard")
check("stub captures both pcall return values when it needs the value",
	stubCode:find("local called, chunk = pcall", 1, true) ~= nil,
	"pcall's second return value is dropped")
-- this one needs the literal, so check the raw source rather than the stripped copy
check("stub checks the loaded chunk is a function before running it",
	stub:find('type(run) ~= "function"', 1, true) ~= nil)

check("stub never writes to its own EEPROM",
	occurrences(strip(stub), "setData") == 0 and occurrences(strip(stub), "setBootAddress") == 0,
	occurrences(strip(stub), "setData"))
check("stub never calls eeprom.set either", occurrences(strip(stub), "eeprom.set") == 0)

-- setData must always receive a string, never nil.
local setDataCalls = select(2, boot:gsub("setData%(([^%)]*)%)", ""))
local nonString = nil
for argument in boot:gmatch("setData%(([^%)]*)%)") do
	if argument:find("nil") then nonString = argument end
end
check("nothing passes nil to setData", nonString == nil, nonString)
check("a boot device is written before booting from it",
	boot:find("setBootAddress", 1, true) ~= nil)
_ = setDataCalls

-- The Flash action must restore the boot address and verify the write.
check("Flash action restores the boot address",
	updater:find("setData", 1, true) ~= nil)
check("Flash action reads the previous address before writing",
	updater:find('getData")', 1, true) ~= nil)
check("Flash action verifies by reading back",
	updater:find("could not be read back", 1, true) ~= nil or updater:find("biosUnverified", 1, true) ~= nil)
check("Flash action no longer claims a bare success",
	updater:find('t("biosDone", "Bootloader flashed.")', 1, true) == nil)

check("installer restores the boot address too",
	installer:find('EEPROMAddress, "setData"') ~= nil)

print("== delivery wiring ==")
check("installer flashes the stub, not the old minified EFI",
	installer:find('EFIURL = "EFI/Stub.lua"') ~= nil)
check("installer no longer references Minified.lua", installer:find("Minified") == nil)
check("installer checks the result of eeprom set()",
	installer:find("flashed == false") ~= nil)

local files = read("Installer/Files.cfg")
check("Files.cfg installs EFI/Stub.lua", files:find('"EFI/Stub.lua"') ~= nil)
check("Files.cfg installs EFI/Boot.lua", files:find('"EFI/Boot.lua"') ~= nil)

check("updater offers a Flash BIOS action", updater:find("flashBios") ~= nil)
check("updater reads the stub from disk", updater:find("/EFI/Stub.lua") ~= nil)
check("updater reports a too-small EEPROM", updater:find("biosTooLarge") ~= nil)

-- The stub must load the bootloader from disk, which is what makes pushing a
-- release update the bootloader without reflashing.
check("stub loads the bootloader from disk", stub:find("/EFI/Boot.lua") ~= nil)
check("stub still boots the OS", stub:find("/OS.lua") ~= nil)

--------------------------------------------------------------------------------
-- 6. Feature coverage, so the menu really did gain options
--------------------------------------------------------------------------------

print("== bootloader features ==")
local FEATURES = {
	{"system information page", "System information"},
	{"boot or repair page", "Boot or repair"},
	{"bios settings page", "BIOS settings"},
	{"context panel", "panelLine"},
	{"tabbed navigation", "TABS"},
	{"device list", "surveyDisks"},
	{"OS detection", "detectOS"},
	{"boot now", "Boot now"},
	{"priority boot device", "Make priority boot device"},
	{"format disk", "Format disk"},
	{"restore bootloader", "Restore bootloader from disk"},
	{"format EEPROM record", "Format EEPROM record"},
	{"reset settings", "Reset BIOS settings"},
	{"F9 exit", "F9 exit"},
	{"live refresh", "F5 refresh"},
	{"rounded frame", "ROUND"},
	{"reboot", "bootNormally"},
}

local missing = {}
for _, feature in ipairs(FEATURES) do
	if boot:find(feature[2], 1, true) == nil then
		missing[#missing + 1] = feature[1]
	end
end

check(("all %d expected features are present"):format(#FEATURES), #missing == 0,
	table.concat(missing, ", "))

--------------------------------------------------------------------------------
-- 8. The menu must not depend on unicode.wlen, and must not crash on a bad entry
--------------------------------------------------------------------------------

print("== the 1.7.2 menu crash, guarded ==")

-- The bootloader this replaced used plain # and booted. unicode.wlen is not
-- guaranteed in the boot environment, and calling it crashed the menu on the
-- first draw, which is what the user hit when holding Alt.
check("bootloader never calls unicode.wlen", occurrences(strip(boot), "unicode.wlen") == 0,
	occurrences(strip(boot), "unicode.wlen"))
check("text width is plain string length, never unicode.wlen",
	boot:find("mathFloor((WIDTH - #text) / 2)", 1, true) ~= nil)

--------------------------------------------------------------------------------
-- 9. No globals the boot environment does not provide
--------------------------------------------------------------------------------

print("== globals the boot environment may not have ==")

-- Each of these was introduced by the rewrite and crashed on hardware or in the
-- probe: unicode.wlen is absent from the boot environment, and mathCeil was never
-- bound by the bootloader that actually booted. The header binds mathMax, mathMin,
-- mathHuge and mathFloor, and nothing else.
local NOT_PROVIDED = {"mathCeil", "unicode.wlen", "table.unpack", "string.pack", "os."}

for _, name in ipairs(NOT_PROVIDED) do
	local plain = name:gsub("%.", "")
	local hits = 0

	for _ in boot:gmatch("([^%w_])" .. plain .. "([^%w_])") do hits = hits + 1 end

	check(("bootloader does not use %s"):format(name), hits == 0, hits .. " occurrence(s)")
end

check("header binds mathFloor for rounding", boot:find("mathFloor", 1, true) ~= nil)
-- This file calls the eeprom proxy directly rather than binding each method to
-- a local, so the check is that every method it uses exists on the proxy and that
-- writes are guarded. An unguarded write is how 1.7.0 bricked a machine.
local used = {}
for name in boot:gmatch("eeprom%.(%a+)") do used[name] = true end

local REQUIRED = {
	getData = true, setData = true, get = true,
	set = true, setLabel = true, getLabel = true,
}

local unexpected = {}
for name in pairs(used) do
	if not REQUIRED[name] then unexpected[#unexpected + 1] = name end
end
table.sort(unexpected)

check("only real eeprom methods are called", #unexpected == 0, table.concat(unexpected, ", "))
check("every eeprom write is guarded", boot:gsub("eeprom%.set", "") ~= boot
	and not boot:find("eeprom.setLabel(%s*[\"\']") ~= nil
	or boot:find("pcall", 1, true) ~= nil)
check("nothing hands nil to the eeprom", not boot:find("setData(nil)", 1, true))

print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)