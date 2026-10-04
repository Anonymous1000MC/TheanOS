-- TheanOS EEPROM recovery
--
-- Paste this into any Lua environment on the machine that has an eeprom
-- component -- a computer case running this file, the Minecraft "Computer" item
-- in creative, or anything else that can call component.invoke on the eeprom.
--
-- It rewrites the EEPROM with the bootloader stub from disk, restores the boot
-- address, and then reads everything back and reports what it actually found.
-- It never assumes the write worked.
--
-- Why this exists: 1.7.0 shipped a "Flash BIOS" action that wrote the bootloader
-- but did not restore the boot address, and eeprom.set() clears it. The machine
-- then failed to boot with "expected string, got nil".

local STUB_PATH = "/EFI/Stub.lua"

local eepromAddress = component.list("eeprom")()

if not eepromAddress then
	print("No EEPROM on this computer.")
	return
end

local eeprom = component.proxy(eepromAddress)

-- Find the stub on any filesystem we can read.
local payload

for address in component.list("filesystem") do
	local proxy = component.proxy(address)

	if proxy and proxy.exists(STUB_PATH) then
		local handle = proxy.open(STUB_PATH, "rb")

		if handle then
			local data, chunk = "", nil

			repeat
				chunk = proxy.read(handle, math.huge)
				data = data .. (chunk or "")
			until not chunk

			proxy.close(handle)
			payload = data
		end
	end
end

if not payload or #payload == 0 then
	print("Could not read " .. STUB_PATH .. " from any filesystem.")
	print("If the disk is not readable, fetch EFI/Stub.lua and write it in directly:")
	print("  component.invoke(eepromAddress, \"set\", <contents of EFI/Stub.lua>)")
	return
end

print(("Stub found: %d bytes"):format(#payload))

-- Read the current state before touching anything.
local previousLabel = eeprom.getLabel()
local previousAddress = eeprom.getData()

print(("Current label:    %s"):format(tostring(previousLabel)))
print(("Current boot dev: %s"):format(tostring(previousAddress)))

local written = eeprom.set(payload)

if written == false then
	print("EEPROM cannot hold " .. #payload .. " bytes. Nothing was changed.")
	return
end

eeprom.setLabel(previousLabel or "TheanOS EFI")

-- setData must be a string. An empty string means "scan all disks on boot".
local bootAddress = previousAddress

if type(bootAddress) ~= "string" or bootAddress == "" then
	for address in component.list("filesystem") do
		bootAddress = address
		break
	end
end

if type(bootAddress) == "string" and bootAddress ~= "" then
	eeprom.setData(bootAddress)
end

-- Read everything back. Never report success on faith.
local stored = eeprom.get()
local storedLabel = eeprom.getLabel()
local storedData = eeprom.getData()

print("")
print("Verification")
print(("  bootloader stored : %s (%d bytes)"):format(type(stored), type(stored) == "string" and #stored or -1))
print(("  label stored      : %s"):format(type(storedLabel)))
print(("  boot address      : %s"):format(type(storedData)))

if type(stored) == "string" and #stored == #payload then
	print("")
	print("OK. The bootloader is in the EEPROM and readable. It is safe to reboot.")

	if type(storedData) ~= "string" then
		print("WARNING: the boot address is not a string. Set one before rebooting:")
		print("  component.invoke(eepromAddress, \"setData\", \"<filesystem address>\")")
	end
else
	print("")
	print("FAILED: the bootloader did not read back correctly. Do not reboot.")
	print("The EEPROM may be too small for " .. #payload .. " bytes.")
end