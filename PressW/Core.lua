-- PressW — Core.lua
-- M0 skeleton: shared namespace, SavedVariables init, event frame, slash commands.
-- See PLAN.md §4 Phase A.

-- WoW passes every addon file two args: the addon's folder name and a private
-- table shared across all files in this addon. We use `ns` as the namespace.
local ADDON_NAME, ns = ...

-- Make a couple of bits available to other files as we add them.
ns.name = ADDON_NAME
ns.version = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "0.0.1"

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------
-- These mirror the data model in PLAN.md §3. On first load (or when a key is
-- missing after an update) we deep-fill from here so older saved data keeps
-- working without wiping the user's records.
ns.defaults = {
	settings = {
		locked = false,                  -- frame drag lock
		showInCombat = true,             -- show running total during combat?
		scale = 1.0,                     -- HUD scale (scales frame + all text proportionally)
		point = { "CENTER", 0, 200 },    -- saved frame position
		escalation = {
			sizeMin = 14, sizeMax = 72,
			ramp = 10,                   -- seconds over which size/color ramps to max
			sizeCurve = 3,               -- size easing exponent (1 = linear; higher = slower start)
			colorCurve = 1,              -- color easing exponent (1 = linear)
			colorStart = { 0, 1, 0 },    -- green
			colorMid   = { 1, 1, 0 },    -- yellow
			colorEnd   = { 1, 0, 0 },    -- red
		},
		minKeyLevelForRecords = 2,       -- ignore runs below this for records
		announceMythicPlus = true,       -- announce result to chat when an M+ key completes
		announceManual = false,          -- announce result to chat when a manual run ends
		announceChannel = "PARTY",       -- where announcements go (PARTY/GUILD/INSTANCE_CHAT/SAY)
	},
	runs = {},                           -- only COMPLETED runs are appended here
}

-- Recursively copy any missing keys from `src` into `dst`. Existing values in
-- `dst` (the user's saved data) are never overwritten.
local function applyDefaults(dst, src)
	if type(dst) ~= "table" then dst = {} end
	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = applyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end

--------------------------------------------------------------------------------
-- Output helpers
--------------------------------------------------------------------------------
local PREFIX = "|cff33ff99PressW|r: "

function ns.Print(...)
	print(PREFIX .. strjoin(" ", tostringall(...)))
end

-- Format a duration in seconds as M:SS (e.g. 142.6 -> "2:23"). Used by the
-- tracker summary and (later) the live display and records UI.
function ns.FormatTime(seconds)
	seconds = math.max(0, math.floor((seconds or 0) + 0.5))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Is a chat channel usable right now?
local function canUseChannel(channel)
	if channel == "PARTY" then return IsInGroup()
	elseif channel == "RAID" then return IsInRaid()
	elseif channel == "INSTANCE_CHAT" then return IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
	elseif channel == "GUILD" then return IsInGuild()
	elseif channel == "SAY" then return true end
	return false
end

-- Send an announcement to a chat channel, falling back to a local print when
-- the chosen channel isn't available (e.g. announcing a record while solo).
function ns.SendAnnounce(text, channel)
	channel = channel or (ns.db and ns.db.settings.announceChannel) or "PARTY"
	if canUseChannel(channel) then
		SendChatMessage(text, channel)
	else
		ns.Print("(not in " .. channel:lower() .. ", shown locally) " .. text)
	end
end

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.frame = frame

frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		local loaded = ...
		if loaded ~= ADDON_NAME then return end

		-- Initialize / migrate SavedVariables.
		PressWDB = applyDefaults(PressWDB or {}, ns.defaults)
		ns.db = PressWDB

		-- Bring up modules that need the DB.
		if ns.Display and ns.Display.Init then ns.Display.Init() end
		if ns.Options and ns.Options.Init then ns.Options.Init() end

		ns.Print("v" .. ns.version .. " loaded. Type |cffffff00/ooc|r for commands.")

		-- We only needed ADDON_LOADED for one-time setup.
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
SLASH_PRESSW1 = "/pressw"
SLASH_PRESSW2 = "/ooc"

local function printHelp()
	ns.Print("commands:")
	print("  |cffffff00/ooc|r — show this help")
	print("  |cffffff00/ooc start|r — begin a manual tracking run (testing / non-key)")
	print("  |cffffff00/ooc stop|r — end the manual run and print the summary")
	print("  |cffffff00/ooc lock|r — toggle the HUD lock (unlocked = draggable preview)")
	print("  |cffffff00/ooc records|r — open the records browser")
	print("  |cffffff00/ooc options|r — open the settings window")
	print("  |cffffff00/ooc version|r — show the loaded version")
end

-- Print the summary returned by Tracker.Stop().
local function printSummary(s)
	ns.Print(string.format(
		"run ended — total OOC |cffffff00%s|r across %d segment%s (longest %s) over a %s run.",
		ns.FormatTime(s.totalOOC),
		s.segmentCount, s.segmentCount == 1 and "" or "s",
		ns.FormatTime(s.longestSegment),
		ns.FormatTime(s.runDuration)
	))
end

SlashCmdList["PRESSW"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

	if msg == "" then
		-- If the HUD is locked and idle it's completely hidden (no unlock button),
		-- so a bare /pressw is the escape hatch to unlock it. Otherwise: help.
		if ns.db and ns.db.settings.locked and not (ns.Tracker and ns.Tracker.IsRunning()) then
			ns.Display.SetLocked(false)
			ns.Print("HUD unlocked — drag it to reposition, then lock it again.")
		else
			printHelp()
		end
	elseif msg == "help" then
		printHelp()
	elseif msg == "version" then
		ns.Print("version " .. ns.version)
	elseif msg == "start" then
		if ns.Tracker.Start("manual") then
			ns.Print("manual run started. Walk in/out of combat to test, then |cffffff00/ooc stop|r.")
		end
	elseif msg == "stop" then
		local s = ns.Tracker.Stop()
		if s then
			printSummary(s)
			if ns.db.settings.announceManual then
				ns.SendAnnounce(("PressW (manual): %s out of combat over a %s run."):format(
					ns.FormatTime(s.totalOOC), ns.FormatTime(s.runDuration)))
			end
		else
			ns.Print("no run is being tracked.")
		end
	elseif msg == "lock" then
		local locked = not (ns.db and ns.db.settings.locked)
		ns.Display.SetLocked(locked)
		ns.Print("HUD " .. (locked and "locked." or "unlocked — drag the preview to move it."))
	elseif msg == "records" then
		ns.RecordsUI.Toggle()
	elseif msg == "options" or msg == "config" then
		ns.Options.Toggle()
	elseif msg == "savetest" then
		ns.Records.DebugSaveTest()
	elseif msg == "dump" then
		-- Debug: show current season + every stored run's key fields so we can see
		-- why a filter hides a record. (Temporary; removed before release.)
		ns.Print("currentSeason() = |cffffff00" .. tostring(ns.GetCurrentSeason and ns.GetCurrentSeason()) ..
			"|r ; you are |cffffff00" .. tostring(ns.PlayerKey and ns.PlayerKey()) .. "|r")
		ns.Print((#ns.db.runs) .. " stored run(s):")
		for i, r in ipairs(ns.db.runs) do
			print(("  %d) %s | season=%s | +%s | OOC %s | %s"):format(
				i, tostring(r.dungeonName), tostring(r.seasonID), tostring(r.keystoneLevel),
				ns.FormatTime(r.totalOOC), tostring(r.character)))
		end
	else
		ns.Print("unknown command '" .. msg .. "'. Type |cffffff00/ooc|r for help.")
	end
end
