--
-- GuildTaxes - keep your guild bank full
--

-- Addon settings
local VERSION = "0.3.0"
local DEVELOPMENT = false
local SLASH_COMMAND = "gt"
local MESSAGE_PREFIX = "GT"
local REFRESH_ALL_PERIOD = 1 * 60
local REFRESH_PLAYER_STATUS_PERIOD = 3 * 60 * 60
local PURGE_DATA_PERIOD = 3 * 60
local QUEUE_ITERATION = 15

local DEFAULTS = {
	realm = {
		history = {},
		status = {}
	},
	profile = {
		version = 0,
		debug = false,
		verbose = false,
		logging = false,
		autopay = true,
		direct = true,
		showTaxFrame = true,
	},
	char = {
		rate = 0.10,
	},
}


--------------------------------------------------------------------------------
-- WoW: Forever compatibility (Interface 16001, modern Midnight UI and API).
-- Several old globals are gone there, so everything below goes through local
-- wrappers that use the modern API and fall back to the old one.
-- No globals are created or overwritten.
--------------------------------------------------------------------------------
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

local function RequestGuildRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

local function GetGuildBankMoney()
	if _G.GetGuildBankMoney then
		return _G.GetGuildBankMoney() or 0
	end
	return 0
end

local function DepositGuildBankMoney(amount)
	if _G.DepositGuildBankMoney then
		_G.DepositGuildBankMoney(amount)
	end
end

local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString

-- Midnight: unknown events raise an error when registered, so check them first
local function IsEventValid(event)
	if C_EventUtils and C_EventUtils.IsEventValid then
		return C_EventUtils.IsEventValid(event)
	end
	return true
end

-- Midnight: addon messages are blocked in some instance situations (encounters, M+)
local function InChatMessagingLockdown()
	return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false
end

-- Midnight: some values (chat, units) can be "secret" and must not be compared
local function IsSecret(...)
	if hasanysecretvalues then
		return hasanysecretvalues(...)
	end
	return false
end

-- Guild bank / mailbox open and close come through the player interaction
-- manager on the modern client; GUILDBANKFRAME_OPENED/CLOSED no longer exist.
local INTERACTION_GUILD_BANKER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
local INTERACTION_MAIL = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo

-- Instantiate
GuildTaxes = LibStub("AceAddon-3.0"):NewAddon("GuildTaxes", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceHook-3.0")

getmetatable(GuildTaxes).__tostring = function (self)
	return GT_CHAT_PREFIX
end


--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------
function GuildTaxes:OnInitialize()
	-- User's settings
	self.db = LibStub("AceDB-3.0"):New("GuildTaxesDB", DEFAULTS, true)

	-- Local state vars
	self.playerName = nil
	self.playerRealm = nil
	self.playerFullName = nil
	self.playerMoney = 0
	self.guildId = nil
	self.guildName = nil
	self.guildRealm = nil
	self.numberMembers = nil
	self.numberMembersOnline = nil
	self.isMailOpened = false
	self.isBankOpened = false
	self.guildBankMoney = 0
	self.bankDataReady = false
	self.isPayingTax = false
	self.isReady = false
	self.outgoingQueue = {}
	self.nextSyncTimestamp = time()
	self.nextPurgeTimestamp = time()
end


--------------------------------------------------------------------------------
-- Utilites
--------------------------------------------------------------------------------
function GuildTaxes:HistoryKey(year, month)
	if string.len(tostring(month)) == 1 then
		return year .. "-0" .. month
	else
		return year .. "-" .. month
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:Debug(message, n)
	if (DEVELOPMENT or self.db.profile.debug) then
		self:Print("|cff999999" .. message .. "|r")
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:FormatMoney(amount, color)
	if amount < 0 then
		return "-" .. GetCoinTextureString(-amount)
	else
		return GetCoinTextureString(amount)
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:PrintGeneralInfo()
	self:Printf(GT_CHAT_GENERAL_INFO, 100 * self.db.char.rate, self.guildName)
end

--------------------------------------------------------------------------------
function GuildTaxes:PrintTax()
	local tax = floor(self:GetTax())
	local message
	if tax >= 1 then
		message = format(GT_CHAT_TAX, self:FormatMoney(tax))
		if (self.isBankOpened and not self.db.profile.autopay) then
			-- "addon:" links are the modern client's link type for addons;
			-- clicks arrive through EventRegistry "SetItemRef"
			message = message .. " |Haddon:GuildTaxes:pay|h|cffff8000[" .. GT_CHAT_TAX_CLICK .. "]|r|h"
		end
	else
		message = GT_CHAT_ALL_PAYED
	end
	self:Print(message)
end

--------------------------------------------------------------------------------
function GuildTaxes:PrintTransaction(income, tax)
	if self.db.profile.logging then
		self:Printf(GT_CHAT_TRANSACTION, self:FormatMoney(income), self:FormatMoney(tax))
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:PrintPayingTax(tax)
	self:Printf(GT_CHAT_PAYING_TAX, self:FormatMoney(tax))
end

--------------------------------------------------------------------------------
function GuildTaxes:PrintNothingToPay()
	self:Print(GT_CHAT_NOTHING_TO_PAY)
end

--------------------------------------------------------------------------------
function GuildTaxes:PrintNotReady()
	GuildTaxes:Print(GT_CHAT_NOT_READY)
end

--------------------------------------------------------------------------------
function GuildTaxes:GetTax()
	local charDB = self.db.char[self.guildId]
	if charDB then
		return charDB.tax or 0
	end
	return 0
end

--------------------------------------------------------------------------------
function GuildTaxes:GetRate()
	return GuildTaxes.db.char.rate
end

--------------------------------------------------------------------------------
function GuildTaxes:GetGuildDB()
	local guildDB = self.db.realm[self.guildId]
	if not guildDB then
		guildDB = {
			["history"] = {},
			["status"] = {}
		}
		self.db.realm[self.guildId] = guildDB
	end
	return guildDB
end

--------------------------------------------------------------------------------
function GuildTaxes:GetStatusDB()
	local guildDB = self:GetGuildDB()
	if guildDB.status == nil then
		guildDB.status = {}
	end
	return guildDB.status
end

--------------------------------------------------------------------------------
function GuildTaxes:GetHistoryDB()
	local guildDB = self:GetGuildDB()
	if guildDB.history == nil then
		guildDB.history = {}
	end
	return guildDB.history
end

--------------------------------------------------------------------------------
function GuildTaxes:GetPlayerStatusDB(playerName, create)
	local statusDB = self:GetStatusDB()
	local playerStatus = statusDB[playerName]
	if playerStatus == nil and create == true then
		playerStatus = {}
		statusDB[playerName] = playerStatus
	end
	return playerStatus
end

--------------------------------------------------------------------------------
function GuildTaxes:GetPlayerHistoryDB(playerName, create)
	local historyDB = self:GetHistoryDB()
	local playerHistory = historyDB[playerName]
	if playerHistory == nil and create == true then
		playerHistory = {}
		historyDB[playerName] = playerHistory
	end
	return playerHistory
end

--------------------------------------------------------------------------------
function GuildTaxes:GetStatus(playerName)
	local statusDB = self:GetStatusDB()
	local historyDB = self:GetHistoryDB()

	local status = {}

	if playerName == GuildTaxes.playerName then
		status.version = GetAddOnMetadata("GuildTaxes", "Version")
		status.timestamp = time()
		status.rate = GuildTaxes:GetRate()
		status.tax = GuildTaxes:GetTax()
		status.updated = time()
	else
		local playerStatus = statusDB[playerName]
		if not playerStatus then
			statusDB[playerName] = {}
			return
		end
		status.version = playerStatus.version
		status.timestamp = playerStatus.timestamp
		status.rate = playerStatus.rate
		status.tax = playerStatus.tax
		status.updated = playerStatus.updated
	end

	local playerHistory = historyDB[playerName]
	if not playerHistory then
		playerHistory = {}
	end

	status.history= {}

	local month = tonumber(date("%m"))
	local year = tonumber(date("%Y"))
	for i=1, 3 do
		local key = GuildTaxes:HistoryKey(year, month)
		local value = playerHistory[key]
		if value == nil then
			value = 0
		end
		status.history[key] = value
		month = month - 1
		if month == 0 then
			month = 12
			year = year - 1
		end
	end

	local total = playerHistory["total"]
	if total == nil then
		total = 0
	end
	status.total = total

	return status
end

--------------------------------------------------------------------------------
function GuildTaxes:MigrateDatabase()
	-- Old GuildId
	local oldGuildId = format("%s-%s", self.guildName, self.guildRealm):lower()
	if self.db.char[oldGuildId] then
		self.db.char[self.guildId] = self.db.char[oldGuildId]
		self.db.char[oldGuildId] = nil
	end

	-- Create new char db
	if not self.db.char[self.guildId] then
		self.db.char[self.guildId] = {
			tax = 0;
		}
	end

	-- Migrate amount -> tax
	if self.db.char[self.guildId].amount ~= nil then
		self.db.char[self.guildId].tax = self.db.char[self.guildId].amount
		self.db.char[self.guildId].amount = nil
	end

	-- Create realm data
	if not self.db.realm then
		self.db.realm = {}
	end
	if not self.db.realm[self.guildId] then
		self.db.realm[self.guildId] = {}
	end

	-- Migrate history & status database
	if self.db.char[self.guildId].status ~= nil then
		for i, v in ipairs(self.db.char[self.guildId].status) do
			self.db.realm[self.guildId].status[i] = v
		end
		self.db.char[self.guildId].status = nil
	end
	if self.db.char[self.guildId].history ~= nil then
		for i, v in ipairs(self.db.char[self.guildId].history) do
			self.db.realm[self.guildId].history[i] = v
		end
		self.db.char[self.guildId].history = nil
	end

	-- Add direct pay settins
	if self.db.profile.direct == nil then
		self.db.profile.direct = true
	end

	-- Data saved under the first name only (before surnames were handled)
	if self.playerName then
		self:MigrateShortName(self.playerName)
	end
end

--------------------------------------------------------------------------------
-- Move status/history saved under "Name" to the roster name "Name Surname".
function GuildTaxes:MigrateShortName(fullName)
	if type(fullName) ~= "string" then return end
	local shortName = fullName:match("^(%S+) ")
	if not shortName then return end

	local statusDB = self:GetStatusDB()
	local old = statusDB[shortName]
	if old then
		local new = statusDB[fullName]
		if not new then
			statusDB[fullName] = old
		elseif old.timestamp and (not new.timestamp or old.timestamp > new.timestamp) then
			new.timestamp = old.timestamp
			new.version = old.version
			new.rate = old.rate
			new.tax = old.tax
			new.updated = old.updated
		end
		statusDB[shortName] = nil
	end

	local historyDB = self:GetHistoryDB()
	local oldHistory = historyDB[shortName]
	if oldHistory then
		local newHistory = historyDB[fullName]
		if not newHistory then
			historyDB[fullName] = oldHistory
		else
			for key, value in pairs(oldHistory) do
				newHistory[key] = math.max(newHistory[key] or 0, value or 0)
			end
		end
		historyDB[shortName] = nil
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:UpdatePlayerName()
	-- WoW: Forever: characters have a surname, and the guild roster lists them
	-- as "Name Surname". UnitName("player") alone returns just "Name".
	local name, surname = (UnitNameUnmodified or UnitName)("player")
	if surname and surname ~= "" and not IsSecret(surname) and not name:find(" ", 1, true) then
		name = name .. " " .. surname
	end
	self.playerName = name
	self.playerRealm = GetRealmName()
	self.playerFullName = self.playerName .. "-" .. self.playerRealm
end

--------------------------------------------------------------------------------
function GuildTaxes:UpdatePlayerMoney(playerMoney)
	if not playerMoney then
		playerMoney = GetMoney()
	end
	self.playerMoney = playerMoney
end

--------------------------------------------------------------------------------
function GuildTaxes:UpdateGuildInfo()
	self:Debug("Updating guild info")
	if IsInGuild() then
		if not self.guildId then
			self.guildName, self.guildRealm = GetGuildInfo("player"), GetRealmName()
			if self.guildName and self.guildRealm then
				self.guildId = format("%s - %s", self.guildName, self.guildRealm)
				self:Debug("Guild ID set: " .. self.guildId)
			else
				self:Debug("Guild info unavailable: guildName=" .. tostring(self.guildName) .. " guildRealm=" .. tostring(self.guildRealm))
			end
		end
		if self.guildId then
			self:MigrateDatabase()
			self.GUI:UpdatePayedStatus()
		end
	else
		self:Debug("Not in a guild")
		self.guildId = nil
		self.isReady = false
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:Ready()
	self:Debug("Ready() called: isReady=" .. tostring(self.isReady)
		.. " guildId=" .. tostring(self.guildId)
		.. " isBankOpened=" .. tostring(self.isBankOpened)
		.. " bankDataReady=" .. tostring(self.bankDataReady)
		.. " isPayingTax=" .. tostring(self.isPayingTax))
	if not self.isReady then
		-- Only guildId is required; numberMembers is for the GUI roster and
		-- loads asynchronously, but autopay/deposit tracking don't need it.
		if self.guildId and self.playerName then
			self.isReady = true
			self:Debug("Addon is now ready")
			self:PrintGeneralInfo()
			self:NotifyStatus(self.playerName)
			self.GUI:UpdatePayedStatus()
			-- If bank is already open and data is loaded, trigger autopay now
			if self.isBankOpened and self.bankDataReady and not self.isPayingTax then
				local tax = floor(self:GetTax())
				self:Debug("Ready() bank already open — tax=" .. tostring(tax) .. " autopay=" .. tostring(self.db.profile.autopay))
				if tax >= 1 and self.db.profile.autopay then
					self:PayTax()
				else
					self:PrintTax()
				end
			end
		else
			self:Debug("Ready() cannot proceed: guildId is nil")
		end
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:AccrueTax(income, tax)
	self:Debug("Accrue tax with " .. tax)
	self.db.char[self.guildId].tax = self:GetTax() + tax
	self:PrintTransaction(income, tax)
	self.GUI:UpdatePayedStatus()
end

--------------------------------------------------------------------------------
function GuildTaxes:ReduceTax(tax)
	self:Debug("Reduce tax with " .. tax)
	self.db.char[self.guildId].tax = self:GetTax() - tax
	self.GUI:UpdatePayedStatus()
end

--------------------------------------------------------------------------------
function GuildTaxes:PayTax()
	self:Debug("PayTax() called: isBankOpened=" .. tostring(self.isBankOpened)
		.. " tax=" .. tostring(floor(self:GetTax()))
		.. " isPayingTax=" .. tostring(self.isPayingTax))
	if not self.isBankOpened then
		self:Print(GT_CHAT_OPEN_BANK)
		return
	end
	if self.isPayingTax then
        self:Debug("PayTax() already in progress, ignoring")
        return
    end
	self.isPayingTax = true
	self:PrintPayingTax(self:GetTax())
	local amount = floor(self:GetTax())
	self:Debug("Calling DepositGuildBankMoney(" .. tostring(amount) .. ")")
	C_Timer.After(0.5, function()
		self:Debug("Deposit timer fired, depositing " .. tostring(amount))
		DepositGuildBankMoney(amount)
	end)
	self.GUI:UpdatePayedStatus()
end

--------------------------------------------------------------------------------
function GuildTaxes:WritePaymentToHistory(tax)
	local month = tonumber(date("%m"))
	local year = tonumber(date("%Y"))
	local key = self:HistoryKey(year, month)
	local playerHistory = self:GetPlayerHistoryDB(self.playerName, true)
	if playerHistory[key] == nil then
		playerHistory[key] = 0
	end
	if playerHistory["total"] == nil then
		playerHistory["total"] = 0
	end
	playerHistory[key] = playerHistory[key] + tax
	playerHistory["total"] = playerHistory["total"] + tax
end

--------------------------------------------------------------------------------
function GuildTaxes:SendData(data)
	local message = table.concat(data, "\t")
	self:Debug("Send (still " .. #self.outgoingQueue .. " in queue): " .. message)
	C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, message, "GUILD")
end

--------------------------------------------------------------------------------
function GuildTaxes:NotifyStatus(playerName)
	if not playerName then
        self:Debug("NotifyStatus: playerName is nil, skipping")
    	return
    end
	local status = self:GetStatus(playerName)
	if status and status.version ~= nil then
		self:Debug("Add status message for " .. playerName .. " to queue")
		local data = {"T", status.version, status.timestamp, playerName, status.rate, math.floor(status.tax)}
		for key, value in pairs(status.history) do
			table.insert(data, key)
			table.insert(data, value)
		end
		table.insert(data, status.total)
		table.insert(self.outgoingQueue, 1, data)
	else
		self:Debug("No status for " .. playerName .. ", ignoring")
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:RequestStatus(playerName, timestamp)
	self:Debug("Add status request for " .. playerName .. " to queue")
	if timestamp == nil then
		timestamp = self:GetPlayerStatusDB(playerName, true).timestamp
	end
	local data = {"S", playerName}
	if timestamp ~= nil then
		table.insert(data, timestamp)
	end
	table.insert(self.outgoingQueue, data)
end

--------------------------------------------------------------------------------
function GuildTaxes:RemoveQueueS(playerName)
	for i=#self.outgoingQueue, 1, -1 do
		local data=self.outgoingQueue[i]
		if data[1] == "S" and data[2] == playerName then
			table.remove(self.outgoingQueue, i)
		end
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:RemoveQueueT(playerName)
	for i=#self.outgoingQueue, 1, -1 do
		local data=self.outgoingQueue[i]
		if data[1] == "T" and data[4] == playerName then
			table.remove(self.outgoingQueue, i)
		end
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:FillOutgoingQueue()
	self:Debug("Filling outgoung queue")

	local statusDB = GuildTaxes:GetStatusDB()

	if self.numberMembers ~= nil and self.numberMembers > 0 then
		for index = 1, self.numberMembers do
			-- The roster can be mid-refresh and return nil for an index
			local playerName = GetGuildRosterInfo(index)
			if playerName and not IsSecret(playerName) then
				playerName = Ambiguate(playerName, "guild")
				self:MigrateShortName(playerName)
				local playerStatus = self:GetPlayerStatusDB(playerName)
				if playerStatus == nil or playerStatus.updated == nil then
					self:RequestStatus(playerName)
				elseif playerStatus.updated + REFRESH_PLAYER_STATUS_PERIOD < time() then
					self:RequestStatus(playerName, playerStatus.timestamp)
				end
			end
		end
	end

	self.nextSyncTimestamp = time() + REFRESH_ALL_PERIOD
end

--------------------------------------------------------------------------------
function GuildTaxes:QueueIteration()
	-- Schedule the next run first, so an error below can't stop the sync for good
	C_Timer.After(QUEUE_ITERATION, GuildTaxes.QueueIteration)
	if GuildTaxes.isReady and not InCombatLockdown() and not InChatMessagingLockdown() then
		if #GuildTaxes.outgoingQueue > 0 then
			local data = table.remove(GuildTaxes.outgoingQueue, 1)
			if data[1] == "S" then
				local playerName = data[2]
				if playerName then
					local playerStatus = GuildTaxes:GetPlayerStatusDB(playerName, true)
					playerStatus.updated = time()
				end
			end
			GuildTaxes:SendData(data)
		else
			if GuildTaxes.nextPurgeTimestamp < time() then
				GuildTaxes:PurgeOldData()
			end
			if GuildTaxes.nextSyncTimestamp < time() then
				GuildTaxes:FillOutgoingQueue()
			end
		end
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:PurgeOldData()
	self:Debug("Purging old data")
	if self.numberMembers ~= nil and self.numberMembers > 0 then
		local statusDB = self:GetStatusDB()
		local guildPlayers = {}
		for index = 1, GuildTaxes.numberMembers do
			local fullName = GetGuildRosterInfo(index)
			if fullName and not IsSecret(fullName) then
				table.insert(guildPlayers, Ambiguate(fullName, "guild"))
			end
		end
		self.nextPurgeTimestamp = time() + PURGE_DATA_PERIOD
		-- TODO: purge old history records
		-- TODO: purge player's data that left guild
	end
end


--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
GuildTaxes.commands = {
	[""]         = "OnGUICommand";
	["sync"]     = "OnSyncCommand";
	["status"]   = "OnPrintTaxCommand";
	["reset"]    = "OnResetCommand";
	["resetall"] = "OnResetAllCommand";
}

--------------------------------------------------------------------------------
function GuildTaxes:IsGuildMaster()
	if not self.numberMembers then return false end
	for i = 1, self.numberMembers do
		local name, _, rankIndex = GetGuildRosterInfo(i)
		if name and Ambiguate(name, "guild") == self.playerName and rankIndex == 0 then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
function GuildTaxes:OnPrintTaxCommand()
	if self.isReady then
		self:PrintTax()
	else
		self.PrintNotReady()
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:OnGUICommand()
	if self.isReady then
		self.GUI:Toggle()
		if self.GUI:IsShown() then
			self.GUI:RefreshTable()
		end
	else
		self:PrintNotReady()
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:OnSyncCommand()
	self:SendData({"S"})
end

--------------------------------------------------------------------------------
function GuildTaxes:OnResetAllCommand()
	if not self.isReady then self:PrintNotReady() return end
	if not self:IsGuildMaster() then
		self:Print("|cffff4444Reset is only available to the Guild Master.|r")
		return
	end
	-- Wipe in-place to preserve AceDB metatables
	local guildDB = self:GetGuildDB()
	wipe(guildDB.history or {})
	wipe(guildDB.status or {})
	guildDB.history = {}
	guildDB.status = {}
	self.db.char[self.guildId].tax = 0
	self.GUI:UpdatePayedStatus()
	self:Print("|cff69ccf0All guild tax history and counters have been reset.|r")
end

--------------------------------------------------------------------------------
function GuildTaxes:OnSlashCommand(input, val)
	local args = {}
	for word in input:gmatch("%S+") do
		table.insert(args, word)
	end

	local _, operation = next(args)
	if operation == nil then
		operation = ""
	end

	if self.commands[operation] then
		self[self.commands[operation]](self)
	else
		self:Debug("Unknown command: " .. operation)
	end
end


--------------------------------------------------------------------------------
-- Communication events
--------------------------------------------------------------------------------
GuildTaxes.events = {

	-- Sync command
	["S"] = function (sender, ...)
		local playerName = select(1, ...)
		if playerName == nil then
			playerName = GuildTaxes.playerName
		end
		local timestamp = select(2, ...)
		if timestamp ~= nil then
			timestamp = tonumber(timestamp)
		end

		local playerStatus = GuildTaxes:GetPlayerStatusDB(playerName, true)
		if playerStatus.timestamp ~= nil then
			if timestamp == nil or timestamp < playerStatus.timestamp then
				GuildTaxes:Debug("Recieved request for " .. playerName)
				GuildTaxes:NotifyStatus(playerName)
			elseif timestamp == playerStatus.timestamp then
				GuildTaxes:Debug("Recieved request for " .. playerName .. ", have same, ignoring")
			else
				GuildTaxes:Debug("Recieved request for " .. playerName .. ", have older, ignoring")
			end
		else
			GuildTaxes:Debug("Recieved request for " .. playerName .. ", have no status, ignoring")
		end
		playerStatus.updated = time()
		GuildTaxes:RemoveQueueS(playerName)
	end,

	-- Player's status
	["T"] = function (sender, version, timestamp, playerName, rate, tax, ...)

		-- TODO: check if recieved request newer

		timestamp = tonumber(timestamp)
		if timestamp == nil then
			GuildTaxes:Debug("Incorrect T-message received from " .. sender)
			return
		end

		rate = tonumber(rate)
		if rate == nil then
			GuildTaxes:Debug("Incorrect T-message received from " .. sender)
			return
		end

		tax = tonumber(tax)
		if tax == nil then
			GuildTaxes:Debug("Incorrect T-message received from " .. sender)
			return
		end

		local playerStatus = GuildTaxes:GetPlayerStatusDB(playerName, true)
		if playerStatus.timestamp == nil or playerStatus.timestamp < timestamp or (sender == playerName and playerStatus.timestamp ~= timestamp) then
			GuildTaxes:Debug("Receive status for " .. tostring(playerName) .. ", updating")
			playerStatus.timestamp = timestamp
			playerStatus.version = version
			playerStatus.rate = rate
			playerStatus.tax = tax
			playerStatus.updated = timestamp
			GuildTaxes:RemoveQueueS(playerName)
			GuildTaxes:RemoveQueueT(playerName)

			local playerHistory = GuildTaxes:GetPlayerHistoryDB(playerName, true)
			for i=1, #... - 1, 2 do
				local key = select(i, ...)
				if key ~= nil then
					local val = tonumber(select(i+1, ...), 10)
					if val == nil then
						val = 0
					end
					playerHistory[key] = val
				end
			end

			local total = tonumber(select(-1, ...), 10)
			if total == nil then
				total = 0
			end
			playerHistory["total"] = total

			if GuildTaxes.GUI:IsShown() then
				GuildTaxes.GUI:RefreshTable()
			end

		elseif playerStatus.timestamp == timestamp then
			GuildTaxes:Debug("Receive status for " .. tostring(playerName) .. ", have same, ignoring")

		else
			GuildTaxes:Debug("Receive status for " .. tostring(playerName) .. ", have newer, ignoring")
		end
	end,
}

function GuildTaxes:OnCommReceived(prefix, message, channel, sender)
	if IsSecret(prefix, message, channel, sender) then
		return
	end
	if prefix == MESSAGE_PREFIX and message and channel == "GUILD" then
		if not GuildTaxes.isReady then
			GuildTaxes:Debug("Addon not ready, ignoring incoming message")
			return
		end
		local data = {}
		for word in string.gmatch(message, "[^\t]+") do
			data[#data + 1] = word
		end
		if #data > 0 then
			local command = table.remove(data, 1)
			local handler = GuildTaxes.events[command]
			if handler then
				handler(sender, unpack(data))
			else
				GuildTaxes:Debug("Unknown command received from " .. sender .. ": ".. command)
			end
		end
	end
end


--------------------------------------------------------------------------------
-- Hyperlink chat handler
--------------------------------------------------------------------------------
function GuildTaxes:OnPayLinkClicked(link)
	if type(link) ~= "string" or IsSecret(link) then
		return
	end
	local linkType, addonName = strsplit(":", link)
	if linkType == "addon" and addonName == "GuildTaxes" then
		if self.isReady then
			local tax = floor(self:GetTax())
			if tax > 0 then
				self:PayTax()
			else
				self:PrintNothingToPay()
			end
		else
			self:PrintNotReady()
		end
	end
end


--------------------------------------------------------------------------------
-- WoW events handlers
--------------------------------------------------------------------------------

-- Try to attach OnShow/OnHide hooks to GuildBankFrame.
-- Called at login and again from any bank event in case the frame was nil at login.
function GuildTaxes:TryAttachBankFrameHooks()
	if not GuildBankFrame then
		self:Debug("TryAttachBankFrameHooks: GuildBankFrame is nil")
		return false
	end
	if GuildBankFrame.gtHooked then
		self:Debug("TryAttachBankFrameHooks: already hooked")
		return true
	end
	GuildBankFrame.gtHooked = true
	self:Debug("TryAttachBankFrameHooks: attaching OnShow/OnHide hooks")
	GuildBankFrame:HookScript("OnShow", function(frame)
		-- Verify it's actually the GuildBankFrame by checking name
		if frame:GetName() == "GuildBankFrame" then
			GuildTaxes:Debug("GuildBankFrame:OnShow fired")
			GuildTaxes:GUILDBANKFRAME_OPENED()
		end
	end)
	GuildBankFrame:HookScript("OnHide", function(frame)
		-- Verify it's actually the GuildBankFrame by checking name
		if frame:GetName() == "GuildBankFrame" then
			C_Timer.After(0, function()
				local visible = frame:IsVisible()
				GuildTaxes:Debug("GuildBankFrame:OnHide deferred — IsVisible=" .. tostring(visible))
				if not visible then
					GuildTaxes:GUILDBANKFRAME_CLOSED()
				end
			end)
		end
	end)
	return true
end

--------------------------------------------------------------------------------
function GuildTaxes:PLAYER_ENTERING_WORLD( ... )
	-- Create GUI
	self.GUI:Create()

	self:Debug("PLAYER_ENTERING_WORLD: GuildBankFrame exists=" .. tostring(GuildBankFrame ~= nil))

	-- Reset bank/mail state when entering a new zone/instance
	-- (player can't be in bank or mailbox when entering a new area)
	self.isBankOpened = false
	self.isMailOpened = false
	self.bankDataReady = false

	-- Attach frame hooks (works if GuildBankFrame already exists at login).
	self:TryAttachBankFrameHooks()

	-- Fallback 1: hooksecurefunc on ShowUIPanel/HideUIPanel.
	-- In TBC Classic, the guild bank is shown via ShowUIPanel(GuildBankFrame).
	-- This is the most reliable open/close signal when WoW events don't fire.
	if not GuildTaxes.gtShowUIPanelHooked then
		GuildTaxes.gtShowUIPanelHooked = true
		if ShowUIPanel then
			hooksecurefunc("ShowUIPanel", function(frame)
				-- Verify it's actually the GuildBankFrame by checking both reference and name
				if frame and frame == GuildBankFrame and frame:GetName() == "GuildBankFrame" then
					GuildTaxes:Debug("ShowUIPanel(GuildBankFrame) detected")
					GuildTaxes:GUILDBANKFRAME_OPENED()
				end
			end)
			self:Debug("ShowUIPanel hook attached")
		else
			self:Debug("ShowUIPanel not found, skipping hook")
		end
		if HideUIPanel then
			hooksecurefunc("HideUIPanel", function(frame)
				-- Verify it's actually the GuildBankFrame by checking both reference and name
				if frame and frame == GuildBankFrame and frame:GetName() == "GuildBankFrame" then
					C_Timer.After(0, function()
						if GuildBankFrame and not GuildBankFrame:IsVisible() then
							GuildTaxes:Debug("HideUIPanel(GuildBankFrame) detected")
							GuildTaxes:GUILDBANKFRAME_CLOSED()
						end
					end)
				end
			end)
			self:Debug("HideUIPanel hook attached")
		else
			self:Debug("HideUIPanel not found, skipping hook")
		end
	end

	-- Fallback 2: helper frame that retries TryAttachBankFrameHooks on bank events,
	-- for the edge case where GuildBankFrame was nil at login.
	if not GuildBankFrame then
		self:Debug("GuildBankFrame nil at login — hookHelper will attach on first bank event")
		local hookHelper = CreateFrame("Frame")
		for _, event in ipairs({"GUILDBANKFRAME_OPENED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "GUILDBANK_UPDATE_MONEY"}) do
			if IsEventValid(event) then
				hookHelper:RegisterEvent(event)
			end
		end
		hookHelper:SetScript("OnEvent", function(self, event)
			GuildTaxes:Debug("hookHelper caught " .. event .. " — retrying TryAttachBankFrameHooks")
			if GuildTaxes:TryAttachBankFrameHooks() then
				self:UnregisterAllEvents()
			end
		end)
	end

	-- Update data
	self:UpdatePlayerName()
	self:UpdatePlayerMoney()
	self:UpdateGuildInfo()

	-- Attempt to mark ready immediately (guildId may already be set from
	-- a cached GUILD_ROSTER_UPDATE that fired before this event)
	self:Ready()

	-- Update guild roster (triggers GUILD_ROSTER_UPDATE → Ready() retry)
	RequestGuildRoster()

	-- Start queue iteration
	C_Timer.After(QUEUE_ITERATION, self.QueueIteration)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
function GuildTaxes:HandleDeposit(amount)
	local now = time()
    if self.lastDepositTime == now and self.lastDepositAmount == amount then
        self:Debug("Duplicate HandleDeposit(" .. amount .. ") suppressed")
        return
    end
    self.lastDepositTime = now
    self.lastDepositAmount = amount
	self:Debug("Deposit confirmed: " .. tostring(amount))
	self:ReduceTax(amount)
	self:WritePaymentToHistory(amount)
	self:PrintTax()
	self:NotifyStatus(self.playerName)
	self.isPayingTax = false
	self.GUI:UpdatePayButton()
end

--------------------------------------------------------------------------------
function GuildTaxes:PLAYER_MONEY( ... )

	local newPlayerMoney = GetMoney()
	local delta = newPlayerMoney - self.playerMoney

	self:Debug("Player money, delta=" .. tostring(delta))

	if not self.isReady then
		self:Debug("Addon is not ready, transaction ignored")

	elseif delta > 0 then
		if not self.guildId then
			self:Debug("Not in guild, transaction ignored")
		elseif self.isMailOpened then
			self:Debug("Mailbox is open, transaction ignored")
		elseif self.isBankOpened then
			self:Debug("Guild bank is open, transaction ignored")
		else
			self:AccrueTax(delta, delta * self.db.char.rate)
			self:NotifyStatus(self.playerName)
		end

	elseif delta < 0 and self.isBankOpened and self.bankDataReady then
		-- Player lost money while bank is open: check if guild bank received it.
		-- This catches deposits when GUILDBANK_UPDATE_MONEY doesn't fire.
		local newBankMoney = GetGuildBankMoney()
		local bankDelta = newBankMoney - self.guildBankMoney
		self:Debug("Bank delta check: player -" .. tostring(-delta) .. ", bank +" .. tostring(bankDelta))
		if bankDelta > 0 then
			self.guildBankMoney = newBankMoney
			self:HandleDeposit(bankDelta)
		else
			self:Debug("No bank increase, ignoring withdrawal")
		end
	else
		self:Debug("Ignoring money change")
	end

	self:UpdatePlayerMoney(newPlayerMoney)
end

--------------------------------------------------------------------------------
function GuildTaxes:GUILDBANKFRAME_OPENED( ... )
	self:Debug("GUILDBANKFRAME_OPENED fired: isBankOpened=" .. tostring(self.isBankOpened))
	if self.isBankOpened then
		self:Debug("Already marked open, ignoring")
		return
	end  -- idempotent: event + frame-fallback may both fire
	self:Debug("Guild bank opened")
	self.isBankOpened = true
	self.GUI:UpdatePayButton()
	self.bankDataReady = false  -- first GUILDBANK_UPDATE_MONEY is the initial data load, not a deposit
	self.guildBankMoney = GetGuildBankMoney()
	self:Debug("Snapshot bank money: " .. tostring(self.guildBankMoney) .. " isReady=" .. tostring(self.isReady) .. " tax=" .. tostring(floor(self:GetTax())) .. " autopay=" .. tostring(self.db.profile.autopay))

	-- Allow time for GUILDBANK_UPDATE_MONEY to fire with the real balance.
	-- If it never fires (some client versions), mark data ready after 1s and trigger autopay.
	C_Timer.After(1, function()
		self:Debug("1s timer: isBankOpened=" .. tostring(self.isBankOpened) .. " bankDataReady=" .. tostring(self.bankDataReady) .. " isPayingTax=" .. tostring(self.isPayingTax))
		if self.isBankOpened and not self.bankDataReady then
			self:Debug("GUILDBANK_UPDATE_MONEY did not fire, using cached balance")
			self.guildBankMoney = GetGuildBankMoney()
			self.bankDataReady = true
			if self.isReady and not self.isPayingTax then
				local tax = floor(self:GetTax())
				self:Debug("1s timer autopay: tax=" .. tostring(tax) .. " autopay=" .. tostring(self.db.profile.autopay))
				if tax >= 1 and self.db.profile.autopay then
					self:PayTax()
				else
					self:PrintTax()
				end
			end
		end
	end)

	if not self.isReady then
		self:PrintNotReady()
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:GUILDBANK_UPDATE_MONEY( ... )
	-- If GuildBankFrame wasn't hooked yet, try now (edge case: frame was nil at login)
	self:TryAttachBankFrameHooks()

	self:Debug("GUILDBANK_UPDATE_MONEY fired: isBankOpened=" .. tostring(self.isBankOpened)
		.. " bankDataReady=" .. tostring(self.bankDataReady)
		.. " frameVisible=" .. tostring(GuildBankFrame and GuildBankFrame:IsVisible() or false))
	-- If bank event fires but we missed the open event, only treat as open
	-- when the guild bank frame is actually visible. This guards against the
	-- event firing due to other guild members' transactions when our bank is
	-- closed, which would permanently corrupt isBankOpened state.
	if not self.isBankOpened then
		if GuildBankFrame and GuildBankFrame:IsVisible() then
			self:Debug("GUILDBANK_UPDATE_MONEY: frame visible but not marked open — fixing")
			self:GUILDBANKFRAME_OPENED()
		else
			self:Debug("GUILDBANK_UPDATE_MONEY fired with bank closed — ignoring")
		end
		return
	end

	local newMoney = GetGuildBankMoney()
	local delta = newMoney - self.guildBankMoney
	self:Debug("Bank money update: prev=" .. tostring(self.guildBankMoney) .. " new=" .. tostring(newMoney) .. " delta=" .. tostring(delta))
	self.guildBankMoney = newMoney

	if not self.bankDataReady then
		-- First event after opening: the server is delivering the real bank balance.
		-- GetGuildBankMoney() may have returned 0 at bank-open time, so the delta
		-- here is just a snapshot correction, not a real deposit. Always treat this
		-- as the baseline and trigger autopay (unless isPayingTax is already set,
		-- which means direct-deposit mode is active and the player will pay manually).
		self:Debug("Guild bank data loaded, balance: " .. tostring(newMoney))
		self.bankDataReady = true
		if self.isReady and not self.isPayingTax then
			local tax = floor(self:GetTax())
			if tax >= 1 and self.db.profile.autopay then
				self:PayTax()
			else
				self:PrintTax()
			end
		end
		return
	end

	if delta > 0 and self.isReady and self.isPayingTax then
    self:HandleDeposit(delta)
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:GUILDBANKFRAME_CLOSED( ... )
	self:Debug("GUILDBANKFRAME_CLOSED fired: isBankOpened=" .. tostring(self.isBankOpened))
	if self.isBankOpened then
		self:Debug("Guild bank closed")
		self.isBankOpened = false
		self.GUI:UpdatePayButton()
		self.bankDataReady = false
	else
		self:Debug("Bank was not marked open, ignoring close")
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:MAIL_SHOW( ... )
	self:Debug("Mailbox opened")
	self.isMailOpened = true
end

--------------------------------------------------------------------------------
function GuildTaxes:MAIL_CLOSED( ... )
	if self.isMailOpened then
		self:Debug("Mailbox closed")
		self.isMailOpened = false
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:PLAYER_GUILD_UPDATE(event, unit)
	-- In TBC Classic the unit arg may be nil; treat any fire as a player update
	if unit == nil or unit == "player" then
		self:Debug("Player guild info updated")
		self:UpdateGuildInfo()
		if self.playerName then
            self:Ready()
        end
	end
end

--------------------------------------------------------------------------------
function GuildTaxes:GUILD_ROSTER_UPDATE( ... )
	self:UpdateGuildInfo()
	local needRefresh = false
	local numMembers, numOnline, _ = GetNumGuildMembers()
	if self.numberMembers ~= numMembers then
		self:Debug("Number of guild members changed: " .. tostring(self.numberMembers) .. " -> " .. numMembers)
		self.numberMembers = numMembers
		needRefresh = true
	end
	if self.numberMembersOnline ~= numOnline then
		self:Debug("Number of online members changed: " .. tostring(self.numberMembersOnline) .. " -> " .. numOnline)
		self.numberMembersOnline = numOnline
		needRefresh = true
	end
	if self.GUI:IsShown() then
		if needRefresh then
			self.GUI.updated = nil
		end
		self.GUI:RefreshTable()
	end
	if self.playerName then
        self:Ready()
    end
end


--------------------------------------------------------------------------------
-- Register events & commands
--------------------------------------------------------------------------------
-- Pay link clicks: the modern client fires EventRegistry "SetItemRef" for
-- "addon:" links. Without EventRegistry, hook the chat frames instead.
if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("SetItemRef", function(_, link)
		GuildTaxes:OnPayLinkClicked(link)
	end, GuildTaxes)
else
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local frame = _G["ChatFrame" .. i]
		if frame then
			frame:HookScript("OnHyperlinkClick", function(_, link)
				GuildTaxes:OnPayLinkClicked(link)
			end)
		end
	end
end

-- Guild bank and mailbox open/close on the modern client
function GuildTaxes:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(event, interactionType)
	if interactionType == nil or IsSecret(interactionType) then return end
	if interactionType == INTERACTION_GUILD_BANKER then
		self:TryAttachBankFrameHooks()
		self:GUILDBANKFRAME_OPENED()
	elseif interactionType == INTERACTION_MAIL then
		self:MAIL_SHOW()
	end
end

function GuildTaxes:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(event, interactionType)
	if interactionType == nil or IsSecret(interactionType) then return end
	if interactionType == INTERACTION_GUILD_BANKER then
		self:GUILDBANKFRAME_CLOSED()
	elseif interactionType == INTERACTION_MAIL then
		self:MAIL_CLOSED()
	end
end

GuildTaxes:RegisterComm(MESSAGE_PREFIX)

GuildTaxes:RegisterChatCommand(SLASH_COMMAND, "OnSlashCommand")

-- Only register events this client knows (unknown events raise an error)
for _, event in ipairs({
	"PLAYER_ENTERING_WORLD",
	"PLAYER_MONEY",
	"PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
	"PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
	"GUILDBANKFRAME_OPENED",
	"GUILDBANKFRAME_CLOSED",
	"GUILDBANK_UPDATE_MONEY",
	"MAIL_SHOW",
	"MAIL_CLOSED",
	"PLAYER_GUILD_UPDATE",
	"GUILD_ROSTER_UPDATE",
}) do
	if IsEventValid(event) then
		GuildTaxes:RegisterEvent(event)
	end
end
