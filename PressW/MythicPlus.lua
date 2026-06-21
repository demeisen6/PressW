-- PressW — MythicPlus.lua
-- M4: drive the tracker from real Challenge Mode (Mythic+) events and route a
-- completed key into Records.SaveRun. See PLAN.md §4 (integrate Phase B with M+).
--
-- Lifecycle:
--   CHALLENGE_MODE_START      -> capture meta, start tracking
--   CHALLENGE_MODE_COMPLETED  -> read completion info, stop, save the run
--   CHALLENGE_MODE_RESET      -> discard the in-progress run (never saved)
--   PLAYER_ENTERING_WORLD     -> best-effort resume if a key is already active
--                                (e.g. after /reload mid-key)

local ADDON_NAME, ns = ...

local MythicPlus = {}
ns.MythicPlus = MythicPlus

-- Metadata for the currently tracked key (mapID/name/par/level/affixes/season).
local activeMeta = nil

--------------------------------------------------------------------------------
-- Metadata gathering
--------------------------------------------------------------------------------
local function gatherMeta()
	if not (C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID) then return nil end
	local mapID = C_ChallengeMode.GetActiveChallengeMapID()
	if not mapID then return nil end

	local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
	local level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()

	return {
		mapID     = mapID,
		name      = name or ("Dungeon " .. mapID),
		timeLimit = timeLimit,                 -- dungeon par/goal, seconds
		level     = level,
		affixIDs  = affixes,
		seasonID  = ns.GetCurrentSeason and ns.GetCurrentSeason() or 0,
	}
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
local function beginRun(meta)
	-- If anything (a manual run) was tracking, drop it — the key takes over.
	if ns.Tracker.IsRunning() then ns.Tracker.Stop() end
	activeMeta = meta
	ns.Tracker.Start("mythicplus", meta)
end

local function onStart()
	local meta = gatherMeta()
	if meta then
		beginRun(meta)
		return
	end
	-- Keystone info occasionally lags the event by a frame; retry briefly.
	local tries = 0
	local function attempt()
		tries = tries + 1
		local m = gatherMeta()
		if m then
			beginRun(m)
		elseif tries < 5 then
			C_Timer.After(0.3, attempt)
		end
	end
	C_Timer.After(0.3, attempt)
end

local function onCompleted()
	if not ns.Tracker.IsRunning() then return end

	local info = C_ChallengeMode and C_ChallengeMode.GetCompletionInfo
		and { C_ChallengeMode.GetCompletionInfo() } or {}
	-- Returns: mapChallengeModeID, level, time(ms), onTime, keystoneUpgradeLevels, ...
	local level    = info[2]
	local timeMs   = info[3]
	local onTime   = info[4]
	local tier     = info[5] or 0

	local meta = activeMeta or {}
	local summary = ns.Tracker.Stop()  -- finalizes OOC segments
	if not summary then return end

	local run = ns.Records.SaveRun({
		dungeonMapID   = meta.mapID,
		dungeonName    = meta.name,
		keystoneLevel  = level or meta.level,
		affixIDs       = meta.affixIDs,
		seasonID       = meta.seasonID,
		totalOOC       = summary.totalOOC,
		segmentCount   = summary.segmentCount,
		longestSegment = summary.longestSegment,
		runDuration    = timeMs and (timeMs / 1000) or summary.runDuration,
		goalTime       = meta.timeLimit,
		onTime         = onTime,
		achievedTier   = tier,
	})

	if ns.db.settings.announceMythicPlus then
		ns.SendAnnounce(ns.Records.FormatRunAnnounce(run))
	end

	activeMeta = nil
end

local function onReset()
	-- Key abandoned/restarted: discard the live run without saving.
	if ns.Tracker.IsRunning() then ns.Tracker.Stop() end
	activeMeta = nil
end

-- After a /reload or zone-in, pick up a key that's already in progress. We can't
-- recover OOC time accrued before the reload, so this restarts the count from
-- now (a known limitation; persisting live state across reload is future work).
local function onEnteringWorld()
	if ns.Tracker.IsRunning() then return end
	if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID
		and C_ChallengeMode.GetActiveChallengeMapID() then
		local meta = gatherMeta()
		if meta then
			beginRun(meta)
			ns.Print("rejoined an in-progress key — OOC tracking resumed (pre-reload time not counted).")
		end
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("CHALLENGE_MODE_START")
events:RegisterEvent("CHALLENGE_MODE_COMPLETED")
events:RegisterEvent("CHALLENGE_MODE_RESET")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

events:SetScript("OnEvent", function(_, event)
	if event == "CHALLENGE_MODE_START" then
		onStart()
	elseif event == "CHALLENGE_MODE_COMPLETED" then
		onCompleted()
	elseif event == "CHALLENGE_MODE_RESET" then
		onReset()
	elseif event == "PLAYER_ENTERING_WORLD" then
		onEnteringWorld()
	end
end)
