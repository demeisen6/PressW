-- PressW — RecordsUI.lua
-- M5: a window listing the best OOC time per dungeon, with filters for
-- season / character / min key level, sortable columns, and chat announcing.
-- See PLAN.md §4 Phase E.

local ADDON_NAME, ns = ...

local RecordsUI = {}
ns.RecordsUI = RecordsUI

-- Live filter + sort state (mirrors Records.GetBest's filter contract).
-- Defaults (season + this character + min level 2) are finalized in build(),
-- once player identity is available.
local filters = { seasonOnly = true, character = nil, minLevel = 2 }
local sortKey = "ooc"   -- "ooc" | "name"

local ROW_HEIGHT = 20

-- Row columns, relative to the scroll content (x, width).
local COL = {
	ann   = { x = 2,   w = 18 },
	name  = { x = 24,  w = 150 },
	ooc   = { x = 178, w = 50 },
	lvl   = { x = 232, w = 28 },
	char  = { x = 264, w = 88 },
	-- (right side reserved for a future "X:XX over <best holder>" comparison
	--  column, once the leaderboard/comms layer lands — see PLAN.md.)
}

-- Announce channels offered in the dropdown.
local CHANNELS = {
	{ "Party", "PARTY" },
	{ "Instance", "INSTANCE_CHAT" },
	{ "Guild", "GUILD" },
	{ "Say", "SAY" },
}
local function channelLabel(v)
	for _, c in ipairs(CHANNELS) do if c[2] == v then return c[1] end end
	return v
end

-- Created lazily on first open.
local window, scroll, content, emptyText, countText, channelDD
local rowPool = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function shortChar(c)
	return c and c:match("^[^-]+") or "?"
end

-- Apply a UI atlas if present, else a texture file (never blank).
local function setIcon(tex, atlas, file)
	if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		tex:SetAtlas(atlas)
	else
		tex:SetTexture(file)
	end
end

-- Collect the currently-filtered best runs, sorted.
local function gatherSorted()
	local best = ns.Records.GetBest(filters)
	local rows = {}
	for _, r in pairs(best) do rows[#rows + 1] = r end
	if sortKey == "name" then
		table.sort(rows, function(a, b) return a.dungeonName < b.dungeonName end)
	else
		table.sort(rows, function(a, b) return a.totalOOC < b.totalOOC end)
	end
	return rows
end

local function acquireRow(i)
	if rowPool[i] then return rowPool[i] end
	local row = CreateFrame("Frame", nil, content)
	row:SetHeight(ROW_HEIGHT)

	-- Per-row announce button.
	local ann = CreateFrame("Button", nil, row)
	ann:SetSize(COL.ann.w, COL.ann.w)
	ann:SetPoint("LEFT", COL.ann.x, 0)
	local aicon = ann:CreateTexture(nil, "ARTWORK")
	aicon:SetAllPoints()
	setIcon(aicon, "UI-HUD-MicroMenu-Communities-Up", "Interface\\Buttons\\UI-GuildButton-MOTD-Up")
	ann:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	ann:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Announce this record")
		GameTooltip:Show()
	end)
	ann:SetScript("OnLeave", function() GameTooltip:Hide() end)
	ann:SetScript("OnClick", function()
		if row.run then ns.SendAnnounce(ns.Records.FormatRecordAnnounce(row.run)) end
	end)
	row.ann = ann

	local function fs(col, font, color)
		local f = row:CreateFontString(nil, "ARTWORK", font)
		f:SetPoint("LEFT", COL[col].x, 0)
		f:SetWidth(COL[col].w)
		f:SetJustifyH("LEFT")
		f:SetWordWrap(false)
		if color then f:SetTextColor(unpack(color)) end
		return f
	end

	row.name  = fs("name", "GameFontHighlight")
	row.ooc   = fs("ooc",  "GameFontNormal", { 1, 0.82, 0 })
	row.lvl   = fs("lvl",  "GameFontHighlight")
	row.char  = fs("char", "GameFontDisable")

	rowPool[i] = row
	return row
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
function RecordsUI.Refresh()
	if not (window and window:IsShown()) then return end

	local rows = gatherSorted()
	for _, row in ipairs(rowPool) do row:Hide() end

	local cw = scroll:GetWidth()
	content:SetWidth(cw)

	for i, r in ipairs(rows) do
		local row = acquireRow(i)
		row.run = r
		row:SetWidth(cw)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row.name:SetText(r.dungeonName or ("Map " .. tostring(r.dungeonMapID)))
		row.ooc:SetText(ns.FormatTime(r.totalOOC))
		row.lvl:SetText("+" .. (r.keystoneLevel or 0))
		row.char:SetText(shortChar(r.character))
		row:Show()
	end

	content:SetHeight(math.max(#rows * ROW_HEIGHT, 1))
	emptyText:SetShown(#rows == 0)
	countText:SetText(("%d dungeon%s"):format(#rows, #rows == 1 and "" or "s"))
end

-- Announce every currently-filtered record to chat (capped to avoid spam).
function RecordsUI.AnnounceAll()
	local rows = gatherSorted()
	if #rows == 0 then
		ns.Print("no records match the current filters.")
		return
	end
	ns.SendAnnounce(("PressW — best out-of-combat times (%d):"):format(#rows))
	local cap = math.min(#rows, 15)
	for i = 1, cap do
		ns.SendAnnounce(ns.Records.FormatRecordAnnounce(rows[i]))
	end
	if #rows > cap then
		ns.Print(("announced top %d of %d (rest omitted to avoid spam)."):format(cap, #rows))
	end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
local function makeCheck(parent, label, x, y, getter, onChange)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetSize(24, 24)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
	cb.Sync = function() cb:SetChecked(getter()) end
	return cb
end

local function makeHeader(text, x, key)
	local b = CreateFrame("Button", nil, window)
	b:SetSize(COL.name.w, 16)
	b:SetPoint("TOPLEFT", x, -114)
	local fs = b:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetPoint("LEFT")
	fs:SetText(text)
	if key then
		b:SetScript("OnClick", function() sortKey = key; RecordsUI.Refresh() end)
	end
	return b
end

local seasonCB, charCB, lvlBox

local function syncControls()
	if seasonCB then seasonCB.Sync() end
	if charCB then charCB.Sync() end
	if lvlBox then lvlBox:SetText(tostring(filters.minLevel)) end
	if channelDD then UIDropDownMenu_SetText(channelDD, channelLabel(ns.db.settings.announceChannel)) end
end

local function build()
	-- Finalize filter defaults now that player identity is available.
	filters.character = ns.PlayerKey()

	window = CreateFrame("Frame", "PressWRecords", UIParent, "DefaultPanelTemplate")
	window:SetSize(480, 470)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	tinsert(UISpecialFrames, "PressWRecords")  -- closes on Escape

	if window.SetTitle then window:SetTitle("PressW M+ OOC Tracker - Records") end

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Filters row 1.
	seasonCB = makeCheck(window, "Current season", 16, -36,
		function() return filters.seasonOnly end,
		function(v) filters.seasonOnly = v; RecordsUI.Refresh() end)

	charCB = makeCheck(window, "This character", 170, -36,
		function() return filters.character ~= nil end,
		function(v) filters.character = v and ns.PlayerKey() or nil; RecordsUI.Refresh() end)

	-- Filters row 2: min level + announce channel.
	local lvlLabel = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	lvlLabel:SetPoint("TOPLEFT", 16, -66)
	lvlLabel:SetText("Min key level >=")

	lvlBox = CreateFrame("EditBox", nil, window, "InputBoxTemplate")
	lvlBox:SetSize(40, 20)
	lvlBox:SetPoint("LEFT", lvlLabel, "RIGHT", 10, 0)
	lvlBox:SetAutoFocus(false)
	lvlBox:SetNumeric(true)
	lvlBox:SetMaxLetters(3)
	local function commitLevel(self)
		filters.minLevel = tonumber(self:GetText()) or 0
		self:ClearFocus()
		RecordsUI.Refresh()
	end
	lvlBox:SetScript("OnEnterPressed", commitLevel)
	lvlBox:SetScript("OnEditFocusLost", commitLevel)

	local chLabel = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	chLabel:SetPoint("TOPLEFT", 210, -66)
	chLabel:SetText("Announce to")

	channelDD = CreateFrame("Frame", "PressWChannelDropdown", window, "UIDropDownMenuTemplate")
	channelDD:SetPoint("LEFT", chLabel, "RIGHT", -6, -2)
	UIDropDownMenu_SetWidth(channelDD, 90)
	UIDropDownMenu_Initialize(channelDD, function(_, level)
		for _, c in ipairs(CHANNELS) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = c[1]
			info.checked = (ns.db.settings.announceChannel == c[2])
			info.func = function()
				ns.db.settings.announceChannel = c[2]
				UIDropDownMenu_SetText(channelDD, c[1])
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	-- Announce all.
	local announceAll = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	announceAll:SetSize(110, 22)
	announceAll:SetPoint("TOPLEFT", 16, -90)
	announceAll:SetText("Announce all")
	announceAll:SetScript("OnClick", RecordsUI.AnnounceAll)

	-- Column headers (Dungeon / OOC sortable).
	makeHeader("Dungeon", 16 + COL.name.x, "name")
	makeHeader("OOC", 16 + COL.ooc.x, "ooc")
	makeHeader("Lvl", 16 + COL.lvl.x, nil)
	makeHeader("Character", 16 + COL.char.x, nil)

	-- Scrolling list.
	scroll = CreateFrame("ScrollFrame", "PressWRecordsScroll", window, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -134)
	scroll:SetPoint("BOTTOMRIGHT", -30, 34)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(scroll:GetWidth(), 1)
	scroll:SetScrollChild(content)

	emptyText = window:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	emptyText:SetPoint("CENTER", scroll, "CENTER")
	emptyText:SetText("No records match these filters.")
	emptyText:Hide()

	countText = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	countText:SetPoint("BOTTOMLEFT", 16, 12)
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------
function RecordsUI.Toggle()
	if not window then build() end
	if window:IsShown() then
		window:Hide()
	else
		if ns.Options and ns.Options.Hide then ns.Options.Hide() end  -- mutually exclusive
		syncControls()
		window:Show()
		RecordsUI.Refresh()
	end
end

function RecordsUI.Hide()
	if window then window:Hide() end
end
