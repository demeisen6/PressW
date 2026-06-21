-- PressW — MythicPlus.lua
-- M4: drive the tracker from real Challenge Mode (Mythic+) events and route a
-- completed key into Records.SaveRun. See PLAN.md §4 (integrate Phase B with M+).
--
-- Lifecycle:
--   CHALLENGE_MODE_START      -> capture meta; wait out the gate countdown
--   START_TIMER               -> gate countdown duration; start tracking when it ends
--   CHALLENGE_MODE_COMPLETED  -> read official time, stop, save the run
--   CHALLENGE_MODE_RESET      -> cancel pending start / discard the run (never saved)
--   PLAYER_ENTERING_WORLD     -> best-effort resume if a key is already active
--                                (e.g. after /reload mid-key)

local ADDON_NAME, ns = ...

local MythicPlus = {}
ns.MythicPlus = MythicPlus

-- Metadata for the currently tracked key (mapID/name/par/level/affixes/season).
local activeMeta = nil

-- Between CHALLENGE_MODE_START and the gate dropping there's a countdown during
-- which the player is stuck behind the barrier (and thus "out of combat"). We do
-- NOT start tracking until that countdown ends, so it isn't counted as avoidable
-- downtime and our run time lines up with the official keystone timer.
-- `awaitingStart`/`startToken` guard the scheduled start against resets.
local awaitingStart = false
local startToken = 0
local pendingCountdown = nil   -- set if START_TIMER arrives before CHALLENGE_MODE_START

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
	meta = meta or activeMeta or gatherMeta()
	if not meta then return end
	if ns.Tracker.IsRunning() then ns.Tracker.Stop() end  -- a manual run yields to the key
	activeMeta = meta
	awaitingStart = false
	ns.Tracker.Start("mythicplus", meta)
end

-- Begin tracking now, unless this scheduled call was superseded (token changed),
-- already handled/cancelled (awaitingStart false), or the key is gone.
local function tryStart(token)
	if token ~= startToken or not awaitingStart then return end
	if not (C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID
		and C_ChallengeMode.GetActiveChallengeMapID()) then return end
	beginRun()
end

local function onChallengeStart()
	startToken = startToken + 1
	local token = startToken
	awaitingStart = true

	-- Capture meta now; keystone info can lag the event by a frame, so retry.
	activeMeta = gatherMeta()
	if not activeMeta then
		local tries = 0
		local function grab()
			tries = tries + 1
			activeMeta = gatherMeta()
			if not activeMeta and tries < 5 then C_Timer.After(0.3, grab) end
		end
		C_Timer.After(0.3, grab)
	end

	-- Wait out the gate countdown before tracking. START_TIMER gives the exact
	-- duration; if it already arrived, use it. Always set a safety-net fallback
	-- (~typical countdown) in case START_TIMER never reports.
	if pendingCountdown then
		C_Timer.After(pendingCountdown, function() tryStart(token) end)
		pendingCountdown = nil
	end
	C_Timer.After(12, function() tryStart(token) end)
end

-- START_TIMER fires with the gate countdown when a key begins. Schedule tracking
-- to start when it ends; handles either event order relative to CHALLENGE_MODE_START.
local function onStartTimer(timerType, timeSeconds)
	local cmType = Enum and Enum.StartTimerType and Enum.StartTimerType.ChallengeModeCountdown
	local isChallenge = (cmType ~= nil and timerType == cmType)
	if awaitingStart then
		-- Accept the challenge countdown, or any countdown if we can't identify the
		-- type (we're already gated to the key-start window, so it's safe).
		if isChallenge or cmType == nil then
			local token = startToken
			C_Timer.After(timeSeconds or 0, function() tryStart(token) end)
		end
	elseif isChallenge then
		pendingCountdown = timeSeconds  -- arrived before CHALLENGE_MODE_START
	end
end

-- Pull the official run time (ms) from GetCompletionInfo. Robust to two quirks:
-- the function is often empty for a moment after the event fires (so the caller
-- retries), and its return order has shifted across patches (so we take the
-- documented index 3, then fall back to scanning for the one value large enough
-- to be a run time in ms — scores and levels are far smaller).
local function readOfficialTimeMs()
	if not (C_ChallengeMode and C_ChallengeMode.GetCompletionInfo) then return nil end
	local r = { C_ChallengeMode.GetCompletionInfo() }
	if type(r[3]) == "number" and r[3] > 1000 then return r[3] end
	for _, v in ipairs(r) do
		if type(v) == "number" and v > 60000 then return v end  -- > 1 min in ms
	end
	return nil
end

local function onCompleted()
	if not ns.Tracker.IsRunning() then return end

	-- Stop tracking immediately so OOC segments end at completion, not after the
	-- poll delay below. Identity/par come from the keystone info captured at start.
	local summary = ns.Tracker.Stop()
	if not summary then return end
	local meta = activeMeta or {}
	activeMeta = nil

	local function finalize(timeMs)
		local par = meta.timeLimit
		-- Prefer the official keystone time; our GetTime() wall-clock runs a few
		-- seconds long (it starts at keystone activation, before the timer).
		local elapsed = timeMs and (timeMs / 1000) or summary.runDuration
		local tier = ns.Records.TierForTime(elapsed, par)
		local onTime = (par and par > 0) and (elapsed <= par) or (tier >= 1)

		local run = ns.Records.SaveRun({
			dungeonMapID   = meta.mapID,
			dungeonName    = meta.name,
			keystoneLevel  = meta.level,
			affixIDs       = meta.affixIDs,
			seasonID       = meta.seasonID,
			totalOOC       = summary.totalOOC,
			segmentCount   = summary.segmentCount,
			longestSegment = summary.longestSegment,
			runDuration    = elapsed,
			goalTime       = par,
			onTime         = onTime,
			achievedTier   = tier,
		})

		if ns.db.settings.announceMythicPlus then
			ns.SendAnnounce(ns.Records.FormatRunAnnounce(run))
		end
	end

	-- GetCompletionInfo may be empty for a moment after the event; poll ~2s.
	local tries = 0
	local function attempt()
		tries = tries + 1
		local timeMs = readOfficialTimeMs()
		if timeMs or tries >= 8 then
			finalize(timeMs)
		else
			C_Timer.After(0.25, attempt)
		end
	end
	attempt()
end

local function onReset()
	-- Key abandoned/restarted: cancel any pending start and discard the live run.
	awaitingStart = false
	startToken = startToken + 1   -- invalidate scheduled tryStart callbacks
	pendingCountdown = nil
	if ns.Tracker.IsRunning() then ns.Tracker.Stop() end
	activeMeta = nil
end

-- After a /reload or zone-in, pick up a key that's already in progress. We can't
-- recover OOC time accrued before the reload, so this restarts the count from
-- now (a known limitation; persisting live state across reload is future work).
local function onEnteringWorld()
	-- Prime M+ seasonal data so C_MythicPlus.GetCurrentSeason() works in town
	-- (it returns -1 until this loads), keeping the records season filter accurate.
	if C_MythicPlus then
		if C_MythicPlus.RequestCurrentAffixes then C_MythicPlus.RequestCurrentAffixes() end
		if C_MythicPlus.RequestMapInfo then C_MythicPlus.RequestMapInfo() end
	end

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
events:RegisterEvent("START_TIMER")
events:RegisterEvent("CHALLENGE_MODE_COMPLETED")
events:RegisterEvent("CHALLENGE_MODE_RESET")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

events:SetScript("OnEvent", function(_, event, ...)
	if event == "CHALLENGE_MODE_START" then
		onChallengeStart()
	elseif event == "START_TIMER" then
		onStartTimer(...)
	elseif event == "CHALLENGE_MODE_COMPLETED" then
		onCompleted()
	elseif event == "CHALLENGE_MODE_RESET" then
		onReset()
	elseif event == "PLAYER_ENTERING_WORLD" then
		onEnteringWorld()
	end
end)
