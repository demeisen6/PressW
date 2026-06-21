# PressW — M+ Out-of-Combat Tracker

A World of Warcraft (retail) addon that tracks how long you spend **out of
combat** during a Mythic+ keystone run — because the timer doesn't stop just
because you do. *Just press W and move.*

It shows your downtime live, nudges you with text that grows and turns red the
longer you stand around, and keeps per-dungeon records of your *least* total
out-of-combat time.

## Features

- **Live HUD** showing `OOC: <downtime> / <total run time>` plus a current-segment
  timer that **grows and shifts green → yellow → red** the longer you stay out of
  combat (escalation curve and colors are configurable).
- **Automatic** start/stop on Mythic+ keystone start, completion, and reset.
- **Records** per dungeon (best/lowest total OOC), with filters for **current
  season**, **this character**, and **minimum key level**.
- **Missed-upgrade insight**: on completion, if you missed a +1/+2/+3 timer by
  *less than your downtime*, PressW tells you the upgrade you left on the table.
- **Chat announcements** of results and records to party/instance/guild/say.
- A manual `/pressw start` / `/pressw stop` toggle for testing or non-key content.

## Installation

**Manual:** download/clone this repo and copy the `PressW` folder into:

```
World of Warcraft/_retail_/Interface/AddOns/
```

so that `.../AddOns/PressW/PressW.toc` exists. Reload or restart the client and
enable **PressW M+ OOC Tracker** in the AddOns list.

## Usage

Slash commands (`/pressw` or `/ooc`):

| Command | Description |
|---|---|
| `/pressw` | Show the command list |
| `/pressw start` | Begin a manual tracking run |
| `/pressw stop` | End the manual run and print a summary |
| `/pressw lock` | Toggle the HUD lock (unlocked = draggable preview + buttons) |
| `/pressw records` | Open the records browser |
| `/pressw options` | Open the settings window |

While the HUD is **unlocked** you can drag it to reposition, and three icons
appear on it: records, lock, and settings. Lock it to hide the preview and the
records/settings icons during play (the lock icon stays so you can unlock again).

## Settings

Open with the cog icon or `/pressw options`:

- Lock HUD, show running total during combat, HUD scale
- Min/max font size and the escalation ramp (how fast the text grows)
- Escalation colors (start / mid / end)
- Minimum key level to record
- Announce results to chat on M+ completion and/or manual runs
- Reset all records

## Source & bug reports

Source code: <https://github.com/demeisen6/PressW>
Found a bug or have a request? [Open an issue](https://github.com/demeisen6/PressW/issues).

## Notes & limitations

- v1 tracks **your** combat state only (`PLAYER_REGEN_ENABLED/DISABLED`).
  Group-wide or per-member out-of-combat tracking is a planned future option.
- Records are stored account-wide in SavedVariables (`PressWDB`).

## License

[MIT](LICENSE) © 2026 demeisen6. Distribution complies with Blizzard's
World of Warcraft UI Add-On Development Policy (free, no paywalls).
