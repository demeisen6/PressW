# OOCTracker — Out-of-Combat Tracker for Mythic+

A World of Warcraft (retail) addon that tracks how long the player spends **out of combat** during a Mythic+ keystone run, displays it live, escalates the on-screen text the longer you stand around, and stores per-dungeon records for the *least* total OOC time.

---

## 0. Design decisions (locked)

| Topic | Decision |
|---|---|
| **Record scope** | Store every saved run with full metadata: `{ character, dungeonMapID, keystoneLevel, seasonID, totalOOC, ... }`. Bests are *computed* from this history so the UI can filter **all-time vs current season**, **key level ≥ X**, and **this character vs all characters**. |
| **Which runs are saved** | **Only completed runs** are saved — regardless of whether the key was timed (under goal) or depleted (over goal). Manual-toggle runs and abandoned/reset keys are tracked live but **never** written to records. |
| **Goal-time comparison** | On key completion, compare elapsed time against **all three upgrade thresholds** (+1 ≤ 100%, +2 ≤ 80%, +3 ≤ 60% of par). Find the highest tier you *missed* by **less than your total OOC time** and flag it ("you'd have gotten +2 if you'd kept moving"). Surfaced in the finish announcement and the records UI. |
| **Display visibility** | Frame is hidden and the timer is stopped whenever not in a live M+ run. Option: show running total *during combat* or hide it during combat. The current-segment counter only appears while out of combat. |
| **OOC definition (v1)** | Player combat via `PLAYER_REGEN_ENABLED` / `PLAYER_REGEN_DISABLED`. |
| **Tracking scope** | Auto start/stop on M+ key events, **plus** a manual `/ooc start` / `/ooc stop` toggle for testing and non-key content (manual runs are not saved to records). |

### ✅ Decided: addon name = **PressW**
The public name is **PressW** ("just press W and move"). The in-game display
title is **"PressW M+ OOC Tracker"** (used in the addon list and both window
titles). Identifiers as shipped:
- Folder / `.toc`: `PressW` / `PressW.toc`
- SavedVariables: `PressWDB` (file `PressW.lua`)
- Slash commands: `/pressw` and `/ooc`
- Chat/print prefix: `PressW:`

(Renamed from the earlier working name `OOCTracker`, itself a fix of the
original `OCCTracker` typo.) The CurseForge project slug/branding in §6 should
follow this name.

### Noted future improvements (not in v1)
- OOC defined as **all party members out of combat** (track each unit's combat flag).
- OOC defined as **a specific group member** being out of combat (focus/targeted player).
- Sync/leaderboard of records across guild or party.
- Export records / WeakAura-style sharing string.
- **"Unskippable" OOC blocks**: some dungeon downtime isn't the player's fault — forced NPC conversations/escorts, RP walk-and-talk segments, scripted gates, elevator/transport rides, boss intro cinematics, etc. We'll eventually need a **data source** to classify these so they can be excluded (or shown separately as "forced OOC") from the player's "movable" OOC time. Open problem: where does that data come from?
  - Candidate signals: a hand-maintained per-dungeon table of known forced segments (keyed by encounter/quest/scene IDs); `CINEMATIC_START/STOP` & movie events; `C_QuestLog`/`GOSSIP_*` events during a key; UnitChannelInfo on escort NPCs; the M+ "force timer not running" hint (some scenes pause the key timer — that pause window is a strong proxy for "forced"). Likely a hybrid: detect what we can from events, fall back to a curated table per patch.
  - Until then v1 counts *all* OOC time uniformly and we note this caveat to the user.

---

## 1. Research: how WoW addons work

Goal of this phase: get a "hello world" addon loading in-game before writing real logic.

### 1.1 Key references to read
- **Warcraft Wiki (warcraft.wiki.gg)** — successor to Wowpedia, the canonical API docs. Pages: *AddOn programming*, *World of Warcraft API*, *Events*, *Widget API*, *TOC format*, *SavedVariables*.
- **Blizzard `Interface` source dump** — search GitHub for `Gethe/wow-ui-source` or `tomrus88/BlizzardInterfaceCode` to read how Blizzard's own UI uses the C_ChallengeMode and Settings APIs.
- **Ace3 docs** (wowace.com) — optional framework (addon skeleton, DB, config GUI) that removes a lot of boilerplate.
- **WoWUIBugs / WoW addon Discord** and `r/wowaddons` for current-patch gotchas.

### 1.2 Addon anatomy
Addons live in:
```
World of Warcraft/_retail_/Interface/AddOns/OOCTracker/
```
Minimum files:
- `OOCTracker.toc` — manifest (interface version, metadata, SavedVariables, file load order).
- One or more `.lua` files.
- Optional `.xml` for frame layout (we'll build frames in Lua instead).

SavedVariables are written to `WTF/Account/<ACCOUNT>/SavedVariables/OOCTracker.lua` on logout/`/reload`.

### 1.3 Dev environment & tooling
- **Editor**: VS Code + the *WoW API* / *Lua* extensions (Ketho's "WoW API" extension gives API IntelliSense).
- **In-game debugging**:
  - `/console scriptErrors 1` to surface Lua errors.
  - **BugSack** + **BugGrabber** addons for a readable error log.
  - `/etrace` (Event Trace) to watch events fire live — essential for confirming `CHALLENGE_MODE_*` and `PLAYER_REGEN_*` timing.
  - `/dump <expr>` and `/run <lua>` for poking the API live.
  - `/reload` to reload UI after editing files.
- **Symlink trick**: develop in this repo (`d:/projects/OOCTracker`) and symlink the addon folder into the live `AddOns` directory so git and the game see the same files:
  ```powershell
  New-Item -ItemType SymbolicLink -Path "<WoW>/_retail_/Interface/AddOns/OOCTracker" -Target "d:/projects/OOCTracker/OOCTracker"
  ```

### 1.4 Patch / interface version
The TOC `## Interface:` number must match the live client (e.g. The War Within `11.x` → `110xxx`). Find the current value in-game with:
```
/dump select(4, GetBuildInfo())
```
Keep this updated each major patch or the addon shows as "out of date."

---

## 2. The APIs we depend on

### 2.1 Combat state
- Event `PLAYER_REGEN_DISABLED` → **entering** combat → close the open OOC segment.
- Event `PLAYER_REGEN_ENABLED` → **leaving** combat → open a new OOC segment.
- `UnitAffectingCombat("player")` / `InCombatLockdown()` → poll current state (used at run start to know which state we're in).

### 2.2 Mythic+ / Challenge Mode
- `CHALLENGE_MODE_START` → key begins → start tracking.
- `CHALLENGE_MODE_COMPLETED` → key finished → finalize run, **save record** (only path that writes to records).
- `CHALLENGE_MODE_RESET` → key abandoned/reset → discard the live run (never saved).
- `C_ChallengeMode.GetActiveChallengeMapID()` → current dungeon mapID.
- `C_ChallengeMode.GetActiveKeystoneInfo()` → `level, affixIDs, wasEnergized`.
- `C_ChallengeMode.GetMapUIInfo(mapID)` → `name, id, timeLimit, texture, ...`. **`timeLimit` is the dungeon par/goal time** used for the over/under comparison.
- `C_ChallengeMode.GetCompletionInfo()` → `mapChallengeModeID, level, time, onTime, keystoneUpgradeLevels, ...`. **`time`** is elapsed run time (ms), **`onTime`** is whether it beat the timer, **`keystoneUpgradeLevels`** is the tier achieved (0–3). Read this on `CHALLENGE_MODE_COMPLETED`.
- **Upgrade thresholds** (seconds): `t1 = timeLimit`, `t2 = 0.8 * timeLimit`, `t3 = 0.6 * timeLimit`. With `elapsed = time/1000` and `achievedTier = keystoneUpgradeLevels`:
  - For each tier above what you achieved, `gap = elapsed - threshold[tier]`.
  - `couldHaveReached` = the **highest** tier whose `0 < gap < totalOOC` (you missed it, but by less than your downtime). `0` means even reclaiming all OOC time wouldn't have upgraded.
  - Store the gap for that tier (`couldHaveGap`) so the UI/announcement can say *by how much*.
- `C_MythicPlus.GetCurrentSeason()` → season ID (for season filtering).
- `UnitName("player")` / `GetRealmName()` (or `GetNormalizedRealmName()`) → character identity for the character dimension.
- `PLAYER_ENTERING_WORLD` → detect `/reload` mid-key and restore in-progress state.

### 2.3 Timing
- `GetTime()` → high-resolution monotonic seconds (fractional). Use deltas between combat transitions; never use wall-clock for durations.
- A throttled `OnUpdate` script on the display frame to refresh the live counter (~10/sec is plenty).

### 2.4 Display & options
- Frames + `FontString` built in Lua. `Frame:SetMovable`, `RegisterForDrag`, save position to SavedVariables.
- Options panel via the **modern Settings API** (`Settings.RegisterCanvasLayoutCategory` / `Settings.RegisterAddOnCategory`) — the old `InterfaceOptions_AddCategory` is deprecated. (Or use **AceConfig** if we adopt Ace3.)

---

## 3. Data model (SavedVariables)

Account-wide so records persist across characters.

```lua
OOCTrackerDB = {
  settings = {
    locked         = false,        -- frame drag lock
    showInCombat   = true,         -- show running total during combat?
    point          = { "CENTER", 0, 200 },  -- saved frame position
    -- escalation thresholds (seconds) and styling
    escalation = {
      sizeMin = 14, sizeMax = 40,
      ramp    = 10,                -- seconds over which size/color ramps to max
      colorStart = {0,1,0},        -- green
      colorMid   = {1,1,0},        -- yellow
      colorEnd   = {1,0,0},        -- red
    },
    minKeyLevelForRecords = 0,     -- ignore runs below this for records
  },

  -- only COMPLETED runs are appended here; bests are computed from this so all filters work
  runs = {
    {
      character     = "Tankadin-Illidan",  -- "Name-Realm" (the character dimension)
      dungeonMapID  = 123,
      dungeonName   = "Ara-Kara",
      keystoneLevel = 18,
      seasonID      = 14,
      affixIDs      = { 9, 7, 124 },
      totalOOC      = 142.6,       -- seconds
      segmentCount  = 31,
      longestSegment= 22.1,
      runDuration   = 1623.0,      -- key elapsed time (seconds)
      goalTime      = 1620.0,      -- dungeon par/timeLimit (seconds)
      overUnder     = 3.0,         -- runDuration - goalTime; negative = timed/under
      onTime        = false,       -- beat the timer?
      achievedTier  = 0,           -- keystoneUpgradeLevels (0-3)
      couldHaveReached = 1,        -- highest tier reclaiming OOC time would have hit (0 = none)
      couldHaveGap  = 2.4,         -- seconds you missed that tier by
      timestamp     = 1718900000,  -- time()
    },
    -- ...
  },
}
```

**Why store full history instead of just bests:** the user wants UI filters for *all-time vs current season*, *key level ≥ X*, and *this character vs all*. A precomputed "best per dungeon" can't answer those without storing one best per (character × dungeon × season × level) anyway. A capped run list (e.g. last 500 runs) is small, flexible, and gives us a history view for free. Bests are derived with a filter+min query at display time.

**`couldHaveReached`** is the headline insight: when a higher upgrade tier was missed by less than the time spent standing around, that tier was lost to downtime, not to clear speed — exactly what this addon exists to expose. It covers depletion (missed +1) and missed +2/+3 upgrades uniformly.

---

## 4. Implementation plan

Suggested file layout inside `OOCTracker/`:
```
OOCTracker.toc
Core.lua        -- addon table, event frame, slash commands, init
Tracker.lua     -- combat + M+ state machine, OOC accumulation
Display.lua     -- the live HUD frame (movable, escalating text)
Records.lua     -- save runs, compute filtered bests
Options.lua     -- Settings panel
RecordsUI.lua   -- the records browser window with filters
```

### Phase A — Skeleton (get it loading)
1. Write `OOCTracker.toc` with metadata + `## SavedVariables: OOCTrackerDB` + file list.
2. `Core.lua`: create the namespace, an event frame, handle `ADDON_LOADED` to init `OOCTrackerDB` with defaults, register `/ooc` slash command (prints "loaded").
3. Verify in-game: addon appears in list, loads, no errors.

### Phase B — Core tracking state machine (`Tracker.lua`)
1. State: `isRunning`, `inCombat`, `segmentStart`, `totalOOC`, `segments[]`, plus current run metadata.
2. On run start (M+ start **or** manual toggle): capture dungeon/level/season, reset accumulators, set `inCombat = UnitAffectingCombat("player")`, if OOC open first segment.
3. `PLAYER_REGEN_DISABLED`: if a segment is open, `totalOOC += GetTime() - segmentStart`, record segment, mark in-combat.
4. `PLAYER_REGEN_ENABLED`: open new segment (`segmentStart = GetTime()`), mark out-of-combat.
5. On run end: close any open segment, build the run record, hand to `Records.lua`.
6. Handle `PLAYER_ENTERING_WORLD` mid-run (reload): if a key is still active, resume; otherwise discard.

### Phase C — Live display (`Display.lua`)
1. Movable frame with two FontStrings: **Total OOC** (running) and **Current segment** (live while OOC).
2. Throttled `OnUpdate`: current segment = `GetTime() - segmentStart`; total = `totalOOC + (open segment so far)`.
3. **Escalation**: map current-segment seconds → font size (lerp `sizeMin`→`sizeMax` over `ramp`) and color (lerp green→yellow→red). Clamp at max.
4. Visibility rules: hidden unless a run is active; during combat show/hide total per `showInCombat`; current-segment line only while OOC.
5. Drag-to-move when unlocked; persist position.

### Phase D — Records storage & queries (`Records.lua`)
1. `SaveRun(run)`: **only called from `CHALLENGE_MODE_COMPLETED`** (completed runs only). Stamp `character`, compute `goalTime`/`overUnder`/`onTime`/`achievedTier`/`couldHaveReached`/`couldHaveGap`, append to `runs`, trim to cap.
2. `GetBest(filters)`: given `{ seasonOnly=bool, minLevel=N, character=name|nil }`, scan `runs`, return lowest `totalOOC` per dungeon. Used by the records UI.
3. On finalize, detect & announce a **new record** ("New OOC record for Ara-Kara: 2:22!").
4. **"Could have upgraded" announcement**: when `couldHaveReached > achievedTier`, print a tier-aware message, e.g. *"Missed +2 by 0:24 — you spent 1:30 out of combat. Keep moving and you'd have upgraded!"* (for `couldHaveReached == 1` it phrases as "you'd have timed it").

### Phase E — Records browser (`RecordsUI.lua`)
1. A window (`/ooc records`) listing one row per dungeon: name, best total OOC, the key level/season it was set at.
2. Filter controls: **All-time / Current season** toggle, **min key level** stepper/dropdown, and **This character / All characters** toggle.
3. Sort by dungeon or by best time. Optional: expand a dungeon to see its run history, with a badge on runs where `couldHaveReached > achievedTier` (e.g. "could've been +2, −0:24").

### Phase F — Options panel (`Options.lua`)
Expose: frame lock, show-in-combat, escalation thresholds & colors, min key level for records, reset-records button. Register with the Settings API so it appears under Options → AddOns.

### Phase G — Polish
- Default sensible thresholds; sanity-check edge cases (death/release, combat at the very start, key restart, dungeon with no mapID).
- Localization-ready strings (a simple `L` table) even if English-only at first.
- Minimap button (optional, via LibDBIcon) or just slash commands.

---

## 5. Testing plan
- **Without a key**: use `/ooc start` / `/ooc stop`, then walk in/out of combat on training dummies; watch the counter, escalation, and that a record gets written.
- **Event sanity**: `/etrace` to confirm `CHALLENGE_MODE_START/COMPLETED/RESET` and `PLAYER_REGEN_*` fire when expected.
- **Reload mid-run**: `/reload` during a manual run and during a real key to verify resume logic.
- **Real M+**: run a low key, confirm auto start/stop, record save, and the new-record announcement.
- **Data integrity**: log out / back in and confirm SavedVariables persisted and the records UI filters work.

---

## 6. Publishing to CurseForge

### 6.1 One-time setup
1. Create/log into a **CurseForge** account and enable the **Authors** program.
2. **Create a new project** under *World of Warcraft → Addons*: set name (`OOCTracker`), summary, category (e.g. *Combat*, *Mythic+*), and a **license** (MIT is common for addons).
3. Pick a slug/URL.

### 6.2 Packaging
- The uploaded zip must contain the `OOCTracker/` folder (with the `.toc`) at its root.
- Add a `.pkgmeta` file and use the **BigWigs packager** (`BigWigsMods/packager`) for proper packaging (handles externals, version substitution like `@project-version@`, changelog, and TOC interface tagging).
- Recommended: host the source on **GitHub** and wire a **GitHub Action** using the BigWigs packager to auto-build and upload on every tagged release. You'll need a **CurseForge API token** (from your CurseForge account settings) stored as a repo secret (`CF_API_KEY`), plus the project ID.

### 6.3 Release workflow
1. Bump `## Version:` in the TOC (or let the packager substitute from the git tag).
2. Update changelog.
3. Tag a release (`git tag v1.0.0 && git push --tags`) → Action builds zip → uploads to CurseForge with the correct **game version** flag (retail / TWW).
4. Set the file as **Release/Beta/Alpha** as appropriate; first public release = Release.

### 6.4 Optional extra distribution
- **Wago Addons** and **WoWInterface** are alternative hosts; the same packager can push to all three.
- Add a README, screenshots/GIF of the escalating HUD, and the records window to the CurseForge project page for discoverability.

---

## 7. Suggested build order (milestones)
1. **M0** — Skeleton loads in-game, `/ooc` responds. *(Phase A)*
2. **M1** — Combat OOC tracking works with manual toggle, prints total on stop. *(Phase B)*
3. **M2** — Live HUD with escalating size/color. *(Phase C)*
4. **M3** — Records saved + new-record detection. *(Phase D)*
5. **M4** — M+ auto start/stop wired in. *(integrate B with M+ events)*
6. **M5** — Records browser with filters. *(Phase E)*
7. **M6** — Options panel + polish. *(Phases F–G)*
8. **M7** — Package & publish to CurseForge. *(Section 6)*

---

## 8. Open questions to revisit later
- Should the record be **least total OOC**, or also surface **fewest/longest segments** as secondary stats? (Data model already stores both.)
- Confirm the +2/+3 threshold percentages (80% / 60% of par) against the live client at build time — verify with `C_ChallengeMode.GetMapUIInfo` / completion data in case Blizzard adjusts them.
- Minimap button vs slash-only.
- Do we want an in-combat **sound/flash** when a segment passes a threshold (nudge to keep pulling)?
