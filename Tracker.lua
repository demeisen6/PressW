-- PressW — Tracker.lua
-- M1: combat out-of-combat state machine + manual start/stop.
-- See PLAN.md §4 Phase B.
--
-- The model is a sequence of OOC "segments". A segment is open only while we
-- *should be accruing* downtime — currently: not in combat and not dead/ghost
-- (see shouldAccrue). The sum of closed segments is `totalOOC`; a currently-open
-- segment is added live by the display. Durations use GetTime() deltas only.

local ADDON_NAME, ns = ...

local Tracker = {}
ns.Tracker = Tracker

-- Live run state. Reset on every Start().
local state = {
	isRunning    = false,
	inCombat     = false,
	dead         = false, -- player dead/ghost? (downtime while dead isn't counted)
	segmentStart = nil,   -- GetTime() when the open OOC segment began; nil if not accruing
	totalOOC     = 0,     -- accumulated seconds from closed segments
	segments     = {},    -- list of closed-segment durations (for count/longest)
	startedAt    = nil,   -- GetTime() at run start (for total run duration)
	source       = nil,   -- "manual" | "mythicplus"
	meta         = nil,   -- run metadata (dungeon/level/season); populated in M4
}
ns.trackerState = state  -- exposed so the display (M2) can read live values

-- Dedicated frame for combat events; registered only while a run is active so
-- we do no work when the addon is idle.
local events = CreateFrame("Frame")

local function now() return GetTime() end

-- Fold the currently open OOC segment into the total and record its length.
local function closeSegment()
	if state.segmentStart then
		local dur = now() - state.segmentStart
		if dur > 0 then
			state.totalOOC = state.totalOOC + dur
			state.segments[#state.segments + 1] = dur
		end
		state.segmentStart = nil
	end
end

local function openSegment()
	state.segmentStart = now()
end

-- We only count OOC time the player could actually have avoided: not in combat
-- AND not dead/ghost (dying mid-boss leaves you "out of combat" while the group
-- fights on — that downtime isn't on you). This predicate is the single place to
-- extend later (e.g. "all party members out of combat").
local function shouldAccrue()
	return state.isRunning and not state.inCombat and not state.dead
end

-- Open or close the OOC segment so it matches whether we should be accruing now.
local function refreshSegment()
	if shouldAccrue() then
		if not state.segmentStart then openSegment() end
	elseif state.segmentStart then
		closeSegment()
	end
end

--------------------------------------------------------------------------------
-- Combat / death transitions (only fire while a run is active)
--------------------------------------------------------------------------------
events:SetScript("OnEvent", function(_, event)
	if not state.isRunning then return end
	if event == "PLAYER_REGEN_DISABLED" then
		state.inCombat = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		state.inCombat = false
	elseif event == "PLAYER_DEAD" or event == "PLAYER_UNGHOST" or event == "PLAYER_ALIVE" then
		-- Re-read authoritatively rather than trust which event means what.
		state.dead = UnitIsDeadOrGhost("player") and true or false
	end
	refreshSegment()
end)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Tracker.IsRunning()
	return state.isRunning
end

-- Live values for the display: total OOC so far (incl. the open segment), the
-- current open-segment length, whether we're in combat, and the total run
-- elapsed time.
function Tracker.GetLive()
	local current = state.segmentStart and (now() - state.segmentStart) or 0
	local runElapsed = state.startedAt and (now() - state.startedAt) or 0
	return state.totalOOC + current, current, state.inCombat, runElapsed
end

-- Begin tracking. `source` is "manual" or "mythicplus"; `meta` is optional run
-- metadata (filled in by the M+ integration in M4).
function Tracker.Start(source, meta)
	if state.isRunning then
		ns.Print("a run is already being tracked — |cffffff00/ooc stop|r it first.")
		return false
	end

	state.isRunning    = true
	state.source       = source or "manual"
	state.meta         = meta
	state.totalOOC     = 0
	state.segments     = {}
	state.segmentStart = nil
	state.startedAt    = now()
	state.inCombat     = UnitAffectingCombat("player") and true or false
	state.dead         = UnitIsDeadOrGhost("player") and true or false

	events:RegisterEvent("PLAYER_REGEN_DISABLED")
	events:RegisterEvent("PLAYER_REGEN_ENABLED")
	events:RegisterEvent("PLAYER_DEAD")
	events:RegisterEvent("PLAYER_UNGHOST")
	events:RegisterEvent("PLAYER_ALIVE")

	refreshSegment()  -- open the OOC clock now if we should already be accruing

	if ns.Display and ns.Display.OnRunStart then ns.Display.OnRunStart() end
	return true
end

-- End the active run and return a summary table. Does NOT save a record — that
-- happens only for completed M+ keys (M3/M4); manual runs are never saved.
-- Returns nil if no run was active.
function Tracker.Stop()
	if not state.isRunning then return nil end

	closeSegment()
	events:UnregisterAllEvents()

	local longest = 0
	for _, d in ipairs(state.segments) do
		if d > longest then longest = d end
	end

	local summary = {
		source         = state.source,
		totalOOC       = state.totalOOC,
		segmentCount   = #state.segments,
		longestSegment = longest,
		runDuration    = now() - (state.startedAt or now()),
		meta           = state.meta,
	}

	state.isRunning = false
	state.source    = nil
	state.meta      = nil

	if ns.Display and ns.Display.OnRunStop then ns.Display.OnRunStop() end
	return summary
end
