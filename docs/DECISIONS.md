# Architecture decisions

Short records of decisions that shape the code. Newest first. Change a record only when the decision itself changes.

## 2026-11-22: Reference data and facts live in the database; Blizzard first, Wowhead marked

**Decision** (agreed with the user):

- **Dimension tables** hold reference data that changes rarely: item names, prices, icons and descriptions; recipes; quests and
  zones; achievements and their categories; talent trees. They are stored in the database and refreshed **once a day**
  (later also by hand from an admin console).
- **Fact tables** hold what changes all the time: character sheets, levels, the auction house. They are refreshed **every
  hour** (half an hour if ever needed).
- **Sources**: Blizzard's API is the base. Wowhead's WoW Forever data is used only for what Blizzard doesn't have, and every
  such value is marked with its source (`src = 'wowhead'`), so the page can say so.
- **The page never calls a game API itself.** It reads the database. (Exception kept: «Хотелки», where a player pastes a
  Wowhead link on purpose.)

**Why**: one source of truth with the same format across the site (the character card and the auction show the same
tooltips), no per-visitor requests to third parties, API secrets stay on the server, and the site works the same when an
external site is slow or down.

**Where it stands**:

| Data | Table | Refresh |
|---|---|---|
| Item names, quality, class, level, icon, vendor prices | `ah_meta` 'items' / 'classes' | daily (`scripts/ah.py --dims`, `.github/workflows/dims.yml`) + new ids hourly |
| Item descriptions (tooltip lines) | `dim_item` (`src` blizzard / wowhead / none) | daily (same job) + new ids hourly |
| Auction prices, flow, totals, price ladder | `ah_hour`, `ah_day`, `ah_meta` 'ladder:*' | hourly (`ah.yml`) |
| Character sheets, roster, levels | `docs` (`gchars`, `guild`, `glevels`, ...) | hourly (`guild_sync`) |
| Recipes (details, crafted item tooltip), achievement descriptions, quests per zone | `bnet_recipes`, `bnet_ach_info`, `bnet_quest_areas` + `bnet_quests` | daily: the 5-minute fill jobs re-fetch rows older than a day (`at` / `item_at`) after the missing ones, keeping old values until replaced |
| Icons, 3D display ids, achievement categories, Spelunker definitions | `bnet_icons`, `bnet_display`, `bnet_ach_cat`, `bnet_ach`, recipe icons | once per id: an id's picture / definition doesn't change, so no refresh |
| Talent trees | `docs` `gtalents/forever` (Wowhead) | weekly |

**Not done yet**: no admin console button. Hand-made lists still live in `index.html` (`AH_VENDOR`, `DUNGEONS`, `RAIDS`, dates): moving them into tables only pays off together with an admin console to edit them.
