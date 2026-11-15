--
-- GuildTaxes - keep your guild bank full
-- Author: Неогик@Галакронд
--
-- WoW: Forever: the main window is built from the client's own panel
-- templates (PortraitFrameTemplate, InsetFrameTemplate, WowScrollBoxList,
-- MinimalScrollBar), so it looks like the Professions window and the other
-- Forever windows instead of an AceGUI frame.
--

-- Settings
local TABLE_UPDATE_THRESHOLD = 5
local WINDOW_NAME = "GuildTaxesFrame"
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 660, 520
local MIN_WIDTH, MIN_HEIGHT = 600, 340
local ROW_HEIGHT = 20
local PORTRAIT = "Interface\\Icons\\INV_Misc_Coin_02"

-- Columns, right to left after the name: key, width, justify
local COLUMNS = {
	{ key = "name",  justify = "LEFT" },             -- fills the rest
	{ key = "rank",  width = 100, justify = "LEFT" },
	{ key = "tax",   width = 104, justify = "RIGHT" },
	{ key = "m1",    width = 66,  justify = "RIGHT" },
	{ key = "m2",    width = 66,  justify = "RIGHT" },
	{ key = "m3",    width = 66,  justify = "RIGHT" },
	{ key = "total", width = 84,  justify = "RIGHT" },
}

local MONTH_NAMES = {
	GT_GUI_MONTH_1, GT_GUI_MONTH_2, GT_GUI_MONTH_3, GT_GUI_MONTH_4,
	GT_GUI_MONTH_5, GT_GUI_MONTH_6, GT_GUI_MONTH_7, GT_GUI_MONTH_8,
	GT_GUI_MONTH_9, GT_GUI_MONTH_10, GT_GUI_MONTH_11, GT_GUI_MONTH_12,
}

local OFFLINE_COLOR = { r = 0.5, g = 0.5, b = 0.5 }

-- GUI
local GUI = {
	frame = nil,
	status = "-",
	data = {},
	updated = nil,
}
GuildTaxes.GUI = GUI


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function MoneyString(value)
	if value then
		return GuildTaxes:FormatMoney(floor(value / 100 / 100) * 100 * 100)
	end
	return "-"
end

local function RateString(rate)
	return format("%d%%", floor((rate or 0) * 100 + 0.5))
end

-- The last three months, newest first
local function MonthHeaders()
	local headers = {}
	local month = tonumber(date("%m"))
	for i = 1, 3 do
		headers[i] = MONTH_NAMES[month]
		month = month - 1
		if month == 0 then month = 12 end
	end
	return headers
end

local function ClassColor(classFile)
	if not classFile then return nil end
	if C_ClassColor and C_ClassColor.GetClassColor then
		return C_ClassColor.GetClassColor(classFile)
	end
	return RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
end

-- One FontString per column, anchored right to left so header and rows line up
local function CreateCells(parent, fontObject)
	local cells = {}
	for i, column in ipairs(COLUMNS) do
		local cell = parent:CreateFontString(nil, "ARTWORK", fontObject)
		cell:SetJustifyH(column.justify)
		cell:SetWordWrap(false)
		cells[i] = cell
		cells[column.key] = cell
	end
	local right = nil
	for i = #COLUMNS, 2, -1 do
		local cell = cells[i]
		cell:SetWidth(COLUMNS[i].width)
		if right then
			cell:SetPoint("RIGHT", right, "LEFT", -6, 0)
		else
			cell:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
		end
		right = cell
	end
	cells[1]:SetPoint("LEFT", parent, "LEFT", 10, 0)
	cells[1]:SetPoint("RIGHT", right, "LEFT", -6, 0)
	return cells
end


--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------
local function InitRow(button)
	if button.cells then return end
	button:SetHeight(ROW_HEIGHT)

	button.stripe = button:CreateTexture(nil, "BACKGROUND")
	button.stripe:SetAllPoints()
	button.stripe:SetColorTexture(1, 1, 1, 0.04)

	button.selected = button:CreateTexture(nil, "BACKGROUND", nil, 1)
	button.selected:SetAtlas("auctionhouse-ui-row-select")
	button.selected:SetAllPoints()
	button.selected:Hide()

	button:SetHighlightAtlas("auctionhouse-ui-row-highlight")

	button.cells = CreateCells(button, "GameFontHighlightSmall")
end

local function RenderRow(button, row)
	InitRow(button)
	local cells = button.cells
	local index = button.GetElementDataIndex and button:GetElementDataIndex() or 0

	button.stripe:SetShown(index % 2 == 0)
	button.selected:SetShown(row.isPlayer == true)

	local shortName = Ambiguate(row.fullName, "guild")
	cells.name:SetText(shortName)
	cells.rank:SetText(row.rank or "")

	if row.version == nil then
		cells.tax:SetText("")
		cells.m1:SetText("")
		cells.m2:SetText("")
		cells.m3:SetText("")
		cells.total:SetText("")
	else
		cells.tax:SetText(MoneyString(row.tax) .. " (" .. RateString(row.rate) .. ")")
		cells.m1:SetText(MoneyString(row.months[1]))
		cells.m2:SetText(MoneyString(row.months[2]))
		cells.m3:SetText(MoneyString(row.months[3]))
		cells.total:SetText(MoneyString(row.total))
	end

	-- Online: class-coloured name, white values; offline: everything grey
	local nameColor = row.online and (ClassColor(row.class) or HIGHLIGHT_FONT_COLOR) or OFFLINE_COLOR
	cells.name:SetTextColor(nameColor.r, nameColor.g, nameColor.b)
	local textColor = row.online and HIGHLIGHT_FONT_COLOR or OFFLINE_COLOR
	for i = 2, #COLUMNS do
		cells[i]:SetTextColor(textColor.r, textColor.g, textColor.b)
	end
end


--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------
function GUI:Create()
	if self.frame then return end

	local db = GuildTaxes.db.profile
	local frame = CreateFrame("Frame", WINDOW_NAME, UIParent, "PortraitFrameTemplate")
	frame:Hide()
	tinsert(UISpecialFrames, WINDOW_NAME) -- Escape closes it
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
	end
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		local point, _, relativePoint, x, y = f:GetPoint(1)
		db.mainFramePoint = { point, relativePoint, x, y }
	end)

	frame:SetTitle(GT_GUI_TITLE)
	if frame.SetPortraitToAsset then
		frame:SetPortraitToAsset(PORTRAIT)
	elseif frame.GetPortrait then
		frame:GetPortrait():SetTexture(PORTRAIT)
	end

	-- Size and position (sizes saved by the old AceGUI window are clamped)
	local width = math.max(MIN_WIDTH, db.mainFrameWidth or DEFAULT_WIDTH)
	local height = math.max(MIN_HEIGHT, db.mainFrameHeight or DEFAULT_HEIGHT)
	frame:SetSize(width, height)
	local saved = db.mainFramePoint
	if type(saved) == "table" and saved[1] then
		frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
	else
		frame:SetPoint("CENTER")
	end

	-- Heading: guild name, and the player's own tax below it
	frame.heading = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	frame.heading:SetPoint("TOPLEFT", 62, -34)
	frame.heading:SetPoint("RIGHT", -16, 0)
	frame.heading:SetJustifyH("LEFT")

	frame.subtitle = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	frame.subtitle:SetPoint("TOPLEFT", 62, -56)
	frame.subtitle:SetPoint("RIGHT", -16, 0)
	frame.subtitle:SetJustifyH("LEFT")

	-- Inset with the members table
	local inset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	inset:SetPoint("TOPLEFT", 14, -78)
	inset:SetPoint("BOTTOMRIGHT", -14, 44)
	frame.inset = inset

	local header = CreateFrame("Frame", nil, inset)
	header:SetPoint("TOPLEFT", 4, -4)
	header:SetPoint("TOPRIGHT", -24, -4)
	header:SetHeight(20)
	frame.headerCells = CreateCells(header, "GameFontNormalSmall")
	frame.headerCells.name:SetText(GT_GUI_COL_NAME)
	frame.headerCells.rank:SetText(GT_GUI_COL_RANK)
	frame.headerCells.tax:SetText(GT_GUI_COL_TAX)
	frame.headerCells.total:SetText(GT_GUI_COL_TOTAL)

	local divider = inset:CreateTexture(nil, "ARTWORK")
	divider:SetAtlas("_UI-Frame-InnerTopTile")
	divider:SetPoint("TOPLEFT", 4, -24)
	divider:SetPoint("RIGHT", -4, 0)
	divider:SetHeight(3)

	local scroll = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
	scroll:SetPoint("TOPLEFT", 4, -27)
	scroll:SetPoint("BOTTOMRIGHT", -24, 4)
	local scrollBar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", RenderRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scroll, scrollBar, view)
	frame.scroll = scroll

	-- Bottom bar: online filter and pay button
	local online = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	online:SetSize(26, 26)
	online:SetPoint("BOTTOMLEFT", 14, 12)
	online:SetChecked(db.onlineOnly and true or false)
	online:SetScript("OnClick", function(button)
		GUI:OnOnlineValueChanged(nil, button:GetChecked() == true)
	end)
	frame.onlineCheckBox = online

	local onlineLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	onlineLabel:SetPoint("LEFT", online, "RIGHT", 2, 0)
	onlineLabel:SetText(GT_GUI_ONLINE_ONLY)

	frame.count = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.count:SetPoint("LEFT", onlineLabel, "RIGHT", 12, 0)

	local pay = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	pay:SetText(GT_CHAT_TAX_CLICK)
	pay:SetSize(math.max(120, pay:GetFontString():GetStringWidth() + 32), 22)
	pay:SetPoint("BOTTOMRIGHT", -26, 14)
	pay:SetMotionScriptsWhileDisabled(true)
	pay:SetScript("OnClick", function()
		GuildTaxes:PayTax()
	end)
	pay:SetScript("OnEnter", function(button)
		if not button:IsEnabled() and floor(GuildTaxes:GetTax()) >= 1 then
			GameTooltip:SetOwner(button, "ANCHOR_TOP")
			GameTooltip:AddLine(GT_CHAT_OPEN_BANK, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	pay:SetScript("OnLeave", GameTooltip_Hide)
	frame.payButton = pay

	-- Resize grip, like the client's own resizable panels
	local resize = CreateFrame("Button", nil, frame, "PanelResizeButtonTemplate")
	resize:SetPoint("BOTTOMRIGHT", -4, 4)
	resize:Init(frame, MIN_WIDTH, MIN_HEIGHT)
	frame:SetScript("OnSizeChanged", function(f)
		db.mainFrameWidth = f:GetWidth()
		db.mainFrameHeight = f:GetHeight()
	end)

	frame:SetScript("OnShow", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		GUI.updated = nil
		GUI:UpdatePayedStatus()
		GUI:RefreshTable()
	end)
	frame:SetScript("OnHide", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
	end)

	self.frame = frame

	-- Tax mini frame (persistent across GUI open/close)
	self.TaxFrame:Create()
end

--------------------------------------------------------------------------------
function GUI:Toggle()
	self:Create()
	self.frame:SetShown(not self.frame:IsShown())
end

--------------------------------------------------------------------------------
function GUI:IsShown()
	return self.frame ~= nil and self.frame:IsShown()
end

--------------------------------------------------------------------------------
function GUI:OnOnlineValueChanged(event, value)
	GuildTaxes.db.profile.onlineOnly = value
	GUI:Render()
end

--------------------------------------------------------------------------------
function GUI:UpdatePayButton()
	if not self.frame then return end
	local canPay = GuildTaxes.isReady and GuildTaxes.isBankOpened and not GuildTaxes.isPayingTax
		and floor(GuildTaxes:GetTax()) >= 1
	self.frame.payButton:SetEnabled(canPay and true or false)
end

--------------------------------------------------------------------------------
function GUI:UpdatePayedStatus()
	local guild = GuildTaxes.guildName
	local tax = GuildTaxes:GetTax()
	local rate = GuildTaxes:GetRate()
	if floor(tax) > 0 then
		self.status = format(GT_GUI_TAX, GuildTaxes:FormatMoney(tax))
	else
		self.status = GT_GUI_ALL_PAYED
	end
	self.status = self.status .. format(GT_GUI_GENERAL_INFO, rate * 100, guild or "")
	if self.frame then
		self.frame.heading:SetText(guild or GT_GUI_TITLE)
		self.frame.subtitle:SetText(self.status)
		self:UpdatePayButton()
	end
	GUI.TaxFrame:Update()
end

--------------------------------------------------------------------------------
-- Rebuild the member list from the guild roster and the synced status data
function GUI:RefreshTable()
	if not self.frame then return end
	local now = time()

	-- Flood protection
	if self.updated ~= nil and self.updated + TABLE_UPDATE_THRESHOLD > now then
		return
	end

	local statusDB = GuildTaxes:GetStatusDB()
	local historyDB = GuildTaxes:GetHistoryDB()
	local month = tonumber(date("%m"))
	local year = tonumber(date("%Y"))

	local data = {}
	for index = 1, (GuildTaxes.numberMembers or 0) do
		local fullName, rank, rankIndex, _, _, _, _, _, online, _, class = GetGuildRosterInfo(index)
		if fullName then
			local shortName = Ambiguate(fullName, "guild")
			local r = {
				fullName = fullName,
				rank = rank,
				rankIndex = rankIndex or 99,
				online = online and true or false,
				class = class,
				isPlayer = shortName == GuildTaxes.playerName,
				months = {},
			}

			local userStatus = statusDB[shortName]
			if userStatus ~= nil then
				r.timestamp = userStatus.timestamp
				r.version = userStatus.version
				r.tax = userStatus.tax
				r.rate = userStatus.rate
			end

			local userHistory = historyDB[shortName]
			if userHistory ~= nil then
				local m, y = month, year
				for i = 1, 3 do
					r.months[i] = userHistory[GuildTaxes:HistoryKey(y, m)]
					m = m - 1
					if m == 0 then
						m = 12
						y = y - 1
					end
				end
				r.total = userHistory.total
			end

			data[#data + 1] = r
		end
	end

	-- Guild rank first, then name
	table.sort(data, function(a, b)
		if a.rankIndex ~= b.rankIndex then
			return a.rankIndex < b.rankIndex
		end
		return a.fullName < b.fullName
	end)

	self.data = data
	self.updated = now
	self:Render()
end

--------------------------------------------------------------------------------
-- Push the (filtered) member list into the scroll box
function GUI:Render()
	local frame = self.frame
	if not frame then return end

	local headers = MonthHeaders()
	frame.headerCells.m1:SetText(headers[1])
	frame.headerCells.m2:SetText(headers[2])
	frame.headerCells.m3:SetText(headers[3])

	local onlineOnly = GuildTaxes.db.profile.onlineOnly
	local rows, numOnline = {}, 0
	for _, row in ipairs(self.data) do
		if row.online then numOnline = numOnline + 1 end
		if not onlineOnly or row.online then
			rows[#rows + 1] = row
		end
	end
	frame.count:SetText(format("%d / %d", numOnline, #self.data))

	local provider = CreateDataProvider(rows)
	frame.scroll:SetDataProvider(provider, ScrollBoxConstants.RetainScrollPosition)
end


--------------------------------------------------------------------------------
-- Tax mini frame
--------------------------------------------------------------------------------
local TaxFrame = {}
GUI.TaxFrame = TaxFrame

function TaxFrame:Create()
	if self.frame then return end

	local f = CreateFrame("Frame", "GuildTaxesTaxFrame", UIParent, "BackdropTemplate")
	f:SetSize(120, 22)
	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")

	f:SetBackdrop({
		bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
		tile = true, tileSize = 8, edgeSize = 8,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	f:SetBackdropColor(0, 0, 0, 0.80)
	f:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)

	-- Single centred label: "Tax: 1g 23s"
	local amount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	amount:SetAllPoints()
	amount:SetJustifyH("CENTER")
	amount:SetJustifyV("MIDDLE")
	self.amount = amount

	-- Drag handlers
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop",  function(self)
		self:StopMovingOrSizing()
		GuildTaxes.db.profile.taxFrameX = self:GetLeft()
		GuildTaxes.db.profile.taxFrameY = self:GetTop()
	end)

	-- Left-click: pay if bank open, otherwise toggle main window
	f:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" then
			if GuildTaxes.isBankOpened and floor(GuildTaxes:GetTax()) > 0 then
				GuildTaxes:PayTax()
			else
				GuildTaxes.GUI:Toggle()
			end
		end
	end)

	-- Tooltip
	f:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(GuildTaxes.guildName or "", 0.54, 0.82, 0.68)
		if GuildTaxes.isBankOpened and floor(GuildTaxes:GetTax()) > 0 then
			GameTooltip:AddLine(GT_TAXFRAME_TOOLTIP_PAY, 1, 1, 0)
		else
			GameTooltip:AddLine(GT_TAXFRAME_TOOLTIP_OPEN, 0.8, 0.8, 0.8)
		end
		GameTooltip:AddLine(GT_TAXFRAME_TOOLTIP_DRAG, 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Restore saved position
	local x = GuildTaxes.db.profile.taxFrameX
	local y = GuildTaxes.db.profile.taxFrameY
	if x and y then
		f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, -220)
	end

	if GuildTaxes.db.profile.showTaxFrame then f:Show() else f:Hide() end
	self.frame = f
	self:Update()
end

function TaxFrame:Update()
	if not self.frame then return end
	if not GuildTaxes.guildId then
		self.frame:Hide()
		return
	end
	if GuildTaxes.db.profile.showTaxFrame then
		self.frame:Show()
	end
	if not GuildTaxes.isReady then
		self.amount:SetText("|cff999999...|r")
		self.frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
		return
	end
	local tax = floor(GuildTaxes:GetTax())
	if tax > 0 then
		self.amount:SetText("|cffff6666" .. GT_TAXFRAME_LABEL .. GuildTaxes:FormatMoney(tax) .. "|r")
		self.frame:SetBackdropBorderColor(0.8, 0.2, 0.2, 0.9)
	else
		self.amount:SetText("|cff44dd44" .. GT_GUI_ALL_PAYED .. "|r")
		self.frame:SetBackdropBorderColor(0.2, 0.6, 0.2, 0.9)
	end
end
