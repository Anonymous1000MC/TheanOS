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
	for name in text:gmatch("[^%w_%.:]([a-zA-Z_][%w_]*)%.[%a_]") do used[name] = true end
	for name in text:gmatch("[^%w_%.:]([a-zA-Z_][%w_]*)(%s*%()") do used[name] = true end

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
-- failure, which both the installer and the Flash BIOS dialog check and surface.
--
-- The assertion is therefore deliberately modest: small enough to fit a 2 KB
-- EEPROM with room to spare, and comfortably smaller than the 3866-byte EFI this
-- replaces (which demonstrably worked, so it is a proven floor for this machine).
check("stub fits a 2 KB EEPROM with margin", stubSize <= 2000, stubSize)
-- The meaningful claim is simply that the stub is smaller than the 3866-byte EFI
-- it replaces, which is proven to work on this machine. A tighter ratio would be
-- an invented number.
check("stub is smaller than the EFI it replaces (3866 B)", stubSize < 3866, stubSize)

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
check("setBootAddress coerces to a string",
	boot:find('type(address) == "string"', 1, true) ~= nil)
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
	{"boot menu", "Boot menu"},
	{"disk utility", "Disk utility"},
	{"diagnostics", "Diagnostics"},
	{"maintenance", "Maintenance"},
	{"tools", "Tools"},
	{"about", "About"},
	{"memory report", "Memory"},
	{"graphics report", "Graphics"},
	{"eeprom report", "Eeprom"},
	{"component inventory", "Components"},
	{"self test", "Self test"},
	{"energy report", "Energy"},
	{"memory test", "Memory test"},
	{"url boot", "Boot from URL"},
	{"set boot device", "Set as boot device"},
	{"rename volume", "Rename volume"},
	{"erase data", "Erase all data"},
	{"clear boot device", "Clear boot device"},
	{"reset bootloader", "Reset bootloader"},
	{"reboot", "Reboot"},
}

local missing = {}
for _, feature in ipairs(FEATURES) do
	if boot:find(feature[2], 1, true) == nil then
		missing[#missing + 1] = feature[1]
	end
end

check(("all %d expected features are present"):format(#FEATURES), #missing == 0,
	table.concat(missing, ", "))

print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)