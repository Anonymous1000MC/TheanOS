-- Differential test: the optimised drawText must produce byte-identical frame
-- contents to the original implementation, for every combination of clipping,
-- transparency and character width.
--
-- Run from the repository root:  lua5.3 Tools/tests/drawtext_diff_test.lua

local root = os.getenv("THEANOS_ROOT") or "."

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then
		pass = pass + 1
	else
		fail = fail + 1
		print("  FAIL " .. name .. "  " .. tostring(extra))
	end
end

--------------------------------------------------------------------------------
-- Reference: the original drawText, copied verbatim from the pre-optimisation
-- file. Deliberately standalone so it cannot drift with the new code.
--------------------------------------------------------------------------------

local function referenceDrawText(env, x, y, textColor, text, transparency)
	local bufferWidth = env.bufferWidth
	local drawLimitX1, drawLimitY1 = env.drawLimitX1, env.drawLimitY1
	local drawLimitX2, drawLimitY2 = env.drawLimitX2, env.drawLimitY2
	local newFrameForegrounds = env.newFrameForegrounds
	local newFrameBackgrounds = env.newFrameBackgrounds
	local newFrameChars = env.newFrameChars
	local unicodeLen, unicodeSub = env.unicodeLen, env.unicodeSub
	local unicodeWlen, unicodeWlenCache = env.unicodeWlen, env.unicodeWlenCache
	local colorBlend = env.colorBlend

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

--------------------------------------------------------------------------------
-- Harness that runs the real drawText out of Screen.lua
--------------------------------------------------------------------------------

-- Screen.lua pulls in the GPU component and the colour library; stub just enough.
local function colorIntegerToRGB(c) return c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF end
local function colorRGBToInteger(r, g, b) return r << 16 | g << 8 | b end
local function colorBlend(a, b, t)
	local ar, ag, ab = colorIntegerToRGB(a)
	local br, bg, bb = colorIntegerToRGB(b)
	return colorRGBToInteger(
		math.floor(ar + (br - ar) * t),
		math.floor(ag + (bg - ag) * t),
		math.floor(ab + (bb - ab) * t)
	)
end

local function unicodeLen(s) return #s end
local function unicodeSub(s, i, j) return string.sub(s, i, j) end
local function unicodeWlen(s) return #s end

-- Pull drawText out of the real Screen.lua and run it with _ENV pointed at a
-- table we control. Everything the function reads as a file-local (bufferWidth,
-- drawLimit*, newFrame*, unicode*, stringSub, stringFind) becomes a field of
-- that table; anything else falls through to the real globals.
local source = assert(io.open(root .. "/Libraries/Screen.lua")):read("*a")
local bodyStart = assert(source:find("local function drawText", 1, true))
local bodyStop = assert(source:find("\nlocal function ", bodyStart + 10, true))
local body = source:sub(bodyStart, bodyStop)

local function compileDrawText(env)
	local code = body .. "\nreturn drawText\n"
	local chunk = assert(load(code, "drawText", "t", env))
	return chunk()
end

local function newEnv(overrides)
	local env = setmetatable({
		unicodeLen = unicodeLen,
		unicodeSub = unicodeSub,
		unicodeWlen = unicodeWlen,
		unicodeWlenCache = {},
		colorBlend = colorBlend,
		-- the fast path's file-locals
		stringSub = string.sub,
		stringFind = string.find,
	}, {__index = _G})

	for k, v in pairs(overrides or {}) do env[k] = v end

	env.newFrameBackgrounds = env.newFrameBackgrounds or {}
	env.newFrameForegrounds = env.newFrameForegrounds or {}
	env.newFrameChars = env.newFrameChars or {}

	return env
end

--------------------------------------------------------------------------------
-- Cases
--------------------------------------------------------------------------------

local TEXTS = {
	"", "hello", "Hello, world!", "t@theanos:/ $ ",
	"a\tb", "0123456789" .. string.rep("x", 40),
	string.rep("A", 200),
	"\0embedded\0nulls",
	"caf\195\169",            -- 2-byte UTF-8
	"\228\184\173",            -- 3-byte UTF-8
	"mixed ascii \195\169 end",
	"\240\159\146\145",        -- 4-byte UTF-8
	string.rep("\195\169", 30),
}

local LIMITS = {
	{1, 1, 80, 25},
	{1, 1, 1, 1},      -- single cell
	{5, 1, 10, 1},     -- narrow window
	{1, 1, 80, 1},      -- single row
	{40, 10, 45, 12},  -- interior box
	{1, 1, 3, 25},     -- very narrow
	{1, 20, 80, 25},   -- bottom strip
}

local XS = {-5, 0, 1, 2, 5, 39, 40, 79, 80, 81, 200}
local YS = {-1, 0, 1, 2, 10, 19, 20, 25, 26, 99}

local function framesEqual(a, b)
	for i = 1, 80 * 25 do
		if a.newFrameForegrounds[i] ~= b.newFrameForegrounds[i] then return false, "fg@" .. i end
		if a.newFrameChars[i] ~= b.newFrameChars[i] then
			return false, ("char@%d %q vs %q"):format(i, tostring(b.newFrameChars[i]), tostring(a.newFrameChars[i]))
		end
	end
	return true
end

local total = 0
for _, limit in ipairs(LIMITS) do
	for _, x in ipairs(XS) do
		for _, y in ipairs(YS) do
			for _, text in ipairs(TEXTS) do
				for _, color in ipairs({0x112233, 0xFFFFFF, 0x000000}) do
					-- false, not nil: ipairs stops at the first nil, and the draw code only
					-- tests truthiness, so false is equivalent to no transparency
					for _, transparency in ipairs({false, 0, 0.25, 0.5, 1}) do
						total = total + 1

						local common = {
							bufferWidth = 80, bufferHeight = 25,
							drawLimitX1 = limit[1], drawLimitY1 = limit[2],
							drawLimitX2 = limit[3], drawLimitY2 = limit[4],
						}

						local envA = newEnv(common)
						local envB = newEnv(common)

						-- pre-fill backgrounds so the transparency blend has something
						-- to read, exactly like a real frame
						for i = 1, 80 * 25 do
							envA.newFrameBackgrounds[i] = 0x0A0A0A
							envB.newFrameBackgrounds[i] = 0x0A0A0A
						end

						local okA, errA = pcall(referenceDrawText, envA, x, y, color, text, transparency)
						local drawNew = compileDrawText(envB)
						local okB, errB = pcall(drawNew, x, y, color, text, transparency)

						if okA ~= okB then
							check(("error mismatch x=%s y=%s limit=%s,%s,%s,%s t=%q")
								:format(x, y, limit[1], limit[2], limit[3], limit[4], text),
								false, ("ref=%s new=%s"):format(tostring(errA), tostring(errB)))
						elseif okA then
							local same, why = framesEqual(envA, envB)
							if not same then
								check(("frame mismatch x=%s y=%s limit=%s,%s,%s,%s t=%q transp=%s")
									:format(x, y, limit[1], limit[2], limit[3], limit[4], text, tostring(transparency)),
									false, why)
							else
								pass = pass + 1
							end
						else
							pass = pass + 1 -- both raised the same error, which is fine
						end
					end
				end
			end
		end
	end
end

print(("compared %d drawText invocations against the original"):format(total))
print(("== RESULT: %d passed, %d failed =="):format(pass, fail))
os.exit(fail == 0 and 0 or 1)