-- PressW — Display.lua
-- M2: the live on-screen HUD. See PLAN.md §4 Phase C.
--
-- Two lines:
--   * Total OOC   — the running total for the whole run (steady size).
--   * Current     — the live open-segment timer that grows larger and shifts
--                   green -> yellow -> red the longer you stand out of combat.
--
-- Visibility:
--   * While a run is active: frame shown. The current line appears only while
--     out of combat; the total line respects settings.showInCombat.
--   * No run + unlocked: a draggable preview is shown so the user can position
--     it. No run + locked: hidden.

local ADDON_NAME, ns = ...

local Display = {}
ns.Display = Display

local UPDATE_INTERVAL = 0.1   -- seconds between HUD refreshes (~10/sec)
local FONT = STANDARD_TEXT_FONT

--------------------------------------------------------------------------------
-- Math helpers
--------------------------------------------------------------------------------
local function lerp(a, b, t) return a + (b - a) * t end

local function lerpColor(c1, c2, t)
	return lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t), lerp(c1[3], c2[3], t)
end

-- Map the current-segment length to a font size and color using the user's
-- escalation settings. `t` ramps 0->1 over `ramp` seconds, then clamps. Size and
-- color are eased independently: t^sizeCurve and t^colorCurve (1 = linear). A
-- larger sizeCurve keeps the text small early and accelerates near the end.
local function escalate(seconds, esc)
	local t = (esc.ramp > 0) and math.min(seconds / esc.ramp, 1) or 1
	local ts = t ^ (esc.sizeCurve or 1)
	local tc = t ^ (esc.colorCurve or 1)
	local size = lerp(esc.sizeMin, esc.sizeMax, ts)
	local r, g, b
	if tc < 0.5 then
		r, g, b = lerpColor(esc.colorStart, esc.colorMid, tc * 2)
	else
		r, g, b = lerpColor(esc.colorMid, esc.colorEnd, (tc - 0.5) * 2)
	end
	return size, r, g, b
end

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------
local frame = CreateFrame("Frame", "PressWHUD", UIParent)
frame:SetSize(200, 80)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)  -- replaced by saved point in Init()
frame:SetClampedToScreen(true)
frame:Hide()
ns.Display.frame = frame

-- Subtle background, only visible while unlocked so the drag region is obvious.
local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.35)
bg:Hide()

local total = frame:CreateFontString(nil, "ARTWORK")
total:SetFont(FONT, 12, "OUTLINE")
total:SetPoint("TOP", frame, "TOP", 0, -4)
total:SetTextColor(0.9, 0.9, 0.9)

local current = frame:CreateFontString(nil, "ARTWORK")
current:SetFont(FONT, 24, "OUTLINE")
current:SetPoint("TOP", total, "BOTTOM", 0, -2)

--------------------------------------------------------------------------------
-- Config buttons (shown only while unlocked, hidden during normal play)
--------------------------------------------------------------------------------
-- Apply a UI atlas if this client has it; otherwise fall back to a texture file.
local function setIcon(tex, atlas, file)
	if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		tex:SetAtlas(atlas)
	else
		tex:SetTexture(file)
	end
end

-- Small icon button (clean atlas icon, transparent) with a hover tooltip.
local function makeIconButton(atlas, file, tooltip, onClick)
	local b = CreateFrame("Button", nil, frame)
	b:SetSize(18, 18)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	setIcon(icon, atlas, file)
	b:SetNormalTexture(icon)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(tooltip)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local recordsBtn = makeIconButton(
	"UI-HUD-MicroMenu-Questlog-Up",                  -- modern book/log icon
	"Interface\\Buttons\\UI-GuildButton-MOTD-Up",    -- fallback
	"PressW Records",
	function() if ns.RecordsUI then ns.RecordsUI.Toggle() end end)
recordsBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)

local settingsBtn = makeIconButton(
	"GM-icon-settings",                              -- modern gear icon
	"Interface\\Buttons\\UI-OptionsButton",          -- fallback
	"PressW Settings",
	function()
		if ns.Options and ns.Options.Toggle then
			ns.Options.Toggle()
		end
	end)
settingsBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

-- Lock toggle. Unlike the records/settings buttons it is NOT hidden while
-- locked (so the HUD can be unlocked again); instead its visibility is driven
-- by the update loop so it only appears alongside the "OOC:" line. Sits just to
-- the left of the settings cog.
local lockBtn = CreateFrame("Button", nil, frame)
lockBtn:SetSize(18, 18)
local lockIcon = lockBtn:CreateTexture(nil, "ARTWORK")
lockIcon:SetAllPoints()
lockBtn:SetNormalTexture(lockIcon)
lockBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
lockBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -2, 0)
lockBtn:SetScript("OnClick", function()
	ns.Display.SetLocked(not (ns.db and ns.db.settings.locked))
end)
lockBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText((ns.db and ns.db.settings.locked) and "Unlock HUD" or "Lock HUD")
	GameTooltip:Show()
end)
lockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function updateLockIcon()
	local locked = ns.db and ns.db.settings.locked
	lockIcon:SetTexture(locked
		and "Interface\\Buttons\\LockButton-Locked-Up"
		or "Interface\\Buttons\\LockButton-Unlocked-Up")
end

--------------------------------------------------------------------------------
-- Position & scale
--------------------------------------------------------------------------------
-- We anchor the frame by its TOP (top-center) to UIParent's BOTTOMLEFT, storing
-- the top-center location in UIParent coordinates (independent of the HUD's own
-- scale). This way changing the scale grows/shrinks the frame around its
-- top-center, which stays put on screen, instead of drifting toward an edge.

local function savePosition()
	if not ns.db then return end
	local s = frame:GetEffectiveScale()
	local ui = UIParent:GetEffectiveScale()
	local cx = ((frame:GetLeft() + frame:GetRight()) / 2) * s / ui
	local ty = frame:GetTop() * s / ui
	ns.db.settings.point = { cx, ty }
end

local function applyPosition()
	local scale = ns.db.settings.scale or 1
	frame:SetScale(scale)

	local p = ns.db.settings.point
	-- Migrate the legacy { anchor, x, y } format (or initialize) by placing the
	-- frame with the old anchor (or a default), then capturing top-center coords.
	if type(p) ~= "table" or type(p[1]) == "string" or not p[2] then
		frame:ClearAllPoints()
		if type(p) == "table" and type(p[1]) == "string" then
			frame:SetPoint(p[1], UIParent, p[1], p[2] or 0, p[3] or 0)
		else
			frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
		end
		savePosition()
		p = ns.db.settings.point
	end

	frame:ClearAllPoints()
	frame:SetPoint("TOP", UIParent, "BOTTOMLEFT", p[1] / scale, p[2] / scale)
end

--------------------------------------------------------------------------------
-- Dragging
--------------------------------------------------------------------------------
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	savePosition()
	applyPosition()  -- normalize to our top-anchored scheme
end)

-- Reflect the lock state: when unlocked the frame is mouse-interactive and shows
-- its background so it can be grabbed.
local function applyLock()
	local locked = ns.db and ns.db.settings.locked
	frame:EnableMouse(not locked)
	if locked then
		bg:Hide(); recordsBtn:Hide(); settingsBtn:Hide()
	else
		bg:Show(); recordsBtn:Show(); settingsBtn:Show()
	end
end

--------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------
-- Show whenever a run is active, or when unlocked (so it can be positioned).
local function shouldShow()
	if ns.Tracker and ns.Tracker.IsRunning() then return true end
	return not (ns.db and ns.db.settings.locked)
end

function Display.Refresh()
	applyLock()
	if shouldShow() then frame:Show() else frame:Hide() end
end

--------------------------------------------------------------------------------
-- Per-frame update (only runs while the frame is shown)
--------------------------------------------------------------------------------
local accum = 0
frame:SetScript("OnUpdate", function(self, elapsed)
	accum = accum + elapsed
	if accum < UPDATE_INTERVAL then return end
	accum = 0

	local esc = ns.db and ns.db.settings.escalation or ns.defaults.settings.escalation
	local showInCombat = not ns.db or ns.db.settings.showInCombat

	if ns.Tracker and ns.Tracker.IsRunning() then
		local totalOOC, curSeg, inCombat, runElapsed = ns.Tracker.GetLive()

		-- Total line: OOC time / total run time. Hidden in combat unless opted in.
		-- The lock toggle tracks the total line's visibility.
		if inCombat and not showInCombat then
			total:SetText("")
			lockBtn:Hide()
		else
			total:SetText(("OOC: %s / %s"):format(ns.FormatTime(totalOOC), ns.FormatTime(runElapsed)))
			updateLockIcon()
			lockBtn:Show()
		end

		-- Current line: only while out of combat, with escalation.
		if inCombat then
			current:SetText("")
		else
			local size, r, g, b = escalate(curSeg, esc)
			current:SetFont(FONT, size, "OUTLINE")
			current:SetTextColor(r, g, b)
			current:SetText(ns.FormatTime(curSeg))
		end
	else
		-- Preview while unlocked and idle.
		total:SetText("OOC: 0:00 / 0:00")
		updateLockIcon()
		lockBtn:Show()
		local size, r, g, b = escalate(0, esc)
		current:SetFont(FONT, size, "OUTLINE")
		current:SetTextColor(r, g, b)
		current:SetText("0:00")
	end
end)

--------------------------------------------------------------------------------
-- Hooks called by Core / Tracker
--------------------------------------------------------------------------------

-- Called by Core once SavedVariables are ready.
function Display.Init()
	applyPosition()
	Display.Refresh()
end

-- Scale the whole HUD (frame + text + buttons scale together, staying
-- proportional) around its top-center. Used by the Options panel.
function Display.SetScale(scale)
	if scale and ns.db then ns.db.settings.scale = scale end
	applyPosition()
end

-- Called by Tracker on Start/Stop.
function Display.OnRunStart()
	accum = UPDATE_INTERVAL  -- force an immediate refresh on next tick
	Display.Refresh()
end

function Display.OnRunStop()
	total:SetText("")
	current:SetText("")
	Display.Refresh()
end

-- Used later by the Options panel (M6); exposed now for completeness.
function Display.SetLocked(locked)
	if ns.db then ns.db.settings.locked = locked and true or false end
	Display.Refresh()
end
