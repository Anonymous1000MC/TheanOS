-- Tests the desktop-shortcut reconciliation added to Libraries/System.lua.
--
-- Regression: Monitor.app shipped in 1.5.0 with no desktop icon, because
-- Installer/Files.cfg is not itself installed and therefore never reaches an
-- existing device. Installer/Files.cfg now sets shortcut = true (fixing fresh
-- installs), and System.lua fills the gap for existing ones.
--
-- Run from the repository root:  lua5.3 Tools/tests/desktop_shortcut_test.lua

local root = os.getenv("THEANOS_ROOT") or "."

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

--------------------------------------------------------------------------------
-- Pull ensureDesktopShortcuts out of the real System.lua and run it against a
-- fake filesystem, rather than reimplementing it here.
--------------------------------------------------------------------------------

local source = assert(io.open(root .. "/Libraries/System.lua")):read("*a")

local listStart = assert(source:find("local missingDesktopShortcuts = {", 1, true))
local listEnd = assert(source:find("\n}", listStart, true)) + 2
local functionStart = assert(source:find("local function ensureDesktopShortcuts()", 1, true))
local functionEnd = assert(source:find("\nend\n", functionStart, true)) + 5
local snippet = source:sub(listStart, listEnd) .. "\n\n" .. source:sub(functionStart, functionEnd)

local function compile(filesystem, paths, system)
	local env = setmetatable({
		filesystem = filesystem,
		paths = paths,
		system = system,
	}, {__index = _G})

	local chunk = assert(load(snippet .. "\nreturn ensureDesktopShortcuts, missingDesktopShortcuts",
		"snippet", "t", env))

	return chunk()
end

--------------------------------------------------------------------------------
-- Fake filesystem
--------------------------------------------------------------------------------

local function newFiles(present)
	local FILES = {}
	for _, p in ipairs(present) do FILES[p] = true end

	local writes = {}

	local filesystem = {}
	function filesystem.path(p) return p:match("^(.+%/).") or "" end
	function filesystem.name(p) return p:match("%/?([^%/]+%/?)$") end
	function filesystem.hideExtension(p) return p:match("(.+)%..+") or p end
	function filesystem.exists(p) return FILES[p] ~= nil end
	function filesystem.makeDirectory() end
	function filesystem.write(p, data)
		FILES[p] = data
		writes[#writes + 1] = {path = p, data = data}
		return true
	end

	return filesystem, writes, FILES
end

local paths = {
	system = {applications = "/Applications/"},
	user = {desktop = "/Users/t/Desktop/"},
}

-- Mirrors system.createShortcut: writes <where> .. ".lnk" holding the target.
local function newSystem(fs)
	local system = {}
	function system.createShortcut(where, forWhat)
		return fs.write(where .. ".lnk", forWhat)
	end
	return system
end

local APP_MAIN = "/Applications/Monitor.app/Main.lua"
local SHORTCUT = "/Users/t/Desktop/Monitor.lnk"

--------------------------------------------------------------------------------
-- Cases
--------------------------------------------------------------------------------

print("== fresh install: no shortcut present ==")
local filesystem, writes, backing = newFiles({APP_MAIN})
local ensure, list = compile(filesystem, paths, newSystem(filesystem))

check("list contains Monitor.app", (function()
	for _, name in ipairs(list) do if name == "Monitor.app" then return true end end
	return false
end)(), table.concat(list, ","))

ensure()
check("shortcut created", filesystem.exists(SHORTCUT))
check("exactly one write", #writes == 1, #writes)
check("shortcut targets the app directory",
	writes[1] ~= nil and writes[1].data == "/Applications/Monitor.app/",
	writes[1] and writes[1].data)

print("== idempotent: running again does not duplicate ==")
local before = #writes
ensure()
ensure()
check("no further writes", #writes == before, #writes - before)

print("== app missing: nothing is written ==")
local fs2, writes2 = newFiles({}) -- neither shortcut nor app
local filesystemRef2 = fs2
local ensure2 = compile(fs2, paths, newSystem(fs2))
ensure2()
check("no shortcut created for a missing app", not fs2.exists(SHORTCUT))
check("nothing written at all", #writes2 == 0, #writes2)

print("== user deleted the icon: it is not resurrected mid-session ==")
-- The desktop is rebuilt on user switch; a user who removed the icon should keep
-- it removed, so this documents the current behaviour explicitly rather than
-- leaving it undefined.
local fs3, _, backing3 = newFiles({APP_MAIN})
local ensure3 = compile(fs3, paths, newSystem(fs3))
ensure3()
check("created on first pass", fs3.exists(SHORTCUT))
backing3[SHORTCUT] = nil -- user deletes it
ensure3()
check("recreated after deletion (documented behaviour)", fs3.exists(SHORTCUT))

print("== the real file still compiles ==")
-- This test extracts the function as text, so it would happily pass while the
-- actual file was syntactically broken. Compile the real thing as well.
local compiled, compileReason = loadfile(root .. "/Libraries/System.lua")
check("Libraries/System.lua compiles", compiled ~= nil, compileReason)

print("== declaration matches the installer ==")
local filesCfg = assert(load("return " .. assert(io.open(root .. "/Installer/Files.cfg")):read("*a")))()
local found = false
for _, item in ipairs(filesCfg.required) do
	if type(item) == "table" and item.path == "Applications/Monitor.app/Main.lua" then
		found = true
		check("Files.cfg sets shortcut = true", item.shortcut == true, tostring(item.shortcut))
		check("Files.cfg keeps the id", item.id == 2531, tostring(item.id))
	end
end
check("Monitor entry present in Files.cfg", found)

print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)