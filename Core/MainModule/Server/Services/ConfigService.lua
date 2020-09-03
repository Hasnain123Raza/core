-- This module acts as a gateway between studio (including the plugin,
-- trello, etc) and live servers. Config user.perm data will always reflect
-- the studio version of config (including bans, roles, etc). Every 10
-- seconds a new copy of the loader is retrieved. If differences are present
-- between the copy and previous version, then these changes are transormed
-- into the live server. This essentially enables changes from studio to be
-- synchronised almost instantly into all live servers.

-- LOCAL
local main = require(game.HDAdmin)
local System = main.modules.System
local NilledData = System.new("NilledData", true)
local nilledUser = NilledData.user
local ConfigService = {
	user = main.modules.SystemStore:createUser("Config"),
	nilledUser = nilledUser,
}
ConfigService.user.onlySaveDataWhenChanged = false
local Thread = main.modules.Thread
local TableUtil = main.modules.TableUtil
local DataUtil = main.modules.DataUtil



-- PRIVATE
local function isATable(value)
	return type(value) == "table"
end

local function updateSystems(func, callInstantly)
	local systems = main.modules.SystemStore:getAllUsers()
	for i, systemUser in pairs(systems) do
		if systemUser.key ~= "Config" and systemUser.key ~= "NilledData" then
			if not callInstantly then
				systemUser:waitUntilLoaded()
			end
			func(systemUser)
		end
	end
end

local function getServiceFromCategory(categoryName)
	local serviceName = categoryName:sub(1, #categoryName-1).."Service"
	local service = main.services[serviceName]
	return service
end



-- START
function ConfigService:start()
	
	-- Firstly, update display instantly with default config values
	local user = ConfigService.user
	local config = main.config
	updateSystems(function(systemUser)
		local categoryName = systemUser.key
		local configCategory = TableUtil.copy(config[categoryName] or {})
		print("TRANSFORM 1: ", categoryName)
		systemUser.recordsActionDelay = 0
		systemUser:transformData(configCategory, systemUser.temp)
		systemUser.recordsActionDelay = systemUser.originalRecordsActionDelay
		print("TRANSFORM 2: ", categoryName)
	end, true)

	-- Load user and check for recent config update directly from studio
	-- (i.e. this is the first server to receive the update)
	-- If present, force save these changes
	-- The HD Admin plugin automatically saves changes *within studio*
	-- therefore this is only here as backup (e.g. in case it's disabled)
	local latestConfig = ConfigService:getLatestConfig()
	if not TableUtil.doTablesMatch(config, latestConfig) then
		user.perm:set("ConfigData", TableUtil.copy(config))
		user:saveAsync()
	end
	
	-- This 'transforms' any data not registered within a Store Service
	-- (such as RoleService) into that service's user
	updateSystems(function(systemUser)
		local categoryName = systemUser.key
		local service = getServiceFromCategory(categoryName)
		if not service then return end
		local generateRecord = service and service.generateRecord
		local categoryTable = {}
		main.modules.TableModifiers.apply(categoryTable)
		local configCategory = TableUtil.copy(config[categoryName] or {})
		-- Transform config values into it, ignoring nilled values
		systemUser:transformData(configCategory, categoryTable, categoryTable, true)
		-- Then transform systemUser.perm, also ignoring nilled values
		systemUser:transformData(systemUser.perm, categoryTable, categoryTable, true)
		-- Finally, update the temp (server) container
		systemUser:transformData(categoryTable, systemUser.temp)
		-- Remove tm
		main.modules.TableModifiers.remove(categoryTable)
		
		-- Listen out for nilled data
		-- When category values are nilled (such as a role record), it's
		-- traditionally impossible to determine if that item has
		-- actually been removed due to the way data is loaded from
		-- config on join. This section here enables us to track nilled
		-- values and respond to them accoridngly
		systemUser.perm.changed:Connect(function(key, value, oldValue)
			if value == nil then
				-- Only class as nilled if value present within config
				if main.config[categoryName][key] ~= nil then
					-- Record value as nilled
					oldValue = oldValue or {}
					nilledUser.perm:pair(categoryName, key, oldValue)
				end
				
			elseif nilledUser.perm:find(categoryName, key) then
				-- Unnil value
				nilledUser.perm:pair(categoryName, key, nil)
				-- Sometimes an unnilled value is added after the temp
				-- record, therefore the temp record gets blocked.
				-- This checks to see if the temp record is present
				-- and adds it in if not
				if service.records[key] == nil then
					systemUser.temp:set(key, systemUser.temp[key])
				end
				
			end
		end)
		
		
	end)
	
	-- If a categories item has never been added before, however it exists
	-- by default within Config, then when it is removed on Server A ingame,
	-- server B will not detect this change. This therefore, fixes that issue,
	-- by listening out for specific changes within NilledData instead of
	-- the system's data
	local function pairNilUpdate(categoryName, key, isNilled)
		local service = getServiceFromCategory(categoryName)
		if not service then return end
		local systemUser = service.user
		if isNilled then
			Thread.wait(3)
			if service.records[key] ~= nil and systemUser.perm:get(key) == nil and DataUtil.isEqual(isNilled, nilledUser.perm:find(categoryName, key)) then
				systemUser.temp:set(key, nil)
			end
		end
		--]]
	end
	nilledUser.perm.paired:Connect(function(categoryName, key, isNilled)
		pairNilUpdate(categoryName, key, isNilled)
	end)
	nilledUser.perm.changed:Connect(function(categoryName, tab)
		if type(tab) == "table" then
			for key, isNilled in pairs(tab) do
				pairNilUpdate(categoryName, key, isNilled)
			end
		end
	end)
	
	
	-- This checks for differences between config and latestConfig and
	-- if present, applies them to the corresponding services
	main.config = config
	while true do
		latestConfig = ConfigService:getLatestConfig()
		ConfigService:transformChanges(latestConfig, main.config, "temp")
		Thread.wait(10)
	end
end



-- METHODS
function ConfigService:getLatestConfig()
	local user = ConfigService.user
	if user.isLoaded then
		user:loadAsync()
	else
		user:waitUntilLoaded()
	end
	return user.perm.ConfigData
end

function ConfigService:transformChanges(latestConfig, config, permOrTemp)
	local latestConfigCopy = TableUtil.copy(latestConfig)
	updateSystems(function(systemUser)
		local categoryName = systemUser.key
		local serviceName = categoryName:sub(1, #categoryName-1).."Service"
		local dataToUpdate = systemUser[permOrTemp]
		local category1 = latestConfig[categoryName]
		local category2 = config[categoryName]
		-- Transform
		systemUser:transformData(category1, category2, dataToUpdate)
	end)
	main.config = latestConfigCopy
end



ConfigService._order = 4
return ConfigService