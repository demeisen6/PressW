-- PressW — Options.lua
-- M6: a standalone settings window. See PLAN.md §4 Phase F.
--
-- We use our own window rather than the Blizzard Settings panel: opening that
-- panel programmatically and closing it with Escape falls through to the game
-- menu. A standalone frame in UISpecialFrames closes cleanly on Escape, and we
-- need color swatches the data-driven Settings list doesn't offer anyway.

local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

local window
local syncers = {}   -- functions that push current DB values into the controls

--------------------------------------------------------------------------------
-- Apply changes to the live HUD
--------------------------------------------------------------------------------
local function apply()
	if ns.Display then
		ns.Display.SetScale(ns.db.settings.scale)
		ns.Display.Refresh()
	end
end

--------------------------------------------------------------------------------
-- Color picker
--------------------------------------------------------------------------------
local function openColorPicker(r, g, b, callback)
	local info = {
		hasOpacity = false,
		r = r, g = g, b = b,
		swatchFunc = function() callback(ColorPickerFrame:GetColorRGB()) end,
		cancelFunc = function() callback(r, g, b) end,  -- restore originals
	}
	ColorPickerFrame:SetupColorPickerAndShow(info)
end

--------------------------------------------------------------------------------
-- Widget builders (parented to the options window)
--------------------------------------------------------------------------------
local function addCheckbox(parent, label, y, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", 24, y)
	cb:SetSize(26, 26)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	syncers[#syncers + 1] = function() cb:SetChecked(get()) end
	return cb
end

local function addSlider(parent, label, y, minV, maxV, stepV, get, set, fmt)
	local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
	s:SetPoint("TOPLEFT", 28, y - 16)
	s:SetWidth(240)
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(stepV)
	s:SetObeyStepOnDrag(true)
	if s.Low then s.Low:SetText("") end
	if s.High then s.High:SetText("") end
	if s.Text then s.Text:SetText("") end

	local lab = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	lab:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
	lab:SetText(label)

	local val = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	val:SetPoint("LEFT", s, "RIGHT", 8, 0)

	local function setText(v)
		val:SetText(fmt and fmt(v) or tostring(math.floor(v + 0.5)))
	end

	s:SetScript("OnValueChanged", function(_, value)
		if stepV >= 1 then value = math.floor(value + 0.5) end
		set(value)
		setText(value)
	end)

	syncers[#syncers + 1] = function() s:SetValue(get()); setText(get()) end
	return s
end

local function addColorSwatch(parent, tooltip, x, y, key)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(22, 22)
	btn:SetPoint("TOPLEFT", x, y)

	local border = btn:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0, 0, 0)

	local tex = btn:CreateTexture(nil, "ARTWORK")
	tex:SetAllPoints()

	local function refresh()
		local c = ns.db.settings.escalation[key]
		tex:SetColorTexture(c[1], c[2], c[3])
	end

	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(tooltip)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	btn:SetScript("OnClick", function()
		local c = ns.db.settings.escalation[key]
		openColorPicker(c[1], c[2], c[3], function(r, g, b)
			c[1], c[2], c[3] = r, g, b
			refresh()
		end)
	end)

	syncers[#syncers + 1] = refresh
	return btn
end

--------------------------------------------------------------------------------
-- Build the standalone settings window
--------------------------------------------------------------------------------
function Options.Init()
	if window then return end

	window = CreateFrame("Frame", "PressWOptions", UIParent, "DefaultPanelTemplate")
	window:SetSize(360, 500)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	window:Hide()
	tinsert(UISpecialFrames, "PressWOptions")  -- closes cleanly on Escape

	if window.SetTitle then window:SetTitle("PressW M+ OOC Tracker - Settings") end

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local y = -40
	local function step(dy) local cur = y; y = y - dy; return cur end

	addCheckbox(window, "Lock HUD (hide preview & buttons)", step(28),
		function() return ns.db.settings.locked end,
		function(v) ns.db.settings.locked = v; apply() end)

	addCheckbox(window, "Show running total during combat", step(28),
		function() return ns.db.settings.showInCombat end,
		function(v) ns.db.settings.showInCombat = v; apply() end)

	addCheckbox(window, "Announce result to chat on M+ completion", step(28),
		function() return ns.db.settings.announceMythicPlus end,
		function(v) ns.db.settings.announceMythicPlus = v end)

	addCheckbox(window, "Announce result to chat on manual run", step(34),
		function() return ns.db.settings.announceManual end,
		function(v) ns.db.settings.announceManual = v end)

	addSlider(window, "HUD scale", step(50), 0.5, 2.0, 0.05,
		function() return ns.db.settings.scale end,
		function(v) ns.db.settings.scale = v; apply() end,
		function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end)

	addSlider(window, "Minimum font size", step(50), 8, 40, 1,
		function() return ns.db.settings.escalation.sizeMin end,
		function(v) ns.db.settings.escalation.sizeMin = v end)

	addSlider(window, "Maximum font size", step(50), 16, 72, 1,
		function() return ns.db.settings.escalation.sizeMax end,
		function(v) ns.db.settings.escalation.sizeMax = v end)

	addSlider(window, "Escalation ramp (seconds)", step(50), 2, 60, 1,
		function() return ns.db.settings.escalation.ramp end,
		function(v) ns.db.settings.escalation.ramp = v end)

	addSlider(window, "Minimum key level to record", step(50), 0, 30, 1,
		function() return ns.db.settings.minKeyLevelForRecords end,
		function(v) ns.db.settings.minKeyLevelForRecords = v end)

	-- Escalation colors on one row.
	local cy = step(38)
	local clabel = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	clabel:SetPoint("TOPLEFT", 24, cy)
	clabel:SetText("Escalation colors:")
	addColorSwatch(window, "Start (just left combat)", 170, cy + 4, "colorStart")
	addColorSwatch(window, "Midpoint", 200, cy + 4, "colorMid")
	addColorSwatch(window, "End (max downtime)", 230, cy + 4, "colorEnd")

	-- Reset records.
	local reset = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	reset:SetSize(150, 22)
	reset:SetPoint("TOPLEFT", 24, step(44))
	reset:SetText("Reset all records")
	reset:SetScript("OnClick", function() StaticPopup_Show("PRESSW_RESET_RECORDS") end)

	window:SetScript("OnShow", function()
		for _, f in ipairs(syncers) do f() end
	end)
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------
function Options.Open()
	if not window then Options.Init() end
	if ns.RecordsUI and ns.RecordsUI.Hide then ns.RecordsUI.Hide() end  -- mutually exclusive
	window:Show()
end

function Options.Hide()
	if window then window:Hide() end
end

function Options.Toggle()
	if not window then Options.Init() end
	if window:IsShown() then window:Hide() else Options.Open() end
end

--------------------------------------------------------------------------------
-- Reset confirmation
--------------------------------------------------------------------------------
StaticPopupDialogs["PRESSW_RESET_RECORDS"] = {
	text = "Delete ALL PressW records? This cannot be undone.",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		wipe(ns.db.runs)
		ns.Print("all records cleared.")
		if ns.RecordsUI and ns.RecordsUI.Refresh then ns.RecordsUI.Refresh() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
}
