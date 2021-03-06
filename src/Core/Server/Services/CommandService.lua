-- LOCAL
local main = require(game.Nanoblox)
local System = main.modules.System
local CommandService = System.new("Commands")
CommandService.remotes = {
	clientCommandRequest = main.modules.Remote.new("clientCommandRequest")
}
local systemUser = CommandService.user
local defaultCommands = main.modules.Commands



-- BEGIN
function CommandService.begin()
	--!!
	local Parser = main.modules.Parser --!!! This is just to test the parser
	--!!

	-- Setup globals
	CommandService.executeBatchGloballySender = main.services.GlobalService.createSender("executeBatchGlobally")
	CommandService.executeBatchGloballyReceiver = main.services.GlobalService.createReceiver("executeBatchGlobally")
	CommandService.executeBatchGloballyReceiver.onGlobalEvent:Connect(function(caller, batch)
		CommandService.executeBatch(caller, batch)
	end)

	-- Grab default commands
	for name, details in pairs(defaultCommands) do
		CommandService.createCommand(name, details)
	end

	-- Setup auto sorters
	local records = CommandService.records
	records:setTable("dictionary", function()
		local dictionary = {}
		for _, record in pairs(records) do
			dictionary[record.name] = record
			for _, alias in pairs(record.aliases) do
				dictionary[alias] = record
			end
		end
		return dictionary
	end, true)
	records:setTable("sortedNameAndAliasLengthArray", function()
		local array = {}
		for itemNameOrAlias, record in pairs(records:getTable("dictionary")) do
			table.insert(array, itemNameOrAlias)
		end
		table.sort(array, function(a, b) return #a > #b end)
		return array
	end)
end



-- EVENTS
CommandService.recordAdded:Connect(function(commandName, record)
	--warn(("COMMAND '%s' ADDED!"):format(commandName))
end)

CommandService.recordRemoved:Connect(function(commandName)
	--warn(("COMMAND '%s' REMOVED!"):format(commandName))
end)

CommandService.recordChanged:Connect(function(commandName, propertyName, propertyValue, propertyOldValue)
	--warn(("BAN '%s' CHANGED %s to %s"):format(commandName, tostring(propertyName), tostring(propertyValue)))
end)



-- METHODS
function CommandService.generateRecord(key)
	return defaultCommands[key] or {
		name = "",
		description = "",
		contributors = {},
		aliases	= {},
		opposites = {}, -- the names to undo (revoke) the command, e.g. ;invisible would have 'visible'
		prefixes = {},
		tags = {},
		args = {},
		blockPeers = false,
		blockJuniors = false,
		autoPreview = false,
		requiresRig = nil,
		remoteNames = {},
		receiverNames = {},
		senderNames = {},
		invoke = function(this, caller, args)
			
		end,
		revoke = function(this, caller, args)
			
		end,
	}
end

function CommandService.createCommand(name, properties)
	local key = properties.UID
	if not key then
		key = name
		properties.UID = key
	end
	local record = CommandService:createRecord(key, false, properties)
	return record
end

function CommandService.getCommand(name)
	return CommandService:getRecord(name)
end

function CommandService.getCommands()
	return CommandService:getRecords()
end

function CommandService.updateCommand(name, propertiesToUpdate)
	CommandService:updateRecord(name, propertiesToUpdate)
	return true
end

function CommandService.removeCommand(name)
	CommandService:removeRecord(name)
	return true
end

function CommandService.getTable(name)
	return CommandService.records:getTable(name)
end 

function CommandService.chatCommand(caller, message)
	print(caller.name, "chatted: ", message)
	local batches = main.modules.Parser.parseMessage(message)
	if type(batches) == "table" then
		for i, batch in pairs(batches) do
			local approved, noticeDetails = CommandService.verifyBatch(caller, batch)
			if approved then
				CommandService.executeBatch(caller, batch)
			end
			for _, detail in pairs(noticeDetails) do
				local method = main.services.MessageService[detail[1]]
				method(caller.player, detail[2])
			end
		end
	end
end

function CommandService.verifyBatch(caller, batch)
	local approved = true
	local details = {}

	local jobId = batch.jobId
	local batchCommands = batch.commands
	local modifiers = batch.modifiers
	local qualifiers = batch.qualifiers
	
	-- Global
	if modifiers.global then
		table.insert(details, {"notice", {
			text = "Executing global command...",
			error = true,
		}})
	end

	-- !!! Error example
	table.insert(details, {"notice", {
		text = "You do not have permission to do that!",
		error = true,
	}})

	return approved, details
end

function CommandService.executeBatch(caller, batch)
	----
	batch.commands = batch.commands or {}
	batch.modifiers = batch.modifiers or {}
	batch.qualifiers = batch.qualifiers or {}
	----
	local Modifiers = main.modules.Modifiers
	for _, item in pairs(Modifiers.sortedOrderArrayWithOnlyPreAction) do
		local continueExecution = item.preAction(caller, batch)
		if not continueExecution then
			return
		end
	end
	local Args = main.modules.Args
	local Qualifiers = main.modules.Qualifiers
	local isPermModifier = batch.modifiers.perm
	local isGlobalModifier = batch.modifiers.wasGlobal
	for commandName, arguments in pairs(batch.commands) do
		local command = CommandService.getCommand(commandName)
		local isCorePlayerArg = Args.playerArgsWithoutHiddenDictionary[string.lower(command.args[1])]
		local TaskService = main.services.TaskService
		local properties = TaskService.generateRecord()
		properties.caller = batch.caller or properties.caller
		properties.commandName = commandName
		properties.args = arguments or properties.args
		-- Its important to split commands into specific users for most cases so that the command can
		-- be easily reapplied if the player rejoins (for ones where the perm modifier is present)
		-- The one exception for this is when a global modifier is present. In this scenerio, don't save
		-- specific targets, simply use the qualifiers instead to select a general audience relevant for
		-- the particular server at time of exection.
		-- e.g. ``;permLoopKillAll`` will save each specific target within that server and permanetly loop kill them
		-- while ``;globalLoopKillAll`` will permanently save the loop kill action and execute this within all
		-- servers repeatidly
		local addToPerm = false
		local splitIntoUsers = false
		if isPermModifier then
			if isGlobalModifier then
				addToPerm = true
			elseif isCorePlayerArg then
				addToPerm = true
				splitIntoUsers = true
			end
		else
			splitIntoUsers = isCorePlayerArg
		end
		if not splitIntoUsers then
			properties.qualifiers = batch.qualifiers or properties.qualifiers
			main.services.TaskService.createTask(addToPerm, properties)
		else
			local targets = Args.dictionary.player:parse(batch.qualifiers)
			for _, plr in pairs(targets) do
				properties.userId = plr.UserId
				main.services.TaskService.createTask(addToPerm, properties)
			end
		end
	end
end

function CommandService.invokeCommand(caller, commandName, ...)
	CommandService.executeBatch(caller, {
		commands = {
			--commandName = args -- !!! what about qualifiers?
		}
	})
end

function CommandService.revokeCommand(caller, commandName, qualifier)
	
end

--[[

local batch = {
	jobId = game.JobId;
	commands = {
		noobify = {"red"},
		goldify = {"red"},
	},
	modifiers = {
		global = {},
		random = {},
	},
	qualifiers = {
		random = {"ben", "matt", "sam"},
		me = true,
		nonadmins = true,
	},
}

]]



-- CLIENT
-- These are used within commands once they have been executed using ``this.client`` to activate client functions
local Client = {}

function Client.new(taskUID)
	local self = {}
	setmetatable(self, Client)
	self.taskUID = taskUID
end

local function makeRequestToClient(player, requestType, self, ...)
	local taskUID = self.UID
	self.remotes.clientCommandRequest:fireClient(player, requestType, taskUID, ...)
end

local function makeRequestToAllClients(self, requestType, ...)
	local taskUID = self.UID
	self.remotes.clientCommandRequest:fireAllClients(requestType, taskUID, ...)
end

local function makeRequestToNearbyClients(origin, radius, self, requestType, ...)
	local taskUID = self.UID
	self.remotes.clientCommandRequest:fireNearbyClients(origin, radius, requestType, taskUID, ...)
end

-- These activate ``clientCommand.invoke`` for the given players
function Client:invokeClient(player, ...)
	local requestType = "invoke"
	makeRequestToClient(player, requestType, self, ...)
end

function Client:invokeAllClients(...)
	local requestType = "invoke"
	makeRequestToAllClients(self, requestType, ...)
end

function Client:invokeNearbyClients(origin, radius, ...)
	local requestType = "invoke"
	makeRequestToNearbyClients(origin, radius, self, requestType, ...)
end

-- These activate ``clientCommand.revoke`` for the given players
function Client:revokeClient(player, ...)
	local requestType = "revoke"
	local target = "Client"
	makeRequestToClient(player, requestType, self, ...)
end

function Client:revokeAllClients(...)
	local requestType = "revoke"
	makeRequestToAllClients(self, requestType, ...)
end

function Client:revokeNearbyClients(origin, radius, ...)
	local requestType = "revoke"
	local target = "NearbyClients"
	makeRequestToNearbyClients(origin, radius, self, requestType, ...)
end

-- These activate ``clientCommand.replicate`` for the given players
function Client:replicateClient(player, ...)
	local requestType = "replicate"
	makeRequestToClient(player, requestType, self, ...)
end

function Client:replicateAllClients(...)
	local requestType = "replicate"
	makeRequestToAllClients(self, requestType, ...)
end

function Client:replicateNearbyClients(origin, radius, ...)
	local requestType = "replicate"
	makeRequestToNearbyClients(origin, radius, self, requestType, ...)
end



return CommandService