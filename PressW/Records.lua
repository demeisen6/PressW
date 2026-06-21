-- PressW — Records.lua
-- M3: persist completed runs, derive analytics, detect records & missed
-- upgrades, and answer filtered "best" queries. See PLAN.md §4 Phase D.
--
-- Only COMPLETED M+ keys are saved here (via SaveRun, called from the M+
-- integration in M4). Manual /ooc runs are never recorded.

local ADDON_NAME, ns = ...

local Records = {}
ns.Records = Records

local RUN_CAP = 500   -- keep the most recent N runs

-- Upgrade-tier time multipliers of the dungeon par (timeLimit), indexed by tier.
--   +1 (timed)  <= 100% of par
--   +2          <=  80% of par
--   +3          <=  60% of par
-- Verify against the live client at build time (PLAN.md §8 open question).
local TIER_MULT = { 1.0, 0.8, 0.6 }

--------------------------------------------------------------------------------
-- Identity / season helpers
--------------------------------------------------------------------------------
local function playerKey()
	local name = UnitName("player")
	local realm = GetNormalizedRealmName() or GetRealmName() or ""
	return name .. "-" .. realm
end
ns.PlayerKey = playerKey

local function currentSeason()
	if C_MythicPlus and C_MythicPlus.GetCurrentSeason then
		return C_MythicPlus.GetCurrentSeason() or 0
	end
	return 0
end
ns.GetCurrentSeason = currentSeason

--------------------------------------------------------------------------------
-- Upgrade analysis
--------------------------------------------------------------------------------
-- Given the run's elapsed time, the dungeon par, the tier actually achieved and
-- the total OOC time, find the highest tier the player *would* have reached had
-- they reclaimed their downtime. Returns (couldHaveReached, couldHaveGap):
--   couldHaveReached = highest tier > achieved whose miss margin < totalOOC
--   couldHaveGap     = seconds that tier was missed by (0 if none)
-- Because higher tiers have smaller thresholds, the gap shrinks as the tier
-- drops, so scanning 3->1 and taking the first qualifying tier yields the best.
local function analyzeUpgrade(elapsed, par, achievedTier, totalOOC)
	if not par or par <= 0 then return 0, 0 end
	for tier = 3, 1, -1 do
		if tier > achievedTier then
			local gap = elapsed - par * TIER_MULT[tier]
			if gap > 0 and gap < totalOOC then
				return tier, gap
			end
		end
	end
	return 0, 0
end
Records.AnalyzeUpgrade = analyzeUpgrade  -- exposed for testing

-- The upgrade tier (0..3) a run achieves, derived from elapsed vs par — exactly
-- how the game decides keystone upgrades. More reliable than GetCompletionInfo's
-- shifting return order.
function Records.TierForTime(elapsed, par)
	if not par or par <= 0 then return 0 end
	for tier = 3, 1, -1 do
		if elapsed <= par * TIER_MULT[tier] then return tier end
	end
	return 0
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------
-- Lowest totalOOC recorded for a dungeon, optionally restricted to one
-- character. Returns nil if there are no qualifying runs.
local function bestTotalForDungeon(mapID, character)
	local best
	for _, r in ipairs(ns.db.runs) do
		if r.dungeonMapID == mapID and (not character or r.character == character) then
			if not best or r.totalOOC < best then best = r.totalOOC end
		end
	end
	return best
end

-- Best (lowest totalOOC) run per dungeon, honoring filters. Returns a table
-- keyed by dungeonMapID -> run. Used by the records browser (M5).
-- filters = { seasonOnly = bool, minLevel = N, character = "Name-Realm" | nil }
function Records.GetBest(filters)
	filters = filters or {}
	local season = filters.seasonOnly and currentSeason() or nil
	local best = {}
	for _, r in ipairs(ns.db.runs) do
		local ok = true
		if filters.minLevel and r.keystoneLevel < filters.minLevel then ok = false end
		if ok and filters.character and r.character ~= filters.character then ok = false end
		if ok and season and r.seasonID ~= season then ok = false end
		if ok then
			local cur = best[r.dungeonMapID]
			if not cur or r.totalOOC < cur.totalOOC then
				best[r.dungeonMapID] = r
			end
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Announcements
--------------------------------------------------------------------------------
local function announceRecord(run, prevAll, prevChar)
	local t = ns.FormatTime(run.totalOOC)
	if not prevAll or run.totalOOC < prevAll then
		local was = prevAll and (" (was " .. ns.FormatTime(prevAll) .. ")") or ""
		ns.Print("|cff00ff00New all-time OOC record|r for " .. run.dungeonName .. ": " .. t .. was .. "!")
	elseif not prevChar or run.totalOOC < prevChar then
		local was = prevChar and (" (was " .. ns.FormatTime(prevChar) .. ")") or ""
		ns.Print("|cff00ff00New OOC record|r for " .. run.dungeonName ..
			" on " .. run.character .. ": " .. t .. was .. "!")
	end
end

local function announceUpgrade(run)
	if run.couldHaveReached <= run.achievedTier then return end
	local by = ns.FormatTime(run.couldHaveGap)
	local ooc = ns.FormatTime(run.totalOOC)
	if run.couldHaveReached == 1 then
		ns.Print(("|cffffd000Missed the timer by %s|r — you spent %s out of combat. " ..
			"Keep moving and you'd have timed it!"):format(by, ooc))
	else
		ns.Print(("|cffffd000Missed +%d by %s|r — you spent %s out of combat. " ..
			"Keep moving and you'd have upgraded!"):format(run.couldHaveReached, by, ooc))
	end
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------
-- Stamp identity/season/timestamp and compute derived fields on a raw run.
-- Idempotent. `run` provides: dungeonMapID, dungeonName, keystoneLevel,
-- affixIDs, totalOOC, segmentCount, longestSegment, runDuration, goalTime,
-- onTime, achievedTier.
local function enrich(run)
	run.character    = run.character or playerKey()
	run.seasonID     = run.seasonID or currentSeason()
	run.timestamp    = run.timestamp or time()
	run.affixIDs     = run.affixIDs or {}
	run.achievedTier = run.achievedTier or 0
	run.overUnder    = (run.runDuration or 0) - (run.goalTime or 0)
	run.couldHaveReached, run.couldHaveGap =
		analyzeUpgrade(run.runDuration or 0, run.goalTime, run.achievedTier, run.totalOOC or 0)
	return run
end
Records.Enrich = enrich

-- Enrich, then persist if at/above the minimum key level. Always returns the
-- enriched run; `run.recorded` is true only if it was saved to the records.
function Records.SaveRun(run)
	enrich(run)

	local minLevel = ns.db.settings.minKeyLevelForRecords or 0
	if (run.keystoneLevel or 0) < minLevel then
		run.recorded = false
		return run
	end

	-- Record check must happen BEFORE we append this run.
	local prevAll  = bestTotalForDungeon(run.dungeonMapID, nil)
	local prevChar = bestTotalForDungeon(run.dungeonMapID, run.character)

	local runs = ns.db.runs
	runs[#runs + 1] = run
	while #runs > RUN_CAP do
		table.remove(runs, 1)  -- drop oldest
	end

	announceRecord(run, prevAll, prevChar)
	announceUpgrade(run)
	run.recorded = true
	return run
end

-- Build a one-line chat string summarizing a completed run.
function Records.FormatRunAnnounce(run)
	local tier = (run.achievedTier and run.achievedTier > 0) and ("+" .. run.achievedTier) or "depleted"
	local s = ("PressW: %s +%d (%s) — %s out of combat over %s"):format(
		run.dungeonName or "?", run.keystoneLevel or 0, tier,
		ns.FormatTime(run.totalOOC), ns.FormatTime(run.runDuration))
	if run.couldHaveReached and run.couldHaveReached > (run.achievedTier or 0) then
		if run.couldHaveReached == 1 then
			s = s .. (". Missed the timer by %s — that was the downtime!"):format(ns.FormatTime(run.couldHaveGap))
		else
			s = s .. (". Missed +%d by %s — that was the downtime!"):format(run.couldHaveReached, ns.FormatTime(run.couldHaveGap))
		end
	end
	return s
end

-- Build a one-line chat string for a stored record.
function Records.FormatRecordAnnounce(run)
	return ("PressW record: %s — %s out of combat (+%d, %s)"):format(
		run.dungeonName or "?", ns.FormatTime(run.totalOOC),
		run.keystoneLevel or 0, run.character or "?")
end

--------------------------------------------------------------------------------
-- Debug helper (temporary, until M4 wires real M+ events)
--------------------------------------------------------------------------------
-- Fabricate a plausible completed run so storage / records / upgrade messages
-- can be exercised without an actual key. `/ooc savetest`
function Records.DebugSaveTest()
	local pool = {
		{ id = 9001, name = "Test: Ara-Kara",   par = 1830 },
		{ id = 9002, name = "Test: City of Threads", par = 1980 },
		{ id = 9003, name = "Test: Stonevault", par = 1920 },
	}
	local d = pool[math.random(#pool)]
	local par = d.par
	local elapsed = par + math.random(-120, 150)
	local tier = 0
	if elapsed <= par then tier = 1 end
	if elapsed <= par * 0.8 then tier = 2 end
	if elapsed <= par * 0.6 then tier = 3 end
	local totalOOC = math.random(30, 150)

	local run = Records.SaveRun({
		dungeonMapID   = d.id,
		dungeonName    = d.name,
		keystoneLevel  = math.random(8, 18),
		totalOOC       = totalOOC,
		segmentCount   = math.random(8, 30),
		longestSegment = math.random(10, 40),
		runDuration    = elapsed,
		goalTime       = par,
		onTime         = tier >= 1,
		achievedTier   = tier,
	})
	if not run.recorded then
		ns.Print("test run was below the 'minimum key level to record' setting; not saved.")
		return
	end
	ns.Print(("saved test run: %s +%d, %s elapsed (par %s), tier +%d, OOC %s."):format(
		run.dungeonName, run.keystoneLevel, ns.FormatTime(run.runDuration),
		ns.FormatTime(run.goalTime), run.achievedTier, ns.FormatTime(run.totalOOC)))
end
