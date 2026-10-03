-- Text utilities for the TheanOS terminal: diff and a minimal patch.
-- Loaded by Commands.lua, which injects `.localization` and `.COLOR`.

local Text = {}

local localization, COLOR, COMMANDS = ...

local filesystem = require("Filesystem")

local function t(key, fallback)
	local value = localization[key]

	if type(value) ~= "string" or value == "$" .. key then
		return fallback
	end

	return value
end

-- Splits on newlines the way every other tool does: a trailing newline terminates
-- the last line rather than introducing an empty one, so "a\nb\n" is two lines.
-- Done by hand because appending a newline and gmatching yields a phantom final
-- element, which silently inflates every line count.
local function splitLines(content)
	local lines, start = {}, 1

	while true do
		local newline = content:find("\n", start, true)

		if not newline then
			if start <= #content then
				lines[#lines + 1] = content:sub(start)
			end
			break
		end

		lines[#lines + 1] = content:sub(start, newline - 1)
		start = newline + 1
	end

	for i = 1, #lines do
		lines[i] = (lines[i]:gsub("\r$", ""))
	end

	return lines
end

local function readLines(path)
	local content = filesystem.read(path)
	if not content then return nil end

	return splitLines(content)
end

local function writeLines(path, lines)
	return filesystem.write(path, table.concat(lines, "\n") .. "\n")
end

Text.commands = {}

--------------------------------------------------------------------------------
-- diff
--------------------------------------------------------------------------------

-- Longest common subsequence table, then a walk that emits unified hunks.
--
-- The table is O(n*m) and must be kept whole, because backtracking reads
-- lengths[i][j-1] and lengths[i+1][j]. Under LuaJ every entry is a boxed Java
-- object, so the cap is set for memory rather than time: 200 lines is 40k
-- entries, already most of what a small computer has spare. Larger files are
-- refused rather than attempted.
local MAX_LINES = 200

local function lcsTable(a, b)
	local lengths = {}
	local previous = {}

	for j = 0, #b do previous[j] = 0 end
	lengths[0] = previous

	for i = 1, #a do
		local current = {[0] = 0}

		for j = 1, #b do
			if a[i] == b[j] then
				current[j] = previous[j - 1] + 1
			else
				local up, left = previous[j], current[j - 1]
				current[j] = up >= left and up or left
			end
		end

		lengths[i] = current
		previous = current
	end

	return lengths
end

-- Emits operations as {kind, text, ai, bi}:
--   ai is the 1-based line in the original, or -- for an insertion, the number
--   of original lines that precede it, so an insertion at the very top is 0.
--   bi is the line in the new file, nil for a deletion.
local function diffSequences(a, b)
	local table_ = lcsTable(a, b)
	local operations, i, j = {}, 1, 1

	-- Row i+1 and column 0 fall off the edge on the final step; the recurrence
	-- treats those as 0.
	local function at(row, column)
		local line = table_[row]
		return (line and line[column]) or 0
	end

	while i <= #a and j <= #b do
		if a[i] == b[j] then
			operations[#operations + 1] = {" ", a[i], i, j}
			i = i + 1
			j = j + 1
		-- Dropping a[i] leaves LCS(a[i+1..], b[j..]) = at(i+1, j); dropping b[j]
		-- leaves at(i, j-1). Keep whichever is larger, so a[i] goes when its own
		-- row is the better continuation. Ties go to a deletion, which keeps
		-- related changes grouped instead of alternating.
		elseif at(i + 1, j) >= at(i, j - 1) then
			operations[#operations + 1] = {"-", a[i], i}
			i = i + 1
		else
			operations[#operations + 1] = {"+", b[j], i - 1, j}
			j = j + 1
		end
	end

	while i <= #a do
		operations[#operations + 1] = {"-", a[i], i}
		i = i + 1
	end

	while j <= #b do
		operations[#operations + 1] = {"+", b[j], i - 1, j}
		j = j + 1
	end

	return operations
end

-- Groups operations into unified hunks.
--
-- A hunk must be a CONTIGUOUS run of the original: its line count has to match
-- the span it claims, or `patch` verifies against the wrong lines and refuses the
-- hunk. So held-back context is either emitted in full inside the current hunk,
-- or the hunk is closed and a new one opened. Trimming it and carrying on -- which
-- is what this did at first -- produces a header that counts fewer lines than the
-- body spans, and the patch silently fails to apply.
local function buildHunks(operations, context)
	local hunks, current, trailing = {}, nil, {}
	local limit = context * 2

	local function closeHunk()
		if current then
			hunks[#hunks + 1] = current
			current = nil
		end
	end

	local function openHunk()
		current = {
			aStart = nil, bStart = nil,
			aCount = 0, bCount = 0,
			aChanged = false, bChanged = false,
			lines = {},
		}
	end

	local function emitContext(op)
		current.lines[#current.lines + 1] = " " .. op[2]
		current.aCount = current.aCount + 1
		current.bCount = current.bCount + 1
		current.aStart = current.aStart or op[3]
		current.bStart = current.bStart or op[4]
	end

	local function emitChange(op)
		current.lines[#current.lines + 1] = op[1] .. op[2]
		current.aStart = current.aStart or op[3]
		current.bStart = current.bStart or op[4]

		if op[1] == "-" then
			current.aCount = current.aCount + 1
			current.aChanged = true
		else
			current.bCount = current.bCount + 1
			current.bChanged = true
		end
	end

	for i = 1, #operations do
		local op = operations[i]

		if op[1] == " " then
			-- Held back, not emitted. Emitting here as well as at the next change
			-- put the same context lines in the body twice, which made the header
			-- count disagree with the span and the patch silently fail to apply.
			trailing[#trailing + 1] = op

			-- The gap is too wide to keep in one hunk.
			if current and #trailing > limit then
				closeHunk()
			end

		else
			if #trailing > limit then
				closeHunk()
			end

			if not current then
				openHunk()

				for k = math.max(1, #trailing - context + 1), #trailing do
					emitContext(trailing[k])
				end
			else
				-- Still the same hunk, so every held-back line has to appear in it.
				for k = 1, #trailing do
					emitContext(trailing[k])
				end
			end

			trailing = {}
			emitChange(op)
		end
	end

	closeHunk()

	-- Identical input produces only context, so no hunk is ever opened. Guard
	-- anyway: a hunk with no change in it is not a hunk.
	local real = {}
	for _, hunk in ipairs(hunks) do
		if hunk.aChanged or hunk.bChanged then
			real[#real + 1] = hunk
		end
	end

	return real
end

-- Splits piped input into lines, or reads the named files. Returns nil plus a
-- message when a named file cannot be read.
-- Splits on newlines without inventing a trailing empty line. Appending a
-- newline and gmatching always yields one, and a stray empty line sorts to the
-- front and changes counts, so it is trimmed once here for every filter.
local function splitInput(content)
	local lines, start = {}, 1

	while true do
		local newline = content:find("\n", start, true)

		if not newline then
			if start <= #content then lines[#lines + 1] = content:sub(start) end
			break
		end

		lines[#lines + 1] = content:sub(start, newline - 1)
		start = newline + 1
	end

	return lines
end

local function gather(context, paths)
	local lines = {}

	if #paths == 0 then
		local input = context.stdin

		if not input then
			return nil, t("noInput", "no input: pass a file or pipe into this")
		end

		return splitInput(input)
	end

	for _, name in ipairs(paths) do
		local fileLines = readLines(context:resolve(name))

		if not fileLines then
			return nil, ("%s: unreadable"):format(name)
		end

		for i = 1, #fileLines do
			lines[#lines + 1] = fileLines[i]
		end
	end

	return lines
end

Text.commands.sort = {
	usage = "sort [-r] [-n] [-u]",
	desc = t("sortDesc", "sort lines of text"),
	run = function(context, args)
		local reverse, numeric, unique, files = false, false, false, {}

		for _, token in ipairs(args) do
			if token == "-r" then reverse = true
			elseif token == "-n" then numeric = true
			elseif token == "-u" then unique = true
			else files[#files + 1] = token end
		end

		local lines, reason = gather(context, files)
		if not lines then context:err("sort: " .. reason) return end

		local key = numeric and function(v) return tonumber(v) or math.huge end or function(v) return v end

		table.sort(lines, function(a, b)
			local x, y = key(a), key(b)

			if x == y then return false end
			if reverse then return x > y end

			return x < y
		end)

		local out = {}
		for i = 1, #lines do
			if not unique or i == 1 or lines[i] ~= lines[i - 1] then
				out[#out + 1] = lines[i]
			end
		end

		for _, line in ipairs(out) do context:out(line) end
	end,
}

Text.commands.uniq = {
	usage = "uniq [-c]",
	desc = t("uniqDesc", "drop adjacent duplicate lines"),
	run = function(context, args)
		local count, files = false, {}

		for _, token in ipairs(args) do
			if token == "-c" then count = true else files[#files + 1] = token end
		end

		local lines, reason = gather(context, files)
		if not lines then context:err("uniq: " .. reason) return end

		local index = 1
		while index <= #lines do
			local run = 1
			while index + run <= #lines and lines[index + run] == lines[index] do run = run + 1 end

			context:out(count and ("%7d %s"):format(run, lines[index]) or lines[index])
			index = index + run
		end
	end,
}

Text.commands.rev = {
	usage = "rev [file...]",
	desc = t("revDesc", "reverse each line"),
	run = function(context, args)
		local lines, reason = gather(context, args)
		if not lines then context:err("rev: " .. reason) return end

		for _, line in ipairs(lines) do
			local reversed = {}
			for i = #line, 1, -1 do reversed[#reversed + 1] = line:sub(i, i) end
			context:out(table.concat(reversed))
		end
	end,
}

Text.commands["tee"] = {
	usage = "tee <file...>",
	desc = t("teeDesc", "print input and also write it to files"),
	run = function(context, args)
		local input = context.stdin

		if not input then
			context:err("tee: no input")
			return
		end

		for _, line in ipairs(splitInput(input)) do
			context:out(line)
		end

		for _, name in ipairs(args) do
			-- input already ends in a newline when it came from a pipe
			filesystem.write(context:resolve(name), input)
		end
	end,
}

Text.commands.diff = {
	usage = "diff [-u] [-c <lines>] <file> <file>",
	desc = t("diffDesc", "show what differs between two files"),
	run = function(context, args)
		local contextLines, positional = 3, {}

		local i = 1
		while args[i] do
			if args[i] == "-u" then
				i = i + 1
			elseif args[i] == "-c" then
				contextLines = tonumber(args[i + 1]) or contextLines
				i = i + 2
			else
				positional[#positional + 1] = args[i]
				i = i + 1
			end
		end

		if #positional < 2 then
			context:err("diff: usage: diff [-c <lines>] <file> <file>")
			return
		end

		local left, right = readLines(context:resolve(positional[1])), readLines(context:resolve(positional[2]))

		if not left then
			context:err(("diff: %s: unreadable"):format(positional[1]))
			return
		elseif not right then
			context:err(("diff: %s: unreadable"):format(positional[2]))
			return
		end

		if #left > MAX_LINES or #right > MAX_LINES then
			context:err(("diff: %s has %d lines, the limit is %d"):format(
				#left > MAX_LINES and positional[1] or positional[2],
				math.max(#left, #right), MAX_LINES
			))
			context:dim("Split the file or compare the sections you care about.")
			return
		end

		local operations = diffSequences(left, right)
		local hunks = buildHunks(operations, contextLines)

		if #hunks == 0 then
			context:ok(t("diffIdentical", "The files are identical."))
			return
		end

		local added, removed = 0, 0
		for _, op in ipairs(operations) do
			if op[1] == "+" then added = added + 1 elseif op[1] == "-" then removed = removed + 1 end
		end

		context:heading(("--- %s"):format(positional[1]))
		context:heading(("+++ %s"):format(positional[2]))

		for _, hunk in ipairs(hunks) do
			context:accent(("@@ -%d,%d +%d,%d @@"):format(
				hunk.aStart or 0, hunk.aCount, hunk.bStart or 0, hunk.bCount
			))

			for _, line in ipairs(hunk.lines) do
				if line ~= "" then
					local color = line:sub(1, 1) == "+" and COLOR.ok
						or line:sub(1, 1) == "-" and COLOR.error or nil

					context:out(line, color)
				end
			end

			context:out("")
		end

		context:out(("%s  +%d  -%d  %s"):format(
			t("diffSummary", "changed:"), added, removed, t("diffLines", "lines")
		))
	end,
}

--------------------------------------------------------------------------------
-- patch
--------------------------------------------------------------------------------

-- Applies a unified diff produced by `diff -u`. Only the hunks are read, and
-- only the -/+ line kinds; the line numbers in the header are used to position
-- the hunk, and a mismatch is reported rather than guessed at.
Text.commands.patch = {
	usage = "patch [-n|--dry] <original> <diff>",
	desc = t("patchDesc", "apply a unified diff to a file"),
	run = function(context, args)
		local dry, positional = false, {}

		for _, token in ipairs(args) do
			if token == "-n" or token == "--dry" then
				dry = true
			else
				positional[#positional + 1] = token
			end
		end

		if #positional < 2 then
			context:err("patch: usage: patch [-n] <original> <diff>")
			return
		end

		local originalPath, diffPath = context:resolve(positional[1]), context:resolve(positional[2])
		local original, diff = readLines(originalPath), readLines(diffPath)

		if not original then
			context:err(("patch: %s: unreadable"):format(positional[1]))
			return
		elseif not diff then
			context:err(("patch: %s: unreadable"):format(positional[2]))
			return
		end

		-- Collect hunks: @@ -aStart,aCount +bStart,bCount @@ then body lines
		local hunks, current = {}, nil

		for i = 1, #diff do
			local line = diff[i]
			local aStart, aCount, bStart = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?%d* @@")

			if aStart then
				current = {
					at = tonumber(aStart),
					skip = tonumber(aCount) or 1,
					lines = {},
				}
				hunks[#hunks + 1] = current
			elseif current and line:sub(1, 1) == "\\" then
				-- "\ No newline at end of file" -- nothing to do
			elseif current and (line:sub(1, 1) == " " or line:sub(1, 1) == "+" or line:sub(1, 1) == "-") then
				current.lines[#current.lines + 1] = line
			end
		end

		if #hunks == 0 then
			context:err(t("patchNoHunks", "No hunks found in the diff."))
			return
		end

		-- Walk backwards so earlier hunks keep their line numbers valid.
		table.sort(hunks, function(a, b) return a.at > b.at end)

		local applied, skipped = 0, 0

		for _, hunk in ipairs(hunks) do
			local expected = {}
			for i = 1, hunk.skip do
				expected[#expected + 1] = original[hunk.at + i - 1]
			end

			local matches = true
			local seen = 0

			for _, line in ipairs(hunk.lines) do
				local kind = line:sub(1, 1)

				if kind == " " or kind == "-" then
					seen = seen + 1
					local want = line:sub(2)

					if original[hunk.at + seen - 1] ~= want then
						matches = false
						break
					end
				end
			end

			if not matches then
				skipped = skipped + 1
				context:warn(("  hunk at line %d does not apply"):format(hunk.at))
			else
				-- splice: replace `skip` lines with the hunk's result
				local result = {}
				for _, line in ipairs(hunk.lines) do
					local kind = line:sub(1, 1)
					if kind == " " or kind == "+" then result[#result + 1] = line:sub(2) end
				end

				for k = hunk.skip, 1, -1 do
					table.remove(original, hunk.at + k - 1)
				end

				-- table.insert at 0 appends, so a pure insertion before the first
				-- line has to go in at index 1.
				local at = hunk.skip > 0 and hunk.at or hunk.at + 1
				for k = 1, #result do
					table.insert(original, at + k - 1, result[k])
				end

				applied = applied + 1
			end
		end

		if applied == 0 then
			context:err(t("patchFailed", "Nothing could be applied."))
			return
		end

		if dry then
			context:ok(("patch: %d hunk(s) would apply, %d skipped (dry run)"):format(applied, skipped))
			return
		end

		if writeLines(originalPath, original) then
			context:ok(("patch: applied %d hunk(s) to %s%s"):format(
				applied, positional[1], skipped > 0 and (", %d skipped"):format(skipped) or ""
			))
		else
			context:err(("patch: could not write %s"):format(positional[1]))
		end
	end,
}

--------------------------------------------------------------------------------

return Text
