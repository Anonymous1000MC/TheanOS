-- TheanOS EFI firmware (modernized classic BIOS)
--
-- Modernized port of the classic TheanOS BIOS: POST, welcome menu, tabbed pages
--   * System information
--   * Boot or repair (disk list + service actions)
--   * BIOS settings
--
-- Visual direction: near-black / dark charcoal, warm off-white text,
-- hazard orange accents, acid green success indicators.
-- Every component call is guarded; never hands nil to EEPROM; works on stock
-- OpenComputers / Lua 5.3.

local cl, cp, invoke = component.list, component.proxy, component.invoke

-- Lua 5.3 compat: prefer 'unicode', fall back to 'utf8'
local unicode = unicode or utf8

local gpu, InternetInt, internet

local users
local filesystems

local CurrentMenu = {}
local BootMenuStage = { 1 } -- 1 - current str, 2 - max strs
local ServiceMenuStage
local BootPageFirstStart, SystemInformationPageFirstStart = true, true

local Bios = { StockSettings = { language = 'en' } }

local Modifier = {}
local UI = {}

local BiosSetingsPage = {
	Element = 1,
	Strings = {
		' Language: [en]',
		' Format EEPROM data',
		' Debug format EEPROM data',
		' Debug format EEPROM code',
	},
	Descriptions = {
		{ 'Changes the language',
			'of the BIOS.',
			'In order for',
			'the changes',
			'to take effect,',
			'you must restart',
			'the computer.',
			'[Not ready yet]' },
		{ 'deletes BIOS data',
			'(resets settings)' },
	},
}

local ServiceMenuPage = {
	Descriptions = {
		{ 'Try to boot from',
			'the disk.',
			'If you are using MineOS',
			'then apply',
			'the bootloader patch' },
		{ 'Applies the bootloader',
			'patch' },
		{},
		{ 'Deletes all data',
			'from disk' },
	},
}

local BiosVersion = '1.9.1'

local Debug = {}

-- Palette (modernized): near-black, dark charcoal, warm off-white,
-- hazard orange, acid green.
local C = {
	bg       = 0x0A0C0E,   -- near-black
	panel    = 0x12161C,   -- dark charcoal
	text     = 0xE8E4D8,   -- warm off-white
	dim      = 0x8A94A0,   -- muted grey-blue
	bright   = 0xFFFFFF,
	accent   = 0xE89C3D,   -- hazard orange
	ok       = 0x9BE860,   -- acid green
	bad      = 0xE05A5A,
}

------------------------------------------
-- EEPROM boot address helpers (guarded)
------------------------------------------
computer.getBootAddress = function()
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return nil end
	local data = invoke(eepromAddr, 'getData')
	if not data then return nil end
	return string.sub(data, 1, 36)
end

computer.setBootAddress = function(address)
	if type(address) ~= 'string' or #address ~= 36 then return nil end
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return nil end
	local data = invoke(eepromAddr, 'getData')
	if not data then return nil end
	local newData = address .. string.sub(data, 37, #data)
	return invoke(eepromAddr, 'setData', newData)
end

function Bios.FormatData()
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return end
	invoke(eepromAddr, 'setData', '------------------------------------------------------------------------en')
end

function Bios.SetLanguage(key)
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return end
	local data = invoke(eepromAddr, 'getData')
	if not data then return end
	local newData = string.sub(data, 1, 72) .. key .. string.sub(data, 75, #data)
	return invoke(eepromAddr, 'setData', newData)
end

function Bios.GetLanguage()
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return 'en' end
	local data = invoke(eepromAddr, 'getData')
	if not data then return 'en' end
	return string.sub(data, 73, 74)
end

function Bios.GetPriorityBootAddress()
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return nil end
	local data = invoke(eepromAddr, 'getData')
	if not data then return nil end
	return string.sub(data, 37, 72)
end

function Bios.SetPriorityBootAddress(address)
	if type(address) ~= 'string' or #address ~= 36 then return nil end
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return nil end
	local data = invoke(eepromAddr, 'getData')
	if not data then return nil end
	local newData = string.sub(data, 1, 36) .. address .. string.sub(data, 73, #data)
	return invoke(eepromAddr, 'setData', newData)
end

------------------------------------------
function Modifier.GetModifierOpportunity()
	if not ServiceMenuStage or not ServiceMenuStage[2] then return false end
	if ServiceMenuStage[2][6] == 'MineOS' then
		local address = ServiceMenuStage[2][4]
		local bootCode = ''

		local handle = invoke(address, 'open', '/OS.lua')
		if handle then
			repeat
				local chunk = invoke(address, 'read', handle, math.huge)
				bootCode = bootCode .. (chunk or '')
			until not chunk
		end

		if bootCode then
			local indexs = {}
			if string.sub(bootCode, 180, 249) == 'component.proxy(component.proxy(component.list("eeprom")()).getData())' then
				indexs[1], indexs[2] = 179, 250
			end

			if indexs[1] then
				return indexs
			else
				return false
			end
		else
			return false
		end
	end
end

function Modifier.TryModify()
	if not ServiceMenuStage or not ServiceMenuStage[2] then return end
	if ServiceMenuStage[2][6] == 'MineOS' then
		local address = ServiceMenuStage[2][4]
		local bootCode = ''

		local handle = invoke(address, 'open', '/OS.lua')
		if handle then
			repeat
				local chunk = invoke(address, 'read', handle, math.huge)
				bootCode = bootCode .. (chunk or '')
			until not chunk
			invoke(address, 'close', handle)
		end

		if not ServiceMenuStage[3] then return end
		local newBootCode = string.sub(bootCode, 1, ServiceMenuStage[3][2])
			.. 'component.proxy(component.proxy(component.list("eeprom")()).getData():sub(1,36))'
			.. string.sub(bootCode, ServiceMenuStage[3][3], #bootCode)

		local handle = invoke(address, 'open', '/OS.lua', 'w')
		if handle then
			invoke(address, 'write', handle, newBootCode)
			invoke(address, 'close', handle)
		end
	end
end
------------------------------------------
function Debug.FormatData()
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return end
	invoke(eepromAddr, 'setData', '')
end

function Debug.FormatBios()
	local eepromAddr = cl('eeprom')()
	if not eepromAddr then return end
	invoke(eepromAddr, 'set', '')
end
------------------------------------------
local function setBackground(a)
	if gpu then pcall(gpu.setBackground, gpu, a) end
end

local function setForeground(a)
	if gpu then pcall(gpu.setForeground, gpu, a) end
end

local function fill(...)
	if gpu then pcall(gpu.fill, gpu, ...) end
end

local function set(...)
	if gpu then pcall(gpu.set, gpu, ...) end
end

local function setResolution(...)
	if gpu then pcall(gpu.setResolution, gpu, ...) end
end

local function fillBackground()
	if gpu then
		local w, h = gpu.getResolution()
		gpu.fill(1, 1, w, h, ' ')
	end
end

local function safeBeep(...)
	pcall(computer.beep, ...)
end

local function SetTextInTheMiddle(y, space, text, correct)
	if not gpu then return end
	local len = #text
	local x
	if correct then
		x = math.floor(space / 2 - len / 2 + correct)
	else
		x = math.floor(space / 2 - len / 2)
	end
	set(x, y, text)
end
------------------------------------------
local function BootWithAddress(address)
	computer.setBootAddress(address)
	local handle
	if ServiceMenuStage[2][6] == 'MineOS' then
		handle = invoke(address, 'open', '/OS.lua')
	else
		handle = invoke(address, 'open', '/init.lua')
	end
	if not handle then return end
	local bootCode = ''
	repeat
		local chunk = invoke(address, 'read', handle, math.huge)
		bootCode = bootCode .. (chunk or '')
	until not chunk
	invoke(address, 'close', handle)

	load(bootCode)()
end

local function BootWithoutAddress()
	local PriorityBootAddress = Bios.GetPriorityBootAddress()
	if PriorityBootAddress and cp(PriorityBootAddress)
		and ((invoke(PriorityBootAddress, 'exists', '/init.lua') and not invoke(PriorityBootAddress, 'isDirectory', 'init.lua'))
		or (invoke(PriorityBootAddress, 'exists', '/OS.lua') and not invoke(PriorityBootAddress, 'isDirectory', 'OS.lua'))) then

		computer.setBootAddress(PriorityBootAddress)

		local handle
		if invoke(PriorityBootAddress, 'exists', '/OS.lua') and not invoke(PriorityBootAddress, 'isDirectory', 'OS.lua') then
			handle = invoke(PriorityBootAddress, 'open', '/OS.lua')
		elseif invoke(PriorityBootAddress, 'exists', '/init.lua') and not invoke(PriorityBootAddress, 'isDirectory', 'init.lua') then
			handle = invoke(PriorityBootAddress, 'open', '/init.lua')
		end

		if not handle then return end
		local bootCode = ''
		repeat
			local chunk = invoke(PriorityBootAddress, 'read', handle, math.huge)
			bootCode = bootCode .. (chunk or '')
		until not chunk
		invoke(PriorityBootAddress, 'close', handle)

		load(bootCode)()
	else
		for address in cl('filesystem') do
			if cp(address).getLabel() ~= 'tmpfs' then
				if (invoke(address, 'exists', '/init.lua') and not invoke(address, 'isDirectory', 'init.lua'))
				or (invoke(address, 'exists', '/OS.lua') and not invoke(address, 'isDirectory', 'OS.lua')) then

					computer.setBootAddress(address)

					local handle
					if invoke(address, 'exists', '/OS.lua') and not invoke(address, 'isDirectory', 'OS.lua') then
						handle = invoke(address, 'open', '/OS.lua')
					elseif invoke(address, 'exists', '/init.lua') and not invoke(address, 'isDirectory', 'init.lua') then
						handle = invoke(address, 'open', '/init.lua')
					end

					if handle then
						local bootCode = ''
						repeat
							local chunk = invoke(address, 'read', handle, math.huge)
							bootCode = bootCode .. (chunk or '')
						until not chunk
						invoke(address, 'close', handle)

						load(bootCode)()
					end
				end
			end
		end
	end
end
------------------------------------------
local function getOS(address)
	if invoke(address, 'exists', '/OS.lua') and not invoke(address, 'isDirectory', '/OS.lua') then -- MineOS
		return 'MineOS'
	elseif invoke(address, 'exists', '/init.lua') and not invoke(address, 'isDirectory', '/init.lua') then -- OpenOS
		local isOpenOS, path
		if invoke(address, 'exists', '/lib/tools/boot.lua') then
			isOpenOS = true
			path = '/lib/tools/boot.lua'
		elseif invoke(address, 'exists', '/lib/core/boot.lua') then
			isOpenOS = true
			path = '/lib/core/boot.lua'
		end
		local handle = invoke(address, 'open', path)
		if not handle then return 'unknown' end
		local bootCode = ''
		repeat
			local chunk = invoke(address, 'read', handle, math.huge)
			bootCode = bootCode .. (chunk or '')
		until not chunk
		local _, strEnd = string.find(bootCode, '_G._OSVERSION = "')
		invoke(address, 'close', handle)
		return string.sub(bootCode, strEnd + 1, string.find(bootCode, '"', strEnd + 1) - 1)
	end
	return 'unknown'
end

local function SystemInformationPageUpdate()
	local totalMemory, freeMemory = computer.totalMemory(), computer.freeMemory()
	fill(6, 7, 41, 3, ' ')
	set(6, 7, 'Total memory: ' .. totalMemory)
	set(6, 8, 'Used memory: ' .. totalMemory - freeMemory)
	set(6, 9, 'Free memory: ' .. freeMemory)

	fill(6, 13, 41, 4, ' ')
	local uptime = computer.uptime()
	if uptime > 60 then
		uptime = tostring(math.floor(uptime / 60 * 10) / 10) .. 'm'
	else
		uptime = uptime .. 's'
	end
	set(6, 13, 'Computer uptime: ' .. uptime)
	set(6, 14, 'Computer max energy: ' .. tostring(computer.maxEnergy()))
	set(6, 15, 'Computer energy: ' .. math.floor(computer.energy()))
	set(6, 16, 'Boot priority address: ' .. unicode.sub(Bios.GetPriorityBootAddress() or '', 1, 18))
end
------------------------------------------

local function ClearLastPage()
	local lastBackground, lastForeground = gpu.getBackground(), gpu.getForeground()

	fill(50, 4, 24, 20, ' ') -- side panel
	fill(2, 4, 47, 20, ' ') -- page

	fill(1, 4, 1, 20, '║')
	fill(49, 4, 1, 20, '║')
	set(1, 5, '╟───────────────────────────────────────────────╢')

	setBackground(C.panel)
	setForeground(C.text)
	set(3, 2, '  System information  ')
	set(25, 2, '  Boot or repair  ')
	set(43, 2, '  Bios settings  ')

	setBackground(lastBackground)
	setForeground(lastForeground)
end

local function got()
	-- Request 74x25; fall back gracefully if the hardware can't do it.
	local ok, w, h = pcall(function() return gpu.setResolution(74, 25) end)
	if not ok then
		w, h = gpu.getResolution()
	end
	setBackground(C.bg)
	setForeground(C.text)
	fill(1, 1, w or 74, h or 25, ' ')
	set(1, 3, '╔')
	fill(2, 3, (w or 74) - 2, 1, '═')
	set(w or 74, 3, '╗')
	fill(1, 4, 1, h and (h - 1) or 20, '║')
	fill(w or 74, 4, 1, h and (h - 1) or 20, '║')
	fill(2, h or 24, (w or 74) - 2, 1, '═')
	set(1, h or 24, '╚')
	set(w or 74, h or 24, '╝')
	set((w or 74) - 25, 3, '╦')
	fill((w or 74) - 25, 4, 1, h and (h - 1) or 20, '║')
	set((w or 74) - 25, h or 24, '╩')
	set(1, 5, '╟───────────────────────────────────────────────╢')
	setBackground(C.accent)
	fill(1, 1, w or 74, 1, ' ')
	setForeground(C.text)
	set(math.floor((w or 74) / 2 - 14), 1, 'Advanced BIOS setup utility')
	setBackground(C.panel)
	fill(1, 2, w or 74, 1, ' ')
	setForeground(C.text)
	set(3, 2, '  System information  ')
	set(math.floor((w or 74) / 2 - 8), 2, '  Boot or repair  ')
	set((w or 74) - 30, 2, '  Bios settings  ')
	fill(1, h or 25, w or 74, 1, ' ')
	setForeground(C.dim)
	SetTextInTheMiddle(h or 25, w or 74, 'v' .. BiosVersion .. ' TheanOS EFI')
end

local function GetSystemInformationPage()
	CurrentMenu = 'SystemInformation'

	setBackground(C.panel)
	setForeground(C.text)
	ClearLastPage()
	set(3, 2, '  System information  ')
	SetTextInTheMiddle(4, 49, 'Information about your system')

	set(50, 21, '←→    Select Screen')
	set(50, 22, 'F9    Save and Exit')

	local totalMemory, freeMemory = computer.totalMemory(), computer.freeMemory()
	set(4, 6, 'Memory information:')
	set(6, 7, 'Total memory: ' .. totalMemory)
	set(6, 8, 'Used memory: ' .. totalMemory - freeMemory)
	set(6, 9, 'Free memory: ' .. freeMemory)

	set(4, 11, 'Computer information:')
	set(6, 12, 'Computer address: ' .. unicode.sub(tostring(computer.address()), 1, 8))
	set(6, 13, 'Computer uptime: ' .. tostring(computer.uptime()))
	set(6, 14, 'Computer max energy: ' .. tostring(computer.maxEnergy()))
	set(6, 15, 'Computer energy: ' .. math.floor(computer.energy()))
	set(6, 16, 'Boot priority address: ' .. unicode.sub(Bios.GetPriorityBootAddress() or '', 1, 18))
	set(6, 17, 'Last boot disc address: ' .. unicode.sub(tostring(computer.getBootAddress()), 1, 18))
end

local function CheckDriveReadyToStart()
	if filesystems[BootMenuStage[1]][5] and filesystems[BootMenuStage[1]][6] ~= 'unknown' then
		return 'YES!'
	elseif filesystems[BootMenuStage[1]][5] then
		return 'maybe'
	else
		return 'not'
	end
end

local function GetBootPage(update)
	CurrentMenu = 'BootAndRepair'

	setBackground(C.panel)
	setForeground(C.text)
	ClearLastPage()
	set(25, 2, '  Boot or repair  ')
	SetTextInTheMiddle(4, 49, 'Select device to boot or repair it')

	set(50, 18, '←→    Select Screen')
	set(50, 19, '↑↓    Select Item')
	set(50, 20, 'Enter Select Field')
	set(50, 21, 'F5    Update device list')
	set(50, 22, 'F9    Save and Exit')

	if BootPageFirstStart or update then
		filesystems = {}
		for address in cl('filesystem') do
			local b = cp(address)
			local label = b.getLabel()
			if label ~= 'tmpfs' then
				local ready, d
				if (invoke(address, 'exists', '/init.lua') and not invoke(address, 'isDirectory', '/init.lua'))
				or (invoke(address, 'exists', '/OS.lua') and not invoke(address, 'isDirectory', '/OS.lua')) then
					d = ' [Ready to boot]'
					ready = true
				else
					d = ' [Not ready to boot]'
					ready = false
				end

				label = label or 'unknown'
				if #label > 11 then
					label = unicode.sub(label, 1, 8) .. '...'
				end

				table.insert(filesystems, { b, d, label, address, ready, getOS(address) })
			end
		end
		BootPageFirstStart = false
	end

	for i = 1, #filesystems do
		if i == BootMenuStage[1] then
			setForeground(C.bright)
			set(4, 5 + i, '► [' .. unicode.sub(filesystems[i][4], 1, 8) .. '] ' .. filesystems[i][3] .. filesystems[i][2])
			setForeground(C.text)
		else
			set(4, 5 + i, '  [' .. unicode.sub(filesystems[i][4], 1, 8) .. '] ' .. filesystems[i][3] .. filesystems[i][2])
		end
	end
	BootMenuStage[2] = #filesystems

	if BootMenuStage[2] ~= 0 then
		set(51, 4, 'Regular hard drive...')
		set(51, 6, 'Address: ' .. unicode.sub(filesystems[BootMenuStage[1]][4], 1, 13))
		set(51, 7, 'Name: ' .. unicode.sub(filesystems[BootMenuStage[1]][3], 1, 15))
		set(51, 8, 'Ready to boot: ' .. CheckDriveReadyToStart())
		set(51, 9, 'OS: ' .. filesystems[BootMenuStage[1]][6])
		set(51, 10, 'Total space: ' .. tostring(filesystems[BootMenuStage[1]][1].spaceTotal()))
		set(51, 11, 'Used space: ' .. tostring(filesystems[BootMenuStage[1]][1].spaceUsed()))
		set(51, 12, 'Free space: ' .. tostring(filesystems[BootMenuStage[1]][1].spaceTotal() - filesystems[BootMenuStage[1]][1].spaceUsed()))
	end
end

function UI.DrawDescription(Table, element)
	setForeground(C.dim)

	fill(50, 4, 24, 15, ' ')
	if Table.Descriptions[element] then
		local description = Table.Descriptions[element]
		for i = 1, #description do
			SetTextInTheMiddle(3 + i, 24, description[i], 50)
		end
	end
end

function BiosSetingsPage.OnChangeField(last)
	setForeground(C.dim)
	set(4, 6 + last, ' ' .. BiosSetingsPage.Strings[last])

	setForeground(C.bright)
	set(4, 6 + BiosSetingsPage.Element, '►' .. BiosSetingsPage.Strings[BiosSetingsPage.Element])

	UI.DrawDescription(BiosSetingsPage, BiosSetingsPage.Element)
end

function BiosSetingsPage.Draw()
	CurrentMenu = 'BiosSetings'

	setBackground(C.panel)
	setForeground(C.text)
	ClearLastPage()
	set(43, 2, '  Bios settings  ')
	SetTextInTheMiddle(4, 49, 'BIOS setup')

	set(50, 19, '←→    Select Screen')
	set(50, 20, '↑↓    Select Item')
	set(50, 21, 'Enter Select Field')
	set(50, 22, 'F9    Save and Exit')

	UI.DrawDescription(BiosSetingsPage, BiosSetingsPage.Element)

	setForeground(C.dim)
	set(4, 7, ' ' .. BiosSetingsPage.Strings[1])
	set(4, 8, ' ' .. BiosSetingsPage.Strings[2])
	set(4, 9, ' ' .. BiosSetingsPage.Strings[3])
	set(4, 10, ' ' .. BiosSetingsPage.Strings[4])

	setForeground(C.bright)
	set(4, 6 + BiosSetingsPage.Element, '►' .. BiosSetingsPage.Strings[BiosSetingsPage.Element])
end

local function BootOtr(this, last)
	if this == last then return end

	setForeground(C.bright)
	set(4, 5 + this, '► [' .. unicode.sub(filesystems[this][4], 1, 8) .. '] ' .. filesystems[this][3] .. filesystems[this][2])

	setForeground(C.text)
	set(4, 5 + last, '  [' .. unicode.sub(filesystems[last][4], 1, 8) .. '] ' .. filesystems[last][3] .. filesystems[last][2])

	fill(50, 6, 24, 7, ' ')
	set(51, 6, 'Address: ' .. unicode.sub(filesystems[this][4], 1, 13))
	set(51, 7, 'Name: ' .. unicode.sub(filesystems[this][3], 1, 15))
	set(51, 8, 'Ready to boot: ' .. CheckDriveReadyToStart())
	set(51, 9, 'OS: ' .. filesystems[this][6])
	set(51, 10, 'Total space: ' .. tostring(filesystems[this][1].spaceTotal()))
	set(51, 11, 'Used space: ' .. tostring(filesystems[this][1].spaceUsed()))
	set(51, 12, 'Free space: ' .. tostring(filesystems[this][1].spaceTotal() - filesystems[this][1].spaceUsed()))
end

local function ServiceTheDeviceOtr(this, last)
	setForeground(C.dim)
	if last == 1 then
		if ServiceMenuStage[2][5] then
			if ServiceMenuStage[2][6] == 'MineOS' then
				set(4, 8, '  Try boot now (/OS.lua) (MineOS mode)    ')
			else
				set(4, 8, '  Try boot now (/init.lua) (OpenOS mode)  ')
			end
		else
			set(4, 8, '  Try boot now (not available)')
		end
	elseif last == 2 then
		if ServiceMenuStage[3][1] then
			set(4, 9, '  Try to modify the bootloader             ')
		else
			set(4, 9, '  Try to modify the bootloader [impossible]')
		end
	elseif last == 3 then
		if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
			set(4, 10, '  Make disk priority bootloader [is already]')
		else
			set(4, 10, '  Make disk priority bootloader [is not]    ')
		end
	elseif last == 4 then
		set(4, 11, '  Format disk')
	end

	setForeground(C.bright)
	if this == 1 then
		if ServiceMenuStage[2][5] then
			if ServiceMenuStage[2][6] == 'MineOS' then
				set(4, 8, '► Try boot now (/OS.lua) (MineOS mode)    ')
			else
				set(4, 8, '► Try boot now (/init.lua) (OpenOS mode)  ')
			end
		else
			set(4, 8, '► Try boot now (not available)')
		end
	elseif this == 2 then
		if ServiceMenuStage[3][1] then
			set(4, 9, '► Try to modify the bootloader             ')
		else
			set(4, 9, '► Try to modify the bootloader [impossible]')
		end
	elseif this == 3 then
		if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
			set(4, 10, '► Make disk priority bootloader [is already]')
		else
			set(4, 10, '► Make disk priority bootloader [is not]    ')
		end
	elseif this == 4 then
		set(4, 11, '► Format disk')
	end

	UI.DrawDescription(ServiceMenuPage, this)
end

local function FormatDevice(drive)
	for _, file in ipairs(drive.list('/')) do
		drive.remove(file)
	end
end

local function ServiceTheDeviceSetPriorityBootAddress(address)
	if address ~= Bios.GetPriorityBootAddress() then
		Bios.SetPriorityBootAddress(address)

		setForeground(C.bright)
		if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
			set(4, 10, '► Make disk priority bootloader [is already]')
		else
			set(4, 10, '► Make disk priority bootloader [is not]    ')
		end
	end
end

local function ServiceTheDevice()
	CurrentMenu = 'ServiceTheDevice'
	ServiceMenuStage = { 1 }

	setBackground(C.panel)
	setForeground(C.text)
	fill(50, 4, 24, 20, ' ')
	fill(2, 4, 47, 20, ' ')
	set(1, 5, '║')
	set(49, 5, '║')
	set(1, 6, '╟───────────────────────────────────────────────╢')

	ServiceMenuStage[2] = filesystems[BootMenuStage[1]]

	SetTextInTheMiddle(4, 49, 'Settings for the device: ')
	SetTextInTheMiddle(5, 49, ServiceMenuStage[2][4])

	set(50, 20, '↑↓    Select Item')
	set(50, 21, 'Enter Select Field')
	set(50, 22, 'Tab   exit to boot menu')

	setForeground(C.bright)
	if ServiceMenuStage[2][5] then
		if ServiceMenuStage[2][6] == 'MineOS' then
			set(4, 8, '► Try boot now (/OS.lua) (MineOS mode)  ')
		else
			set(4, 8, '► Try boot now (/init.lua) (OpenOS mode)  ')
		end
	else
		set(4, 8, '► Try boot now (not available)')
	end
	setForeground(C.dim)

	local modifyOpportunityAndIndexes = Modifier.GetModifierOpportunity()
	if modifyOpportunityAndIndexes then
		ServiceMenuStage[3] = { true, modifyOpportunityAndIndexes[1], modifyOpportunityAndIndexes[2] }
		set(4, 9, '  Try to modify the bootloader')
	else
		ServiceMenuStage[3] = { false }
		set(4, 9, '  Try to modify the bootloader [impossible]')
	end

	if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
		set(4, 10, '  Make disk priority bootloader [is already]')
	else
		set(4, 10, '  Make disk priority bootloader [is not]')
	end

	set(4, 11, '  Format disk')

	UI.DrawDescription(ServiceMenuPage, ServiceMenuStage[1])
end
------------------------------------------
local function POST()
	local sc, gpA, iA = cl('screen')(), cl('gpu')(), cl('internet')()
	if gpA and sc then
		pcall(invoke, gpA, 'bind', sc)
		gpu = cp(gpA)
	else
		safeBeep(20, 5)
		-- don't shutdown headless machines; just bail out
		return false
	end

	if iA then
		InternetInt = true
		internet = cp(iA)
	else
		safeBeep(2000, 2)
	end

	local eepromAddr = cl('eeprom')()
	if eepromAddr then
		local data = invoke(eepromAddr, 'getData')
		if data == '' then
			Bios.FormatData()
		end
	end

	return true
end

------------

local function BootAndRepairPageKeyListener(key)
	if key == 200 and BootMenuStage[1] > 1 then -- up
		local last = BootMenuStage[1]
		BootMenuStage[1] = BootMenuStage[1] - 1
		BootOtr(BootMenuStage[1], last)

	elseif key == 208 and BootMenuStage[1] < BootMenuStage[2] then -- down
		local last = BootMenuStage[1]
		BootMenuStage[1] = BootMenuStage[1] + 1
		BootOtr(BootMenuStage[1], last)

	elseif key == 63 then -- F5
		GetBootPage(true)

	elseif key == 28 then -- enter
		ServiceTheDevice()

	end
end

local function ServiceTheDevicePageKeyListener(key)
	if key == 28 then -- enter
		if ServiceMenuStage[1] == 1 then
			if ServiceMenuStage[2][5] then
				BootWithAddress(ServiceMenuStage[2][4])
			else
				safeBeep()
			end

		elseif ServiceMenuStage[1] == 2 then
			if ServiceMenuStage[3][1] then
				Modifier.TryModify()
				local modifyOpportunityAndIndexes = Modifier.GetModifierOpportunity()
				if modifyOpportunityAndIndexes then
					ServiceMenuStage[3] = { true, modifyOpportunityAndIndexes[1], modifyOpportunityAndIndexes[2] }
				else
					ServiceMenuStage[3] = { false }
				end

				ServiceTheDeviceOtr(ServiceMenuStage[1], ServiceMenuStage[1])
			end

		elseif ServiceMenuStage[1] == 3 then
			ServiceTheDeviceSetPriorityBootAddress(ServiceMenuStage[2][4])

		elseif ServiceMenuStage[1] == 4 then
			FormatDevice(ServiceMenuStage[2][1])

		end
	elseif key == 200 and ServiceMenuStage[1] > 1 then
		local last = ServiceMenuStage[1]
		ServiceMenuStage[1] = ServiceMenuStage[1] - 1
		ServiceTheDeviceOtr(ServiceMenuStage[1], last)

	elseif key == 208 and ServiceMenuStage[1] < 4 then
		local last = ServiceMenuStage[1]
		ServiceMenuStage[1] = ServiceMenuStage[1] + 1
		ServiceTheDeviceOtr(ServiceMenuStage[1], last)

	elseif key == 15 then -- tab
		GetBootPage(true)
	end
end

function BiosSetingsPage.FunctionStarter()
	local element = BiosSetingsPage.Element
	if element == 1 then

	elseif element == 2 then
		Bios.FormatData()

	elseif element == 3 then
		Debug.FormatData()

	elseif element == 4 then
		Debug.FormatBios()

	end
	BiosSetingsPage.Draw()
end

function BiosSetingsPage.KeyListener(key)
	if key == 28 then
		BiosSetingsPage.FunctionStarter()
	elseif key == 200 and BiosSetingsPage.Element > 1 then
		local last = BiosSetingsPage.Element
		BiosSetingsPage.Element = BiosSetingsPage.Element - 1
		BiosSetingsPage.OnChangeField(last)

	elseif key == 208 and BiosSetingsPage.Element < 4 then
		local last = BiosSetingsPage.Element
		BiosSetingsPage.Element = BiosSetingsPage.Element + 1
		BiosSetingsPage.OnChangeField(last)
	end
end

local function keyListener()
	while true do
		local e, _, _, key = computer.pullSignal(0.5)
		if e == 'key_up' then
			if key == 203 and CurrentMenu ~= 'SystemInformation' then -- left
				if CurrentMenu == 'BootAndRepair' then
					GetSystemInformationPage()
				elseif CurrentMenu == 'BiosSetings' then
					GetBootPage()
				end
			elseif key == 205 and CurrentMenu ~= 'BiosSetings' then -- right
				if CurrentMenu == 'SystemInformation' then
					GetBootPage()
				elseif CurrentMenu == 'BootAndRepair' then
					BiosSetingsPage.Draw()
				end
			elseif key == 67 then -- F9
				if CurrentMenu == 'BootAndRepair' or CurrentMenu == 'SystemInformation' or CurrentMenu == 'BiosSetings' then
					return
				end
			else
				if CurrentMenu == 'BootAndRepair' then
					BootAndRepairPageKeyListener(key)
				elseif CurrentMenu == 'ServiceTheDevice' then
					ServiceTheDevicePageKeyListener(key)
				elseif CurrentMenu == 'BiosSetings' then
					BiosSetingsPage.KeyListener(key)
				end
			end
		end
		if CurrentMenu == 'SystemInformation' then -- live refresh every 0.5s
			SystemInformationPageUpdate()
		end
	end
end

local function HiMenu()
	setResolution(50, 16)
	setBackground(0) -- black in case of boot after a BIOS error
	fillBackground()

	set(11, 1, 'Advanced BIOS by titan123023')
	set(7, 15, 'Press Alt to enter the settings menu')
	set(8, 16, 'Press any key to skip this message')

	local goToMenu
	while true do
		local e, _, _, k = computer.pullSignal(5)
		if e ~= nil then
			if e == 'key_down' then
				if k == 56 or k == 27 then -- Alt or Esc
					goToMenu = true
					break
				else
					break
				end
			end
		else
			break
		end
	end
	if goToMenu then
		got()
		GetSystemInformationPage()
		keyListener()
	end
	BootWithoutAddress()
	SetTextInTheMiddle(8, 50, 'No bootable device found!')

	while true do
		local e, _, _, k = computer.pullSignal(0.5)
		if e == 'key_down' and (k == 56 or k == 27) then
			break
		end
		safeBeep()
	end
	got()
	GetSystemInformationPage()
	keyListener()
end
------------

if POST() then
	HiMenu()
else
	-- No GPU/screen: try to boot from disk without graphics.
	BootWithoutAddress()
	while true do
		computer.pullSignal(5)
	end
end
