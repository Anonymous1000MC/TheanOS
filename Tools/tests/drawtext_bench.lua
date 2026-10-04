-- Micro-benchmark for the drawText ASCII fast path.
--
-- IMPORTANT: this runs on the build machine's Lua, not on OpenComputers
-- hardware. Treat the numbers as evidence that the change is not slower and
-- scales better, not as a prediction of on-device frame time. The real
-- interpreter there is a C build on a weak ARM core with no JIT, where
-- per-call overhead is comparatively even worse -- so if the win holds here it
-- should hold there, but the magnitude will differ.
--
-- Run from the repository root:  lua5.3 Tools/tests/drawtext_bench.lua

local root = os.getenv("THEANOS_ROOT") or "."

local function colorBlend(a) return a end
local function unicodeLen(s) return #s end
local function unicodeSub(s, i, j) return string.sub(s, i, j) end
local function unicodeWlen(s) return #s end

local source = assert(io.open(root .. "/Libraries/Screen.lua")):read("*a")
local bodyStart = assert(source:find("local function drawText", 1, true))
local bodyStop = assert(source:find("\nlocal function ", bodyStart + 10, true))
local body = source:sub(bodyStart, bodyStop)

-- The pre-optimisation implementation, verbatim, for a like-for-like baseline.
local baselineText = [[
local function drawText(x, y, textColor, text, transparency)
	if y < drawLimitY1 or y > drawLimitY2 then return end
	local charIndex, screenIndex, char, charWlen = 1, bufferWidth * (y - 1) + x
	for charIndex = 1, unicodeLen(text) do
		char = unicodeSub(text, charIndex, charIndex)
		charWlen = unicodeWlenCache[char]
		if not charWlen then
			charWlen = unicodeWlen(char)
			unicodeWlenCache[char] = charWlen
		end
		for i = 1, charWlen do
			if x >= drawLimitX1 and x + charWlen - 1 <= drawLimitX2 then
				if transparency then
					newFrameForegrounds[screenIndex] = colorBlend(newFrameBackgrounds[screenIndex], textColor, transparency)
				else
					newFrameForegrounds[screenIndex] = textColor
				end
				newFrameChars[screenIndex] = i == 1 and char or " "
			end
			x, screenIndex = x + 1, screenIndex + 1
		end
	end
end
return drawText
]]

local function makeEnv()
	return setmetatable({
		bufferWidth = 80, bufferHeight = 25,
		drawLimitX1 = 1, drawLimitY1 = 1, drawLimitX2 = 80, drawLimitY2 = 25,
		newFrameBackgrounds = {}, newFrameForegrounds = {}, newFrameChars = {},
		unicodeLen = unicodeLen, unicodeSub = unicodeSub,
		unicodeWlen = unicodeWlen, unicodeWlenCache = {},
		colorBlend = colorBlend,
		stringSub = string.sub, stringFind = string.find,
	}, {__index = _G})
end

local function compileNew()
	local code = body .. "\nreturn drawText\n"
	return assert(load(code, "drawText", "t", makeEnv()))()
end

local function compileOld()
	return assert(load(baselineText, "drawTextOld", "t", makeEnv()))()
end

-- A realistic screenful: mostly short ASCII labels, like the desktop and apps.
local LINES = {}
for row = 1, 25 do
	local parts = {}
	for column = 1, 6 do
		parts[#parts + 1] = "label" .. row .. "_" .. column
	end
	LINES[#LINES + 1] = table.concat(parts, "  ")
end

local REPEATS = 400 -- full-screen repaints

local function timeScreen(fn)
	-- warm up
	for row = 1, 25 do fn(1, row, 0xE1E1E1, LINES[row], nil) end

	local start = os.clock()
	for _ = 1, REPEATS do
		for row = 1, 25 do
			fn(1, row, 0xE1E1E1, LINES[row], nil)
		end
	end
	return os.clock() - start
end

print("drawText micro-benchmark")
print(("  screen: 25 lines x %d chars, %d full repaints = %d calls")
	:format(#LINES[1], REPEATS, REPEATS * 25))
print("  NOTE: measured on the build machine, not on OpenComputers hardware.")
print()

local envOld, envNew = makeEnv(), makeEnv()
local old = compileOld()
local new = compileNew()

-- interleave to reduce ordering bias, take the best of each
local bestOld, bestNew = math.huge, math.huge
for round = 1, 3 do
	bestOld = math.min(bestOld, timeScreen(old))
	bestNew = math.min(bestNew, timeScreen(new))
end

print(("  baseline (unicode.sub per char): %8.4f s"):format(bestOld))
print(("  optimised (ASCII fast path)    : %8.4f s"):format(bestNew))
print(("  speedup                        : %8.2fx"):format(bestOld / bestNew))
print(("  per repaint: %.3f ms -> %.3f ms"):format(bestOld / REPEATS * 1000, bestNew / REPEATS * 1000))

-- Non-ASCII must not regress: it takes the same path as before.
local wide = string.rep("\195\169", 30)
local function timeWide(fn)
	fn(1, 1, 0xE1E1E1, wide, nil)
	local start = os.clock()
	for _ = 1, REPEATS * 25 do fn(1, 1, 0xE1E1E1, wide, nil) end
	return os.clock() - start
end

local wideOld = math.min(timeWide(old), timeWide(old))
local wideNew = math.min(timeWide(new), timeWide(new))
print()
print("  non-ASCII (falls through to the unchanged path):")
print(("    baseline %.4f s, optimised %.4f s"):format(wideOld, wideNew))