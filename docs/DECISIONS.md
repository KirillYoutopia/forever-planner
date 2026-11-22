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
| Recipes, achievements, quests, icons, 3D display ids | `bnet_recipes`, `bnet_ach*`, `bnet_quest*`, `bnet_icons`, `bnet_display` | loaded **once** per id, never refreshed: to move to the daily refresh |
| Talent trees | `docs` `gtalents/forever` (Wowhead) | weekly |

**Not done yet**: the "loaded once" dimension caches above don't follow the daily refresh; there is no admin console button.
