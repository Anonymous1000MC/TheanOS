-- Command implementations for the TheanOS terminal.
-- Loaded by Main.lua via loadfile, which injects `.localization` and `.COLOR`.

local Commands = {}

Commands.localization = Commands.localization or {}
Commands.COLOR = Commands.COLOR or {}

local localization = Commands.localization
local COLOR = Commands.COLOR

local filesystem = require("Filesystem")
local internet = require("Internet")
local paths = require("Paths")
local system = require("System")
local keyboard = require("Keyboard")
local screen = require("Screen")
local textLib = require("Text")

--------------------------------------------------------------------------------
-- Argument handling
--------------------------------------------------------------------------------

-- Splits a command line into tokens, honouring 'single' and "double" quotes.
function Commands.tokenize(line)
	local tokens = {}
	local current, quote = "", nil

	for i = 1, #line do
		local char = line:sub(i, i)

		if quote then
			if char == quote then
				quote = nil
			else
				current = current .. char
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char:match("%s") then
			if current ~= "" then
				tokens[#tokens + 1] = current
				current = ""
			end
		else
			current = current .. char
		end
	end

	if current ~= "" then
		tokens[#tokens + 1] = current
	end

	return tokens
end

-- Splits tokens into leading flags and positional arguments.
local function partitionFlags(tokens)
	local flags, positional = {}, {}

	for _, token in ipairs(tokens) do
		if #token > 1 and token:sub(1, 1) == "-" then
			flags[token:sub(2)] = true
		else
			positional[#positional + 1] = token
		end
	end

	return flags, positional
end

local function hasFlag(flags, ...)
	for _, name in ipairs({...}) do
		if flags[name] then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- Blocking line reader (used by sudo for password entry)
--------------------------------------------------------------------------------

function Commands.readLine(context, question, masked)
	context:out(question, COLOR.accent)

	local buffer = ""

	while true do
		local signal, _, character, code = computer.pullSignal()

		if signal == "key_down" then
			if code == 28 then -- return
				context:setEphemeral(nil)
				return buffer
			elseif code == 29 then -- ctrl+c aborts
				context:setEphemeral(nil)
				return nil
			elseif code == 14 then -- backspace
				buffer = unicode.sub(buffer, 1, -2)
			elseif not keyboard.isControl(character) then
				buffer = buffer .. unicode.char(character)
			end

			context:setEphemeral(masked and string.rep("*", unicode.len(buffer)) or buffer)
		elseif signal == "terminate" then
			context:setEphemeral(nil)
			return nil
		end
	end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function humanSize(bytes)
	if not bytes then return "-" end

	local units = {"B", "KB", "MB", "GB", "TB"}
	local value, unit = bytes, 1

	while value >= 1024 and unit < #units do
		value = value / 1024
		unit = unit + 1
	end

	return ("%.1f%s"):format(value, units[unit])
end

-- Formats a timestamp the way `ls -l` and friends expect.
local function formatDate(timestamp)
	if not timestamp or timestamp == 0 then return "                " end

	return os.date("%Y-%m-%d %H:%M", math.floor(timestamp / 1000))
end

--------------------------------------------------------------------------------
-- Package index (shared by tpkg)
--------------------------------------------------------------------------------

local PACKAGE_BASE_URL = "https://raw.githubusercontent.com/Anonymous1000MC/TheanOS/master/"
local PACKAGE_INDEX_URL = PACKAGE_BASE_URL .. "Packages/index.cfg"

local packageCachePath = paths.user.applicationData .. "tpkg/"

local function deserialize(text)
	local chunk, reason = load("return " .. text, "=index")
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

local function indexPath()
	return packageCachePath .. "index.cfg"
end

local function installedPath()
	return packageCachePath .. "installed.cfg"
end

local function readIndex()
	if not filesystem.exists(indexPath()) then
		return nil, localization.noIndex or "no package index cached -- run 'tpkg update'"
	end

	local ok, index = pcall(filesystem.readTable, indexPath())
	if not ok or type(index) ~= "table" then
		return nil, localization.badIndex or "cached package index is corrupt"
	end

	return index
end

local function readInstalled()
	if not filesystem.exists(installedPath()) then
		return {}
	end

	local ok, installed = pcall(filesystem.readTable, installedPath())
	if not ok or type(installed) ~= "table" then
		return {}
	end

	return installed
end

local function writeInstalled(installed)
	filesystem.makeDirectory(packageCachePath)
	filesystem.writeTable(installedPath(), installed, true)
end

local function findPackage(index, name)
	for _, package in ipairs(index.packages or {}) do
		if package.name == name or package.id == name then
			return package
		end
	end
end

-- Downloads a repository file into the OS root.
local function installFile(remotePath, context)
	local target = "/" .. remotePath:gsub("^/", "")
	local proxy, proxyPath = filesystem.get(target)

	if proxy then
		proxy.makeDirectory(paths.path(proxyPath))
	end

	local ok, reason = internet.download(PACKAGE_BASE_URL .. urlEncode(target:sub(2)), target)
	if not ok then
		return nil, reason
	end

	return target
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

Commands.commands = {}

local commands = Commands.commands

--------------------------------------------------------------------------------
-- Builtins
--------------------------------------------------------------------------------

commands.help = {
	usage = "help [command]",
	desc = localization.helpDesc or "list available commands, or explain one",
	run = function(context, args)
		if args[1] then
			local command = commands[args[1]]
			if not command then
				context:err(("no such command: %s"):format(args[1]))
				return
			end

			context:heading(command.usage or args[1])
			context:out(command.desc or "")
			return
		end

		local groups = {
			{localization.groupFiles or "Files", {"ls", "cd", "pwd", "cat", "mkdir", "rm", "cp", "mv", "touch", "tree", "find"}},
			{localization.groupText or "Text", {"grep", "wc", "head", "tail", "cat"}},
			{localization.groupSystem or "System", {"ps", "kill", "df", "du", "date", "uptime", "uname", "env", "history", "whoami", "hostname", "which"}},
			{localization.groupTheanOS or "TheanOS", {"tpkg", "sudo", "fastfetch", "reboot", "shutdown"}},
			{localization.groupShell or "Shell", {"help", "man", "clear", "echo", "sleep", "exit"}},
		}

		local width = 0
		for _, group in ipairs(groups) do
			for _, name in ipairs(group[2]) do
				width = math.max(width, #name)
			end
		end

		for _, group in ipairs(groups) do
			context:heading(group[1])

			local names = {}
			for _, name in ipairs(group[2]) do
				if commands[name] then names[#names + 1] = name end
			end
			table.sort(names)

			for _, name in ipairs(names) do
				context:out(("  %-" .. width .. "s  %s"):format(name, commands[name].desc or ""))
			end

			context:out("")
		end
	end,
}

commands.man = {
	usage = "man <command>",
	desc = localization.manDesc or "show the manual page for a command",
	run = function(context, args)
		if not args[1] then
			context:err("man: what manual page do you want?")
			return
		end

		local command = commands[args[1]]
		if not command then
			context:err(("man: no entry for %s"):format(args[1]))
			return
		end

		context:heading(args[1])
		context:accent("usage: " .. (command.usage or args[1]))
		context:out(command.desc or "")
	end,
}

commands.clear = {
	usage = "clear",
	desc = localization.clearDesc or "clear the screen",
	run = function(context) context:clear() end,
}

commands.echo = {
	usage = "echo [text...]",
	desc = localization.echoDesc or "print text",
	run = function(context, args)
		context:out(table.concat(args, " "))
	end,
}

commands.exit = {
	usage = "exit",
	desc = localization.exitDesc or "close the terminal",
	run = function(context) context:quit() end,
}

commands.sleep = {
	usage = "sleep <seconds>",
	desc = localization.sleepDesc or "wait for a number of seconds",
	run = function(context, args)
		local seconds = tonumber(args[1])
		if not seconds then
			context:err("sleep: expected a number of seconds")
			return
		end

		require("Event").sleep(math.min(seconds, 30))
	end,
}

--------------------------------------------------------------------------------
-- Navigation and listing
--------------------------------------------------------------------------------

commands.pwd = {
	usage = "pwd",
	desc = localization.pwdDesc or "print the working directory",
	run = function(context)
		context:out(context:cwd())
	end,
}

commands.cd = {
	usage = "cd [path]",
	desc = localization.cdDesc or "change the working directory",
	run = function(context, args)
		local target = context:resolve(args[1])

		if not filesystem.exists(target) then
			context:err(("cd: %s: no such file or directory"):format(args[1] or ""))
			return
		elseif not filesystem.isDirectory(target) then
			context:err(("cd: %s: not a directory"):format(args[1]))
			return
		end

		context:setCwd(target)
	end,
}

commands.ls = {
	usage = "ls [-l] [-a] [path]",
	desc = localization.lsDesc or "list directory contents",
	run = function(context, args)
		local flags, positional = partitionFlags(args)
		local showHidden = hasFlag(flags, "a", "all")
		local target = context:resolve(positional[1])

		if not filesystem.exists(target) then
			context:err(("ls: %s: no such file or directory"):format(positional[1] or ""))
			return
		end

		if not filesystem.isDirectory(target) then
			context:out(context:shorten(target))
			return
		end

		local list = filesystem.list(target) or {}

		if not showHidden then
			local filtered = {}
			for _, name in ipairs(list) do
				if name:sub(1, 1) ~= "." then filtered[#filtered + 1] = name end
			end
			list = filtered
		end

		if #list == 0 then
			context:dim("(empty)")
			return
		end

		if hasFlag(flags, "l") then
			for _, name in ipairs(list) do
				local path = target .. name
				local isDirectory = filesystem.isDirectory(path)
				local size = isDirectory and 0 or (filesystem.size(path) or 0)

				context:out(("%s  %8s  %s  %s"):format(
					isDirectory and "d" or "-",
					humanSize(size),
					formatDate(filesystem.lastModified(path)),
					name .. (isDirectory and "/" or "")
				))
			end
		else
			local names = {}
			for _, name in ipairs(list) do
				names[#names + 1] = filesystem.isDirectory(target .. name) and (name .. "/") or name
			end

			local perRow = math.max(1, math.floor(context:columns() / 18))
			local row = {}

			for i, name in ipairs(names) do
				row[#row + 1] = ("%-17s"):format(name)

				if i % perRow == 0 or i == #names then
					context:out((table.concat(row):gsub("%s+$", "")))
					row = {}
				end
			end
		end
	end,
}

commands.tree = {
	usage = "tree [path]",
	desc = localization.treeDesc or "show a directory tree",
	run = function(context, args)
		local root = context:resolve(args[1])

		if not filesystem.exists(root) then
			context:err(("tree: %s: no such directory"):format(args[1] or ""))
			return
		end

		local shown = 0

		local function walk(path, prefix, depth)
			if depth > 6 or shown > 120 then return end

			local list = filesystem.list(path) or {}

			for _, name in ipairs(list) do
				local child = path .. name
				local isDirectory = filesystem.isDirectory(child)

				shown = shown + 1
				context:out(prefix .. (isDirectory and "├── " or "└── ") .. name, isDirectory and COLOR.accent or nil)

				if isDirectory then
					walk(child, prefix .. (prefix:sub(-1) == "─" and "│   " or "    "), depth + 1)
				end
			end
		end

		context:accent(context:shorten(root))
		walk(root, "", 1)
	end,
}

commands.find = {
	usage = "find <pattern> [path]",
	desc = localization.findDesc or "find files matching a name pattern",
	run = function(context, args)
		local pattern = args[1]
		if not pattern then
			context:err("find: expected a name pattern")
			return
		end

		local root = context:resolve(args[2])
		local found = 0

		local function walk(path, depth)
			if depth > 6 or found > 60 then return end

			for _, name in ipairs(filesystem.list(path) or {}) do
				local child = path .. name
				local bare = filesystem.name(child)

				if bare:lower():find(pattern:lower(), 1, true) then
					found = found + 1
					context:out(context:shorten(child))
				end

				if filesystem.isDirectory(child) then
					walk(child, depth + 1)
				end
			end
		end

		if not filesystem.isDirectory(root) then
			context:err("find: not a directory")
			return
		end

		walk(root, 1)

		if found == 0 then
			context:dim(("no matches for '%s'"):format(pattern))
		end
	end,
}

--------------------------------------------------------------------------------
-- File manipulation
--------------------------------------------------------------------------------

commands.cat = {
	usage = "cat <file...>",
	desc = localization.catDesc or "print the contents of files",
	run = function(context, args)
		if #args == 0 then
			context:err("cat: expected a file")
			return
		end

		for _, name in ipairs(args) do
			local path = context:resolve(name)

			if not filesystem.exists(path) then
				context:err(("cat: %s: no such file"):format(name))
			elseif filesystem.isDirectory(path) then
				context:err(("cat: %s: is a directory"):format(name))
			else
				local content = filesystem.read(path)
				if content then
					for line in (content .. "\n"):gmatch("(.-)\n") do
						context:out(line)
					end
				else
					context:err(("cat: %s: unreadable"):format(name))
				end
			end
		end
	end,
}

commands.mkdir = {
	usage = "mkdir <directory...>",
	desc = localization.mkdirDesc or "create directories",
	run = function(context, args)
		if #args == 0 then
			context:err("mkdir: expected a directory name")
			return
		end

		for _, name in ipairs(args) do
			local path = context:resolve(name)

			if filesystem.exists(path) then
				context:err(("mkdir: %s: already exists"):format(name))
			elseif not filesystem.makeDirectory(path) then
				context:err(("mkdir: %s: could not create"):format(name))
			end
		end
	end,
}

commands.touch = {
	usage = "touch <file...>",
	desc = localization.touchDesc or "create empty files",
	run = function(context, args)
		if #args == 0 then
			context:err("touch: expected a file name")
			return
		end

		for _, name in ipairs(args) do
			local path = context:resolve(name)

			if not filesystem.exists(path) then
				local proxy, proxyPath = filesystem.get(path)
				proxy.makeDirectory(paths.path(proxyPath))

				local handle = proxy.open(proxyPath, "wb")
				if handle then proxy.close(handle) end
			end
		end
	end,
}

local function removeTree(path, depth)
	depth = depth or 1
	if depth > 12 then return end

	for _, name in ipairs(filesystem.list(path) or {}) do
		local child = path .. name

		if filesystem.isDirectory(child) then
			removeTree(child, depth + 1)
		else
			filesystem.remove(child)
		end
	end

	filesystem.remove(path)
end

commands.rm = {
	usage = "rm [-r] <path...>",
	desc = localization.rmDesc or "remove files or directories",
	run = function(context, args)
		local flags, positional = partitionFlags(args)
		local recursive = hasFlag(flags, "r", "R", "recursive")

		if #positional == 0 then
			context:err("rm: expected a path")
			return
		end

		for _, name in ipairs(positional) do
			local path = context:resolve(name)

			if not filesystem.exists(path) then
				context:err(("rm: %s: no such file or directory"):format(name))
			elseif path == "/" then
				context:err("rm: refusing to remove the filesystem root")
			elseif filesystem.isDirectory(path) then
				if not recursive then
					context:err(("rm: %s: is a directory (use -r)"):format(name))
				elseif not context:isElevated() then
					context:err(("rm: %s: removing a directory needs sudo"):format(name))
				else
					removeTree(path)
				end
			else
				filesystem.remove(path)
			end
		end
	end,
}

commands.rmdir = {
	usage = "rmdir <directory...>",
	desc = localization.rmdirDesc or "remove empty directories",
	run = function(context, args)
		if #args == 0 then
			context:err("rmdir: expected a directory")
			return
		end

		for _, name in ipairs(args) do
			local path = context:resolve(name)

			if not filesystem.isDirectory(path) then
				context:err(("rmdir: %s: not a directory"):format(name))
			elseif #(filesystem.list(path) or {}) > 0 then
				context:err(("rmdir: %s: directory not empty"):format(name))
			else
				filesystem.remove(path)
			end
		end
	end,
}

commands.cp = {
	usage = "cp <source> <destination>",
	desc = localization.cpDesc or "copy files",
	run = function(context, args)
		local source, destination = context:resolve(args[1]), args[2] and context:resolve(args[2])

		if not source or not destination then
			context:err("cp: usage: cp <source> <destination>")
			return
		elseif not filesystem.exists(source) then
			context:err(("cp: %s: no such file"):format(args[1]))
		elseif not filesystem.copy(source, destination) then
			context:err(("cp: could not copy to %s"):format(args[2]))
		end
	end,
}

commands.mv = {
	usage = "mv <source> <destination>",
	desc = localization.mvDesc or "move or rename files",
	run = function(context, args)
		local source, destination = context:resolve(args[1]), args[2] and context:resolve(args[2])

		if not source or not destination then
			context:err("mv: usage: mv <source> <destination>")
			return
		elseif not filesystem.exists(source) then
			context:err(("mv: %s: no such file"):format(args[1]))
		elseif not filesystem.rename(source, destination) then
			context:err(("mv: could not move to %s"):format(args[2]))
		end
	end,
}

--------------------------------------------------------------------------------
-- Text utilities
--------------------------------------------------------------------------------

commands.grep = {
	usage = "grep <pattern> <file...>",
	desc = localization.grepDesc or "search for a pattern inside files",
	run = function(context, args)
		local pattern = args[1]
		if not pattern or #args < 2 then
			context:err("grep: usage: grep <pattern> <file...>")
			return
		end

		local plain = not pattern:find("[%^%$%(%)%%%.%[%]%*%+%-%?]", 1)

		for i = 2, #args do
			local path = context:resolve(args[i])

			if not filesystem.exists(path) or filesystem.isDirectory(path) then
				context:err(("grep: %s: not a readable file"):format(args[i]))
			else
				local content = filesystem.read(path) or ""
				local number = 0

				for number, line in ipairs(textLib.split(content, "\n")) do
					if line:find(pattern, plain) then
						context:out(("%s:%d: %s"):format(args[i], number, line), COLOR.ok)
					end
				end
			end
		end
	end,
}

commands.wc = {
	usage = "wc <file...>",
	desc = localization.wcDesc or "count lines, words and characters",
	run = function(context, args)
		if #args == 0 then
			context:err("wc: expected a file")
			return
		end

		for _, name in ipairs(args) do
			local path = context:resolve(name)
			local content = filesystem.read(path)

			if not content then
				context:err(("wc: %s: unreadable"):format(name))
			else
				local lines = 0
				for _ in content:gmatch("[^\n]+") do lines = lines + 1 end

				local words = 0
				for _ in content:gmatch("%S+") do words = words + 1 end

				context:out(("%s  %d lines  %d words  %d bytes"):format(name, lines, words, #content))
			end
		end
	end,
}

commands.head = {
	usage = "head [-n <count>] <file...>",
	desc = localization.headDesc or "print the first lines of a file",
	run = function(context, args)
		local count, files = 10, {}

		local i = 1
		while args[i] do
			if args[i] == "-n" then
				count = tonumber(args[i + 1]) or count
				i = i + 2
			else
				files[#files + 1] = args[i]
				i = i + 1
			end
		end

		if #files == 0 then
			context:err("head: expected a file")
			return
		end

		for _, name in ipairs(files) do
			local content = filesystem.read(context:resolve(name))
			if not content then
				context:err(("head: %s: unreadable"):format(name))
			else
				local shown = 0
				for line in (content .. "\n"):gmatch("(.-)\n") do
					shown = shown + 1
					if shown > count then break end
					context:out(line)
				end
			end
		end
	end,
}

commands.tail = {
	usage = "tail [-n <count>] <file...>",
	desc = localization.tailDesc or "print the last lines of a file",
	run = function(context, args)
		local count, files = 10, {}

		local i = 1
		while args[i] do
			if args[i] == "-n" then
				count = tonumber(args[i + 1]) or count
				i = i + 2
			else
				files[#files + 1] = args[i]
				i = i + 1
			end
		end

		if #files == 0 then
			context:err("tail: expected a file")
			return
		end

		for _, name in ipairs(files) do
			local content = filesystem.read(context:resolve(name))
			if not content then
				context:err(("tail: %s: unreadable"):format(name))
			else
				local all = {}
				for line in (content .. "\n"):gmatch("(.-)\n") do
					all[#all + 1] = line
				end

				for i = math.max(1, #all - count + 1), #all do
					context:out(all[i])
				end
			end
		end
	end,
}

--------------------------------------------------------------------------------
-- System information
--------------------------------------------------------------------------------

commands.df = {
	usage = "df",
	desc = localization.dfDesc or "report filesystem usage",
	run = function(context)
		context:out(("%-12s %10s %10s %10s"):format("filesystem", "size", "used", "free"))

		local seen = {}
		local mounts = filesystem.mounts and filesystem.mounts() or {}

		if #mounts == 0 then mounts = {"/"} end

		for _, path in ipairs(mounts) do
			local proxy = filesystem.getProxy(path)
			if proxy and not seen[proxy.address] then
				seen[proxy.address] = true

				local total = proxy.spaceTotal() or 0
				local used = proxy.spaceUsed() or 0

				context:out(("%-12s %10s %10s %10s"):format(
					proxy.getLabel and (proxy.getLabel() or proxy.address) or proxy.address,
					humanSize(total), humanSize(used), humanSize(total - used)
				))
			end
		end
	end,
}

commands.du = {
	usage = "du [path]",
	desc = localization.duDesc or "show how much space a directory uses",
	run = function(context, args)
		local root = context:resolve(args[1])

		if not filesystem.exists(root) then
			context:err(("du: %s: no such path"):format(args[1] or ""))
			return
		end

		local function measure(path, depth)
			if depth > 8 then return 0 end

			if not filesystem.isDirectory(path) then
				return filesystem.size(path) or 0
			end

			local total = 0
			for _, name in ipairs(filesystem.list(path) or {}) do
				total = total + measure(path .. name, depth + 1)
			end

			return total
		end

		context:out(("%s\t%s"):format(humanSize(measure(root, 1)), context:shorten(root)))
	end,
}

commands.date = {
	usage = "date",
	desc = localization.dateDesc or "print the current date and time",
	run = function(context)
		context:out(os.date("%A, %d %B %Y  %H:%M:%S"))
	end,
}

commands.uptime = {
	usage = "uptime",
	desc = localization.uptimeDesc or "show how long the system has been running",
	run = function(context)
		local seconds = computer.uptime()

		context:out(("up %d:%02d:%02d"):format(
			math.floor(seconds / 3600),
			math.floor(seconds / 60) % 60,
			math.floor(seconds) % 60
		))
	end,
}

commands.whoami = {
	usage = "whoami",
	desc = localization.whoamiDesc or "print the current user",
	run = function(context)
		context:out(context:user())
	end,
}

commands.hostname = {
	usage = "hostname",
	desc = localization.hostnameDesc or "print the computer label",
	run = function(context)
		context:out(context:host())
	end,
}

commands.uname = {
	usage = "uname [-a]",
	desc = localization.unameDesc or "print system information",
	run = function(context, args)
		local all = args[1] == "-a"

		if all then
			context:out(("TheanOS %s on %s (%s) -- OpenComputers"):format(
				system.version or "1.0", context:host(), context:user()
			))
		else
			context:out("TheanOS")
		end
	end,
}

commands.env = {
	usage = "env",
	desc = localization.envDesc or "print the environment",
	run = function(context)
		context:out("USER=" .. context:user())
		context:out("HOME=" .. context:userHome())
		context:out("PWD=" .. context:cwd())
		context:out("SHELL=/TheanOS")
		context:out("TERM=theanos-tty")
	end,
}

commands.which = {
	usage = "which <command>",
	desc = localization.whichDesc or "show which command would run",
	run = function(context, args)
		if not args[1] then
			context:err("which: expected a command name")
			return
		end

		if commands[args[1]] then
			context:out(("/Applications/Terminal.app/Commands.lua:%s"):format(args[1]))
		else
			context:err(("which: %s: not found"):format(args[1]))
		end
	end,
}

commands.history = {
	usage = "history",
	desc = localization.historyDesc or "show recent commands",
	run = function(context)
		local shell = context.shell and context.shell() or {}
		local history = shell.history or {}

		for i, entry in ipairs(history) do
			context:out(("%4d  %s"):format(i, entry), COLOR.dim)
		end
	end,
}

commands.ps = {
	usage = "ps",
	desc = localization.psDesc or "list running windows",
	run = function(context)
		context:out(("%-6s %s"):format("PID", "WINDOW"))

		local pid = 1

		for _, name in ipairs(filesystem.list("/Applications/") or {}) do
			if filesystem.extension(name) == ".app" then
				context:out(("%-6d %s"):format(pid, filesystem.hideExtension(name)))
				pid = pid + 1
			end
		end

		context:dim("(TheanOS is cooperative -- this is a listing, not a process table)")
	end,
}

commands.kill = {
	usage = "kill <pid>",
	desc = localization.killDesc or "close an installed application",
	run = function(context, args)
		local index = tonumber(args[1])
		if not index then
			context:err("kill: expected a pid")
			return
		end

		local apps = {}

		for _, name in ipairs(filesystem.list("/Applications/") or {}) do
			if filesystem.extension(name) == ".app" then
				apps[#apps + 1] = filesystem.hideExtension(name)
			end
		end

		if not apps[index] then
			context:err(("kill: no such pid: %s"):format(args[1]))
			return
		end

		context:ok(("sent SIGTERM to %s (close its window to finish)"):format(apps[index]))
	end,
}

--------------------------------------------------------------------------------
-- TheanOS specific
--------------------------------------------------------------------------------

local function asciiLogo()
	return {
		"███████╗",
		"██╔════╝",
		"███████╗",
		"╚════██║",
		"███████║",
		"╚══════╝",
	}
end

local function osVersion()
	if computer.getOperatingSystem then
		local ok, value = pcall(computer.getOperatingSystem)
		if ok and value then return value end
	end

	return "OpenComputers"
end

commands.fastfetch = {
	usage = "fastfetch",
	desc = localization.fastfetchDesc or "show a summary of this system",
	run = function(context)
		local logo = asciiLogo()

		local info = {
			("user@%s"):format(context:host()),
			"",
			("OS        %s"):format(osVersion()),
			("Host      %s"):format(context:host()),
			("Kernel    Lua %s"):format(_VERSION:match("%d+%.%d+") or "?"),
			("Shell     TheanOS terminal"),
			("Theme     installer default"),
			"",
			("CPU       OpenComputers Lua VM"),
			("Memory    %s"):format(humanSize(computer.totalMemory())),
			("Display   %dx%d"):format(screen.getWidth and screen.getWidth() or 0, screen.getHeight and screen.getHeight() or 0),
			("Uptime    %ds"):format(math.floor(computer.uptime())),
		}

		if context:isElevated() then
			info[#info + 1] = ""
			info[#info + 1] = "Privilege  elevated (sudo)"
		end

		for i = 1, math.max(#logo, #info) do
			local left = logo[i] or (" "):rep(7)
			local right = info[i] or ""
			context:out(("%s  %s"):format(left, right), i == 1 and COLOR.heading or nil)
		end
	end,
}

commands.neofetch = {
	usage = "neofetch",
	desc = localization.neofetchDesc or "alias for fastfetch",
	run = function(context) commands.fastfetch.run(context, {}) end,
}

commands.reboot = {
	usage = "reboot",
	desc = localization.rebootDesc or "restart the computer",
	run = function(context)
		if not context:isElevated() and not confirm(context, localization.confirmReboot) then
			return
		end

		computer.shutdown(true)
	end,
}

commands.shutdown = {
	usage = "shutdown",
	desc = localization.shutdownDesc or "power the computer off",
	run = function(context)
		if not context:isElevated() and not confirm(context, localization.confirmShutdown) then
			return
		end

		computer.shutdown()
	end,
}

function confirm(context, question)
	local answer = context:prompt(("%s [y/N] "):format(question or "Are you sure?"))
	return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

--------------------------------------------------------------------------------
-- sudo
--------------------------------------------------------------------------------

commands.sudo = {
	usage = "sudo <command>",
	desc = localization.sudoDesc or "run a command with elevated privileges",
	run = function(context, args, rawLine)
		if not args[1] then
			context:err("sudo: usage: sudo <command>")
			return
		end

		local settings = filesystem.readTable(context:userHome() .. "Settings.cfg") or {}
		local storedHash = settings.securityPassword

		-- No password configured: behave like NOPASSWD sudo.
		if storedHash then
			local attempts = 0

			while attempts < 3 do
				local entered = Commands.readLine(context, ("[%s] password for %s: "):format(
					context:user(), context:user()
				), true)

				if entered == nil then
					context:err("sudo: aborted")
					return
				end

				local ok, hash = pcall(function()
					return require("SHA-256").hash(entered)
				end)

				if ok and hash == storedHash then
					break
				end

				attempts = attempts + 1
				context:err("Sorry, try again.")
			end

			if attempts >= 3 then
				context:err("sudo: 3 incorrect attempts")
				return
			end
		end

		local command = commands[args[1]]
		if not command then
			context:err(("sudo: %s: command not found"):format(args[1]))
			return
		end

		context:dim("sudo: elevated for this command")
		context.shell().elevated = true

		-- sudo re-runs the command, so drop the echoed sudo invocation first
		command.run(context, Commands.tokenize(table.concat(args, " ", 2)), table.concat(args, " ", 2))
	end,
}

--------------------------------------------------------------------------------
-- tpkg
--------------------------------------------------------------------------------

local function requireElevation(context, action)
	if context:isElevated() then return true end

	context:err(("tpkg: %s changes the system -- run 'sudo tpkg %s'"):format(action, action))
	return false
end

local function packageSummary(package)
	return ("%s %s -- %s"):format(package.name, package.version or "?", package.description or "")
end

local TPKG_USAGE = [[
tpkg -- TheanOS package manager

usage:
  tpkg update              refresh the package index from the repository
  tpkg search <text>       search the index
  tpkg list                show installed packages
  tpkg info <package>      show details about a package
  tpkg install <package>   download and install (needs sudo)
  tpkg remove <package>    uninstall a package (needs sudo)
  tpkg upgrade             reinstall packages with newer versions (needs sudo)
  tpkg help                this text]]

commands.tpkg = {
	usage = "tpkg <subcommand>",
	desc = localization.tpkgDesc or "install and remove packages",
	run = function(context, args)
		local subcommand = args[1]

		if not subcommand or subcommand == "help" or subcommand == "--help" then
			for _, line in ipairs(textLib.split(TPKG_USAGE, "\n")) do
				context:out(line)
			end
			return
		end

		if subcommand == "update" then
			context:out("fetching package index...")

			local body, reason = internet.request(PACKAGE_INDEX_URL)
			if not body then
				context:err(("tpkg: could not reach the repository: %s"):format(reason))
				return
			end

			local index, parseReason = deserialize(body)
			if not index or type(index) ~= "table" or type(index.packages) ~= "table" then
				context:err(("tpkg: malformed index: %s"):format(parseReason or "?"))
				return
			end

			filesystem.makeDirectory(packageCachePath)
			filesystem.write(indexPath(), body)

			context:ok(("index updated: %d packages"):format(#index.packages))
			return
		end

		local index, reason = readIndex()
		if not index then
			context:err("tpkg: " .. reason)
			return
		end

		if subcommand == "search" then
			local query = (args[2] or ""):lower()
			local found = 0

			for _, package in ipairs(index.packages) do
				local haystack = (package.name .. " " .. (package.description or "") .. " " .. (package.id or "")):lower()

				if haystack:find(query, 1, true) then
					found = found + 1
					context:out(packageSummary(package))
				end
			end

			if found == 0 then
				context:dim(("nothing matched '%s'"):format(args[2] or ""))
			end

			return
		end

		if subcommand == "list" then
			local installed = readInstalled()
			local names = {}

			for name in pairs(installed) do
				names[#names + 1] = name
			end
			table.sort(names)

			if #names == 0 then
				context:dim("no packages installed through tpkg")
				return
			end

			for _, name in ipairs(names) do
				local entry = installed[name]
				context:out(("%s %s"):format(name, entry.version or "?"))
			end

			return
		end

		if subcommand == "info" then
			local package = args[2] and findPackage(index, args[2])
			if not package then
				context:err(("tpkg: unknown package: %s"):format(args[2] or ""))
				return
			end

			context:heading(("%s %s"):format(package.name, package.version or "?"))
			context:out(("id          %s"):format(package.id or package.name))
			context:out(("author      %s"):format(package.author or "unknown"))
			context:out(("description %s"):format(package.description or ""))
			context:out(("homepage    %s"):format(package.homepage or "-"))
			context:out(("files       %d"):format(#(package.files or {})))

			if package.dependencies and #package.dependencies > 0 then
				context:out(("depends     %s"):format(table.concat(package.dependencies, ", ")))
			end

			return
		end

		if subcommand == "install" then
			if not args[2] then
				context:err("tpkg install: expected a package name")
				return
			end

			if not requireElevation(context, "install") then return end

			local package = findPackage(index, args[2])
			if not package then
				context:err(("tpkg: unknown package: %s"):format(args[2]))
				return
			end

			context:out(("installing %s %s..."):format(package.name, package.version or "?"))

			local installedFiles, failed = {}, 0

			for _, remotePath in ipairs(package.files or {}) do
				local path = type(remotePath) == "table" and remotePath.path or remotePath
				local optional = type(remotePath) == "table" and remotePath.optional

				context:dim("  " .. path)

				local target, why = installFile(path, context)
				if target then
					installedFiles[#installedFiles + 1] = path
				elseif not optional then
					failed = failed + 1
					context:err(("    failed: %s"):format(why or "?"))
				end
			end

			if failed > 0 then
				context:err(("tpkg: %s finished with %d errors"):format(package.name, failed))
				return
			end

			local installed = readInstalled()
			installed[package.name] = {
				version = package.version or "1",
				files = installedFiles,
				index = index.version or 1,
			}

			writeInstalled(installed)
			context:ok(("%s installed (%d files)"):format(package.name, #installedFiles))
			return
		end

		if subcommand == "remove" then
			if not args[2] then
				context:err("tpkg remove: expected a package name")
				return
			end

			if not requireElevation(context, "remove") then return end

			local installed = readInstalled()
			local entry = installed[args[2]]

			if not entry then
				context:err(("tpkg: %s is not installed"):format(args[2]))
				return
			end

			for _, path in ipairs(entry.files or {}) do
				local proxy, proxyPath = filesystem.get("/" .. path:sub(2):gsub("^/", ""))

				if proxy and proxy.exists(proxyPath) then
					proxy.remove(proxyPath)
				end

				context:dim("  removed " .. path)
			end

			installed[args[2]] = nil
			writeInstalled(installed)

			context:ok(("%s removed"):format(args[2]))
			return
		end

		if subcommand == "upgrade" then
			if not requireElevation(context, "upgrade") then return end

			local installed = readInstalled()
			local upgraded = 0

			for name, entry in pairs(installed) do
				local package = findPackage(index, name)

				if package and (package.version or "1") ~= (entry.version or "1") then
					context:out(("upgrading %s: %s -> %s"):format(name, entry.version or "?", package.version or "?"))

					for _, remotePath in ipairs(package.files or {}) do
						local path = type(remotePath) == "table" and remotePath.path or remotePath
						installFile(path, context)
					end

					entry.version = package.version or "1"
					upgraded = upgraded + 1
				end
			end

			writeInstalled(installed)

			if upgraded == 0 then
				context:dim("everything is up to date")
			else
				context:ok(("%d package(s) upgraded"):format(upgraded))
			end

			return
		end

		context:err(("tpkg: unknown subcommand: %s"):format(subcommand))
	end,
}

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

commands.dir = {usage = "dir", desc = "alias for ls -l", run = function(context, args)
	local all = {}
	for _, token in ipairs(args) do all[#all + 1] = token end
	all[#all + 1] = "-l"
	commands.ls.run(context, all)
end}

commands["ll"] = commands.dir
commands.cls = commands.clear

--------------------------------------------------------------------------------

return Commands
