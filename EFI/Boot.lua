-- TheanOS EFI firmware (classic BIOS, modernized UI)
-- Logic preserved exactly from your pasted version.
-- Visual direction: near-black/dark charcoal, warm off-white text,
-- hazard orange accents, acid green status indicators.

local cl = component.list
local cp = component.proxy
local invoke = component.invoke

local unicode = unicode or utf8 --lua 5.3 compatibility

local gpu, InternetInt, internet

local users
local filesystems

local CurrentMenu = {}
local BootMenuStage = {1}--1 - current str, 2 - max strs, 3 - label, 4 - address, 5 - ready?
local ServiceMenuStage
local BootPageFirstStart, SystemInformationPageFirstStart = true, true

local Bios = { StockSettings = {
	language = 'en'
}}

local Modifier = {}
local UI = {}

-- Modern palette
	local C = {
		bg     = 0x0A0C0E,   -- near-black
		panel  = 0x12161C,   -- dark charcoal
		border = 0x232A33,   -- muted charcoal border
		text   = 0xE8E4D8,   -- warm off-white
		dim    = 0x8A94A0,   -- muted grey-blue
		bright = 0xFFFFFF,
		accent = 0xE89C3D,   -- hazard orange
		ok     = 0x9BE860,   -- acid green
		bad    = 0xE05A5A,
	}

local BiosSetingsPage = {
	Element = 1, 
	Strings = {
		' Language: [en]',
		' Format EEPROM data',
		' Debug format EEPROM data',
		' Debug format EEPROM code'
	}, 
	Descriptions = {
		{'Changes the language',
		'of the BIOS.',
		'In order for',
		'the changes',
		'to take effect,',
		'you must restart',
		'the computer.',
		'[Not ready yet]'},
		{'deletes BIOS data',
		'(resets settings)'
		},
	}
}

local ServiceMenuPage = {
	Descriptions = {
		{'Try to boot from',
		'the disk.',
		'If you are using MineOS',
		'then apply',
		'the bootloader patch'},
		{'Applies the bootloader',
		'patch'},
		{},
		{'Deletes all data',
		'from disk'}
	}
}

local BiosVersion = '1.9.7'

local Debug = {}
------------------------------------------
computer.getBootAddress = function()
	local MemoryController = invoke(cl("eeprom")(), "getData")
	return string.sub(MemoryController,1,36)
end

computer.setBootAddress = function(address)
	if string.len(address) == 36 then
		local MemoryController = invoke(cl("eeprom")(), "getData")
		local newData = address..string.sub(MemoryController,37,string.len(MemoryController))
		return invoke(cl('eeprom')(), "setData", newData)
	end
end

function Bios.FormatData()
	invoke(cl('eeprom')(), "setData", '------------------------------------------------------------------------en')
end

function Bios.SetLanguage(key)
	local MemoryController = invoke(cl("eeprom")(), "getData")
	local newData = string.sub(MemoryController,1,72)..key..string.sub(MemoryController,75,string.len(MemoryController))
end

function Bios.GetLanguage()
	local MemoryController = invoke(cl("eeprom")(), "getData")
	return string.sub(MemoryController,73,74)
end

function Bios.GetPriorityBootAddress()
	local MemoryController = invoke(cl("eeprom")(), "getData")
	return string.sub(MemoryController,37,72)
end

function Bios.SetPriorityBootAddress(address)
	local MemoryController = invoke(cl("eeprom")(), "getData")
	local newData = string.sub(MemoryController,1,36)..address..string.sub(MemoryController,73,string.len(MemoryController))
	return invoke(cl('eeprom')(), "setData", newData)
end

------------------------------------------
function Modifier.GetModifierOpportunity()
	if ServiceMenuStage[2][6] == 'MineOS' then
		local address = ServiceMenuStage[2][4]
		local bootCode = ""

		local handle, err = invoke(address, "open", "/OS.lua")
		if handle then
			repeat
				local chunk = invoke(address, "read", handle, math.huge)
				bootCode = bootCode..(chunk or "")
			until not chunk
		end

		if bootCode then
			local indexs = {}
			if string.sub(bootCode,180,249) == 'component.proxy(component.proxy(component.list("eeprom")()).getData())' then
				indexs[1],indexs[2] = 179,250
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
	if ServiceMenuStage[2][6] == 'MineOS' then
		local address = ServiceMenuStage[2][4]
		local bootCode = ""

		local handle, err = invoke(address, "open", "/OS.lua")
		if handle then
			repeat
				local chunk = invoke(address, "read", handle, math.huge)
				bootCode = bootCode..(chunk or "")
			until not chunk
			invoke(address,'close',handle)
		end

		local newBootCode = string.sub(bootCode,1,ServiceMenuStage[3][2])..'component.proxy(component.proxy(component.list("eeprom")()).getData():sub(1,36))'..string.sub(bootCode,ServiceMenuStage[3][3],string.len(bootCode))

		local handle, err = invoke(address, "open", "/OS.lua",'w')
		if handle then
			invoke(address, 'write', handle, newBootCode)
			invoke(address,'close',handle)
		end
	end
end
------------------------------------------
function Debug.FormatData()
	invoke(cl('eeprom')(), "setData",'')
end

function Debug.FormatBios()
	invoke(cl('eeprom')(), "set",'')
end
------------------------------------------
local function setBackground(a)
	gpu.setBackground(a)
end

local function setForeground(a)
	gpu.setForeground(a)
end

local function fill(...)
	local args = {...}
	if type(args[5]) == 'number' and type(args[6]) == 'string' then
		setBackground(args[5])
		gpu.fill(args[1], args[2], args[3], args[4], args[6])
	else
		gpu.fill(...)
	end
end

local function set(...)
	local args = {...}
	if type(args[3]) == 'number' and type(args[4]) == 'string' then
		setForeground(args[3])
		gpu.set(args[1], args[2], args[4])
	else
		gpu.set(...)
	end
end

local function setResolution(...)
	gpu.setResolution(...)
end

local function fillBackground()
	local w,h = gpu.getResolution()
	gpu.fill(1,1,w,h,' ')
end

local function SetTextInTheMiddle(y,space,text,correct)
	if correct then
		set(space/2-unicode.len(text)/2+correct,y,text)
	else
		set(space/2-unicode.len(text)/2,y,text)
	end
end
------------------------------------------
local function BootWithAddress(address)
	computer.setBootAddress(address)
	local handle, err
	if ServiceMenuStage[2][6] == 'MineOS' then
		handle, err = invoke(address, "open", "/OS.lua")
	else
		handle, err = invoke(address, "open", "/init.lua")
	end
	if not handle then
		error(err)
	end
	local bootCode = ""
	repeat
		local chunk = invoke(address, "read", handle, math.huge)
		bootCode = bootCode..(chunk or "")
	until not chunk
	invoke(address,'close',handle)

	load(bootCode)()
end

local function BootWithoutAddress()
	local PriorityBootAddress = Bios.GetPriorityBootAddress()
	if PriorityBootAddress and component.proxy(PriorityBootAddress) and ((invoke(PriorityBootAddress,'exists','/init.lua') and not invoke(PriorityBootAddress, "isDirectory", "init.lua")) or (invoke(PriorityBootAddress,'exists','/OS.lua') and not invoke(PriorityBootAddress, "isDirectory", "OS.lua"))) then
		computer.setBootAddress(PriorityBootAddress)

		local handle, err
		if invoke(PriorityBootAddress,'exists','/OS.lua') and not invoke(PriorityBootAddress, "isDirectory", "OS.lua") then
			handle, err = invoke(PriorityBootAddress, "open", "/OS.lua")
		elseif invoke(PriorityBootAddress,'exists','/init.lua') and not invoke(PriorityBootAddress, "isDirectory", "init.lua") then
			handle, err = invoke(PriorityBootAddress, "open", "/init.lua")
		end

		if not handle then
			error(err)
		end
		local bootCode = ""
		repeat
			local chunk = invoke(PriorityBootAddress, "read", handle, math.huge)
			bootCode = bootCode..(chunk or "")
		until not chunk
		invoke(PriorityBootAddress,'close',handle)

		load(bootCode)()
	else
		for address in pairs(cl('filesystem')) do
			if cp(address).getLabel() ~= 'tmpfs' then
				if (invoke(address,'exists','/init.lua') and not invoke(address, "isDirectory", "init.lua")) or (invoke(address,'exists','/OS.lua') and not invoke(address, "isDirectory", "OS.lua")) then 
					computer.setBootAddress(address)

					local handle, err
					if invoke(address,'exists','/OS.lua') and not invoke(address, "isDirectory", "OS.lua") then
						handle, err = invoke(address, "open", "/OS.lua")
					elseif invoke(address,'exists','/init.lua') and not invoke(address, "isDirectory", "init.lua") then
						handle, err = invoke(address, "open", "/init.lua")
					end

					if handle then
						local bootCode = ""
						repeat
							local chunk = invoke(address, "read", handle, math.huge)
							bootCode = bootCode..(chunk or "")
						until not chunk
						invoke(address,'close',handle)

						load(bootCode)()
					end
				end
			end
		end
	end
end
------------------------------------------
local function getOS(address)
	if invoke(address,'exists','/OS.lua') and not invoke(address, "isDirectory", "/OS.lua") then
		return 'MineOS'
	elseif invoke(address,'exists','/init.lua') and not invoke(address, "isDirectory", "/init.lua") then
		local isOpenOS, path
		if invoke(address,'exists','/lib/tools/boot.lua') then
			isOpenOS = true
			path = '/lib/tools/boot.lua'
		elseif invoke(address,'exists','/lib/core/boot.lua') then
			isOpenOS = true
			path = '/lib/core/boot.lua'
		end
		local handle = invoke(address, "open", path)
		if not handle then
			return tostring('unknown')
		end
		local bootCode = ""
		repeat
			local chunk = invoke(address, "read", handle, math.huge)
			bootCode = bootCode..(chunk or "")
		until not chunk
		local _,strEnd = string.find(bootCode,'_G._OSVERSION = "')
		invoke(address,'close',handle)
		return string.sub(bootCode,strEnd+1,string.find(bootCode,'"',strEnd+1)-1)
	end
	return tostring('unknown')
end

local function SystemInformationPageUpdate()
	local totalMemory, freeMemory = computer.totalMemory(), computer.freeMemory()
	fill(6,7,41,3,' ')
	set(6,7,'Total memory: '..totalMemory)
	set(6,8,'Used memory: '..totalMemory-freeMemory)
	set(6,9,'Free memory: '..freeMemory)

	fill(6,13,41,4,' ')
	local uptime = computer.uptime()
	if uptime > 60 then
		uptime = tostring(math.modf(uptime/60*10)/10)..'m'
	else
		uptime = uptime..'s'
	end
	set(6,13,'Computer uptime: '..uptime)
	set(6,14,'Computer max energy: '..computer.maxEnergy())
	set(6,15,'Computer energy: '..math.modf(computer.energy()))
	set(6,16,'Boot priority address: '..unicode.sub(Bios.GetPriorityBootAddress(),1,18))
end
------------------------------------------

local function ClearLastPage()
	local lastBackground,lastForeground = gpu.getBackground(), gpu.getForeground()

	fill(50,4,24,20,C.panel)
	fill(2,4,47,20,C.panel)

	fill(1,4,1,20,C.border)
	fill(49,4,1,20,C.border)
	set(1,5,C.border,'╟───────────────────────────────────────────────╢')

	setBackground(C.panel)
	setForeground(C.text)
	set(3,2,'  System information  ')
	set(25,2,'  Boot or repair  ')
	set(43,2,'  Bios settings  ')

	setBackground(lastBackground)
	setForeground(lastForeground)
end

local function got()
	setResolution(74,25)
	setBackground(C.panel)
	setForeground(C.text)
	fill(1,1,74,25,C.bg)
	set(1,3,C.border,'╔')
	fill(2,3,72,1,C.border,'═')
	set(74,3,C.border,'╗')
	fill(1,4,1,20,C.border,'║')
	fill(74,4,1,20,C.border,'║')
	fill(2,24,72,1,C.border,'═')
	set(1,24,C.border,'╚')
	set(74,24,C.border,'╝')
	set(49,3,C.border,'╦')
	fill(49,4,1,20,C.border,'║')
	set(49,24,C.border,'╩')
	set(1,5,C.border,'╟───────────────────────────────────────────────╢')
	setBackground(C.accent)
	fill(1,1,74,1,C.bg)
	setForeground(C.text)
	set(23,1,'Advanced BIOS setup utility')
	setBackground(C.panel)
	fill(1,2,74,1,C.bg)
	setForeground(C.text)
	set(3,2,'  System information  ')
	set(25,2,'  Boot or repair  ')
	set(43,2,'  Bios settings  ')
	fill(1,25,74,1,C.bg)
	setForeground(C.dim)
	SetTextInTheMiddle(25,74,'v'..BiosVersion..' TheanOS EFI')
end

local function GetSystemInformationPage()
	CurrentMenu = 'SystemInformation'

	setBackground(C.panel)
	setForeground(C.text)
	ClearLastPage()
	set(3,2,'  System information  ')
	SetTextInTheMiddle(4,49,'Information about your system')

	set(50,21,C.dim,'←→    Select Screen')
	set(50,22,C.dim,'F9    Save and Exit')

	local totalMemory, freeMemory = computer.totalMemory(), computer.freeMemory()
	set(4,6,C.accent,'Memory information:')
	set(6,7,C.text,'Total memory: '..totalMemory)
	set(6,8,C.text,'Used memory: '..totalMemory-freeMemory)
	set(6,9,C.text,'Free memory: '..freeMemory)

	set(4,11,C.accent,'Computer information:')
	set(6,12,C.text,'Computer address: '..unicode.sub(computer.address(),1,8))
	set(6,13,C.text,'Computer uptime: '..computer.uptime())
	set(6,14,C.text,'Computer max energy: '..computer.maxEnergy())
	set(6,15,C.text,'Computer energy: '..math.modf(computer.energy()))
	set(6,16,C.text,'Boot priority address: '..unicode.sub(Bios.GetPriorityBootAddress(),1,18))
	set(6,17,C.text,'Last boot disc address: '..unicode.sub(computer.getBootAddress(),1,18))
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
	set(25,2,'  Boot or repair  ')
	SetTextInTheMiddle(4,49,'Select device to boot or repair it')

	set(50,18,C.dim,'←→    Select Screen')
	set(50,19,C.dim,'↑↓    Select Item')
	set(50,20,C.dim,'Enter Select Field')
	set(50,21,C.dim,'F5    Update device list')
	set(50,22,C.dim,'F9    Save and Exit')

	if BootPageFirstStart or update then
		filesystems = {}
		for address in pairs(cl('filesystem')) do
			local b = cp(address)
			local label = b.getLabel()
			if label ~= 'tmpfs' then
				local ready, d
				if (invoke(address,'exists','/init.lua') and not invoke(address, "isDirectory", "/init.lua")) or (invoke(address,'exists','/OS.lua') and not invoke(address, "isDirectory", "/OS.lua")) then 
					d=' [Ready to boot]'
					ready = true
				else 
					d=' [Not ready to boot]'
					ready = false
				end

				label = label or 'unknown'
				if string.len(label) > 11 then
					label = unicode.sub(label,1,8)..'...'
				end

				table.insert(filesystems,{b,d,label,address,ready,getOS(address)})
			end
		end
		BootPageFirstStart = false
	end

	for i=1,#filesystems do
		if i==BootMenuStage[1] then 
			setForeground(C.bright) 
			set(4,5+i,'► ['..unicode.sub(filesystems[i][4],1,8)..'] '..filesystems[i][3]..filesystems[i][2])
			setForeground(C.text)
		else
			set(4,5+i,'  ['..unicode.sub(filesystems[i][4],1,8)..'] '..filesystems[i][3]..filesystems[i][2])
		end
	end
	BootMenuStage[2] = #filesystems

	if BootMenuStage[2] ~= 0 then
		set(51,4,C.dim,'Regular hard drive...')
		set(51,6,C.text,'Address: '..unicode.sub(filesystems[BootMenuStage[1]][4],1,13))
		set(51,7,C.text,'Name: '..unicode.sub(filesystems[BootMenuStage[1]][3],1,15))
		set(51,8,C.text,'Ready to boot: '..CheckDriveReadyToStart())
		set(51,9,C.text,'OS: '..filesystems[BootMenuStage[1]][6])
		set(51,10,C.text,'Total space: '..filesystems[BootMenuStage[1]][1].spaceTotal())
		set(51,11,C.text,'Used space: '..filesystems[BootMenuStage[1]][1].spaceUsed())
		set(51,12,C.text,'Free space: '..filesystems[BootMenuStage[1]][1].spaceTotal()-filesystems[BootMenuStage[1]][1].spaceUsed())
	end
end

function UI.DrawDescription(Table,element)
	setForeground(C.dim)

	fill(50,4,24,15,C.panel)
	if Table.Descriptions[element] then
		local description = Table.Descriptions[element]
		for i=1,#description do
			SetTextInTheMiddle(3+i,24,description[i],50)
		end
	end
end

function BiosSetingsPage.OnChangeField(last)
	setForeground(C.dim)
	set(4,6+last,' '..BiosSetingsPage.Strings[last])

	setForeground(C.bright)
	set(4,6+BiosSetingsPage.Element,'►'..BiosSetingsPage.Strings[BiosSetingsPage.Element])

	UI.DrawDescription(BiosSetingsPage,BiosSetingsPage.Element)
end

function BiosSetingsPage.Draw()
	CurrentMenu = 'BiosSetings'

	setBackground(C.panel)
	setForeground(C.text)
	ClearLastPage()
	set(43,2,'  Bios settings  ')
	SetTextInTheMiddle(4,49,'BIOS setup')

	set(50,19,C.dim,'←→    Select Screen')
	set(50,20,C.dim,'↑↓    Select Item')
	set(50,21,C.dim,'Enter Select Field')
	set(50,22,C.dim,'F9    Save and Exit')

	UI.DrawDescription(BiosSetingsPage,BiosSetingsPage.Element)

	setForeground(C.dim)
	set(4,7,' '..BiosSetingsPage.Strings[1])
	set(4,8,' '..BiosSetingsPage.Strings[2])
	set(4,9,' '..BiosSetingsPage.Strings[3])
	set(4,10,' '..BiosSetingsPage.Strings[4])

	setForeground(C.bright)
	set(4,6+BiosSetingsPage.Element,'►'..BiosSetingsPage.Strings[BiosSetingsPage.Element])
end

local function BootOtr(this,last)
	if this==last then return end

	setForeground(C.bright)
	set(4,5+this,'► ['..unicode.sub(filesystems[this][4],1,8)..'] '..filesystems[this][3]..filesystems[this][2])

	setForeground(C.text)
	set(4,5+last,'  ['..unicode.sub(filesystems[last][4],1,8)..'] '..filesystems[last][3]..filesystems[last][2])

	fill(50,6,24,7,C.panel)
	set(51,6,C.text,'Address: '..unicode.sub(filesystems[this][4],1,13))
	set(51,7,C.text,'Name: '..unicode.sub(filesystems[this][3],1,15))
	set(51,8,C.text,'Ready to boot: '..CheckDriveReadyToStart())
	set(51,9,C.text,'OS: '..filesystems[this][6])
	set(51,10,C.text,'Total space: '..filesystems[this][1].spaceTotal())
	set(51,11,C.text,'Used space: '..filesystems[this][1].spaceUsed())
	set(51,12,C.text,'Free space: '..filesystems[this][1].spaceTotal()-filesystems[this][1].spaceUsed())
end

local function ServiceTheDeviceOtr(this,last)
	setForeground(C.dim)
	if last == 1 then
		if ServiceMenuStage[2][5] then
			if ServiceMenuStage[2][6] == 'MineOS' then
				set(4,8,'  Try boot now (/OS.lua) (MineOS mode)    ')
			else
				set(4,8,'  Try boot now (/init.lua) (OpenOS mode)  ')
			end
		else
			set(4,8,'  Try boot now (not available)')
		end
	elseif last == 2 then
		if ServiceMenuStage[3][1] then
			set(4,9,'  Try to modify the bootloader             ')
		else
			set(4,9,'  Try to modify the bootloader [impossible]')
		end
	elseif last == 3 then
		if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
			set(4,10,'  Make disk priority bootloader [is already]')
		else
			set(4,10,'  Make disk priority bootloader [is not]    ')
		end
	elseif last == 4 then
		set(4,11,'  Format disk')
	end

	setForeground(C.bright)
	if this == 1 then
		if ServiceMenuStage[2][5] then
			if ServiceMenuStage[2][6] == 'MineOS' then
				set(4,8,'► Try boot now (/OS.lua) (MineOS mode)    ')
			else
				set(4,8,'► Try boot now (/init.lua) (OpenOS mode)  ')
			end
		else
			set(4,8,'► Try boot now (not available)')
		end
	elseif this == 2 then
		if ServiceMenuStage[3][1] then
			set(4,9,'► Try to modify the bootloader             ')
		else
			set(4,9,'► Try to modify the bootloader [impossible]')
		end
	elseif this == 3 then
		if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
			set(4,10,'► Make disk priority bootloader [is already]')
		else
			set(4,10,'► Make disk priority bootloader [is not]    ')
		end
	elseif this == 4 then
		set(4,11,'► Format disk')
	end

	UI.DrawDescription(ServiceMenuPage,this)
end

local function FormatDevice(drive)
	for _, file in ipairs(drive.list("/")) do
		drive.remove(file)
	end
end

local function ServiceTheDeviceSetPriorityBootAddress(address)
	if address ~= Bios.GetPriorityBootAddress() then
		Bios.SetPriorityBootAddress(address)

		setForeground(C.bright)
		if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
			set(4,10,'► Make disk priority bootloader [is already]')
		else
			set(4,10,'► Make disk priority bootloader [is not]    ')
		end
	end
end

local function ServiceTheDevice()
	CurrentMenu = 'ServiceTheDevice'
	ServiceMenuStage = {1} 

	setBackground(C.panel)
	setForeground(C.text)
	fill(50,4,24,20,C.panel)
	fill(2,4,47,20,C.panel)
	set(1,5,C.border,'║')
	set(49,5,C.border,'║')
	set(1,6,C.border,'╟───────────────────────────────────────────────╢')

	ServiceMenuStage[2] = filesystems[BootMenuStage[1]]

	SetTextInTheMiddle(4,49,'Settings for the device: ')
	SetTextInTheMiddle(5,49,ServiceMenuStage[2][4])

	set(50,20,C.dim,'↑↓    Select Item')
	set(50,21,C.dim,'Enter Select Field')
	set(50,22,C.dim,'Tab   exit to boot menu')

	setForeground(C.bright)
	if ServiceMenuStage[2][5] then
		if ServiceMenuStage[2][6] == 'MineOS' then
			set(4,8,'► Try boot now (/OS.lua) (MineOS mode)  ')
		else
			set(4,8,'► Try boot now (/init.lua) (OpenOS mode)  ')
		end
	else
		set(4,8,'► Try boot now (not available)')
	end
	setForeground(C.dim)

	local modifyOpportunityAndIndexes = Modifier.GetModifierOpportunity()
	if modifyOpportunityAndIndexes then
		ServiceMenuStage[3] = {true,modifyOpportunityAndIndexes[1],modifyOpportunityAndIndexes[2]}
		set(4,9,'  Try to modify the bootloader')
	else
		ServiceMenuStage[3] = {false}
		set(4,9,'  Try to modify the bootloader [impossible]')
	end

	if Bios.GetPriorityBootAddress() == ServiceMenuStage[2][4] then
		set(4,10,'  Make disk priority bootloader [is already]')
	else
		set(4,10,'  Make disk priority bootloader [is not]')
	end

	set(4,11,'  Format disk')

	UI.DrawDescription(ServiceMenuPage,ServiceMenuStage[1])
end
------------------------------------------
local function POST()
	local sc,gpA,iA = cl('screen')(),cl('gpu')(),cl('internet')()
	if gpA and sc then 
		pcall(invoke, gpA, 'bind', sc)
		gpu=cp(gpA)
	else 
		computer.beep(20,5) 
		computer.shutdown()  
	end

	if iA then 
		InternetInt = true 
		internet=cp(iA) 
	else
		computer.beep(2000,2)
	end

	if invoke(cl("eeprom")(), "getData") == '' then
		Bios.FormatData()
	end

end

------------

local function BootAndRepairPageKeyListener(key)
	if key==200 and BootMenuStage[1] > 1 then --2
		local last = BootMenuStage[1]
		BootMenuStage[1] = BootMenuStage[1]-1
		BootOtr(BootMenuStage[1],last)

	elseif key==208 and BootMenuStage[1] < BootMenuStage[2] then --8
		local last = BootMenuStage[1]
		BootMenuStage[1] = BootMenuStage[1]+1
		BootOtr(BootMenuStage[1],last)

	elseif key==63 then --F5
		GetBootPage(true)

	elseif key==28 then --enter
		ServiceTheDevice()

	end
end

local function ServiceTheDevicePageKeyListener(key)
	if key==28 then --enter
		if ServiceMenuStage[1] == 1 then
			if ServiceMenuStage[2][5] then
				BootWithAddress(ServiceMenuStage[2][4])
			else
				computer.beep()
			end

		elseif ServiceMenuStage[1] == 2 then
			if ServiceMenuStage[3][1] then
				Modifier.TryModify()
				local modifyOpportunityAndIndexes = Modifier.GetModifierOpportunity()
				if modifyOpportunityAndIndexes then
					ServiceMenuStage[3] = {true,modifyOpportunityAndIndexes[1],modifyOpportunityAndIndexes[2]}
				else
					ServiceMenuStage[3] = {false}
				end

				ServiceTheDeviceOtr(ServiceMenuStage[1],ServiceMenuStage[1])
			end

		elseif ServiceMenuStage[1] == 3 then
			ServiceTheDeviceSetPriorityBootAddress(ServiceMenuStage[2][4])

		elseif ServiceMenuStage[1] == 4 then
			FormatDevice(ServiceMenuStage[2][1])

		end
	elseif key == 200 and ServiceMenuStage[1] > 1 then
		local last = ServiceMenuStage[1]
		ServiceMenuStage[1] = ServiceMenuStage[1]-1
		ServiceTheDeviceOtr(ServiceMenuStage[1], last)

	elseif key == 208 and ServiceMenuStage[1] < 4 then
		local last = ServiceMenuStage[1]
		ServiceMenuStage[1] = ServiceMenuStage[1]+1
		ServiceTheDeviceOtr(ServiceMenuStage[1], last)

	elseif key == 15 then --tab
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
	if key==28 then
		BiosSetingsPage.FunctionStarter()
	elseif key == 200 and BiosSetingsPage.Element > 1 then
		local last = BiosSetingsPage.Element
		BiosSetingsPage.Element = BiosSetingsPage.Element-1
		BiosSetingsPage.OnChangeField(last)

	elseif key == 208 and BiosSetingsPage.Element < 4 then
		local last = BiosSetingsPage.Element
		BiosSetingsPage.Element = BiosSetingsPage.Element+1
		BiosSetingsPage.OnChangeField(last)
	end
end

local function keyListener()
	while true do
		local e,_,_,key = computer.pullSignal(0.5)
		if e=='key_up'then
			if key==203 and CurrentMenu ~= 'SystemInformation' then --4
				if CurrentMenu == 'BootAndRepair' then
					GetSystemInformationPage()
				elseif CurrentMenu == 'BiosSetings' then
					GetBootPage()
				end
			elseif key==205 and CurrentMenu ~= 'BiosSetings' then --6
				if CurrentMenu == 'SystemInformation' then
					GetBootPage()
				elseif CurrentMenu == 'BootAndRepair' then
					BiosSetingsPage.Draw()
				end
			elseif key==67 then --F9
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
		if CurrentMenu == 'SystemInformation' then --обновление инфы каждый проход цикла (0.5сек)
			SystemInformationPageUpdate()
		end
	end
end

local function HiMenu()
	setResolution(50,16)
	setBackground(0)
	fillBackground()

	set(11,1,C.accent,'Advanced BIOS by titan123023')
	set(7,15,C.text,'Press F12 to enter the settings menu')
	set(8,16,C.dim,'Press any key to skip this message')

	local goToMenu
	while true do
		local e,_,_,k = computer.pullSignal(5)
		if e ~= nil then
			if e=='key_up' then
				if k==88 then
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
	SetTextInTheMiddle(8,50,C.bad,'No bootable device found!')

	while true do
		local e,_,_,k = computer.pullSignal(0.5)
		if e=='key_up' and k==88 then
			break
		end
		computer.beep()
	end
	got()
	GetSystemInformationPage()
	keyListener()
end
------------

POST()
HiMenu()
