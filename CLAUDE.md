# WoW Forever Planner — project context

You're working on the guild site of a small WoW Forever group (Kute Expats, EU, PvP Horde; 5 core players). The UI text is in English (since 2026-11-23, the owner's decision; Russian was dropped, no language switch). Keep all user-facing text in English; game names as in the game. Values stored in the database in Russian (e.g. bet categories) stay as they are and are translated only for display. It's a static site on GitHub Pages backed by Supabase; reading needs no login, writing needs a player login (see "Login and permissions"). Before a substantial task read `docs/PHASE_HANDOFF.md` (state, open questions) and `docs/DECISIONS.md` (architecture decisions).

## Stack and files
- `index.html`: the entire app. Vanilla JS and CSS in one file. No framework, no build step.
- `old.html`: the previous version of the site, kept unchanged. `v2.html` only redirects old links to `index.html` (keeping the `#...` part).
- `supabase/functions/modelviewer`: Edge Function that proxies Wowhead's 3D model viewer files for the character card.
- `store.js`: Supabase adapter. It copies the old claude.ai storage interface, so the page code stays the same:
  - `db.collection(name).onSnapshot(cb)` gets `{ docs: [{ id, data() }] }`. `.add(data)` and `.doc(id)` are also available.
  - `db.doc("coll/id")` has `.update(patch)` (deep merge), `.set(data)`, `.delete()` and `.onSnapshot(cb)`.
  - Updates are applied locally first, then confirmed by Supabase realtime. The data is fully reloaded when the tab becomes visible again.
  - Big collections (`LAZY`: `gcat`, `gtalents`) are not in the initial load; `db.want(coll)` fetches one and keeps it live. `wantLazy()` asks for them when a view that uses them opens; a new user of these collections must be covered there.
- `config.js`: Supabase URL and anon key.
- `supabase.sql`: schema and seed data. It's safe to re-run.
  - One table, `docs(coll, id, data jsonb)`, primary key `(coll, id)`.
  - RPC `patch_doc(p_coll, p_id, p_patch)` deep-merges a patch on the server, so two people editing different fields don't overwrite each other.
  - `patch_doc` is the only write path for the page (security definer, merge-only, validates collection names, vote values and that voters are group players). A new collection must be added to its allow-list. `players` rows accept only known keys with checked shapes (class, race, role and pick values from the lists). Anon can only `select` the table directly, never insert/update/delete.
  - `docs_history` keeps the previous version of every changed row (not readable by anon), for undoing vandalism.
  - Realtime is enabled on the table.
  - The page loads ALL of `docs` on start and gets every change by realtime, so big or fast-changing data (the auction, item descriptions) lives in separate hidden tables read through RPCs (`db.call(fn, args)`), never in `docs`.
  - Writes from GitHub Actions go through RPCs guarded by the shared secret `bnet_config.ah_secret` (`ah_publish`, `ah_names_put`, `dim_item_put`), never with a database password.
- `scripts/ah.py`: the auction and reference-data job (Python, standard library only). `--publish` (hourly, `.github/workflows/ah.yml`), `--dims` (daily, `.github/workflows/dims.yml`); locally `py scripts/ah.py --env ..\wow-guild-backend\.env --archive ..\wow-ah-data` keeps raw snapshots. `--selftest` runs its asserts. GitHub secrets: `BLIZZARD_CLIENT_ID`, `BLIZZARD_CLIENT_SECRET`, `AH_SECRET`.
- `docs/DECISIONS.md` (architecture decisions), `docs/PHASE_HANDOFF.md` (current state), `docs/INSTRUCTION_PROPOSALS.md` (proposed changes to this file).
- `roadmap.png`: the roadmap image used in the header.
- `README.md`: setup and hosting steps (Supabase project, Netlify Drop / GitHub Pages).

## Data model (`data` is jsonb)
- `players/{id}`, where core ids are `p_denis`, `p_kirill`, `p_olesya`, `p_yan`, `p_alexey` and new ids look like `p_xxxxxxxxxxxx`:
  - `name`: string
  - `createdAt`: number, used for sort order
  - `picks`: `{ [Class]: 1 | 2 | -1 (ban) | 0 }`
  - `main`: `{ cls, race, role }`. A ★ in the grid means `main.cls` is set.
  - `profs`: `{ [Profession]: boolean }`
  - `avail`: `{ "YYYY-MM-DD": "full" | "no" | a subset of "mde" (morning/day/evening) | "hA-B" (hours) | "" }`
  - `char`: guild character slug linked to the player (set on the character sheet, "Чей персонаж"). `lvlOf(p)` and the party frames read level, class, race and avatar from that character; the old manual `level`/`xp` are only a fallback and are no longer edited.
  - `alts`: `{ [slug]: true }`, the player's twinks in the guild (`false` = unlinked, since patches only merge). Read via `altsOf(p)`. A character belongs to one player, as main or twink.
  - `deleted`: `true` hides a (non-core) player. The database allows no deletes, so removal is a soft delete.
- `votes/{playerId}`: `{ vote: "pve" | "pvp" | "", at }`. One vote per group player; `""` means the vote was withdrawn. The voter types their name; it must match a player name (case-insensitive) or the vote is silently refused with no hints. The name is remembered in localStorage as `wf-name`.
- `meta/settings`: `{ size: 5 | 10 }`
- "Скоро" tab (`#soon`). "Ближайшая игра" lives in the calendar tab. `DUNGEONS` follows Wowhead's WoW Forever dungeon guide (beta data):
  - Player fields: `level` (1–60), `xp` (0–100, % to next level), `dungeons: { [dungeonId]: true }` (ids in `DUNGEONS` / `RAIDS`).
  - `tasks/{id}`: `{ text, due, done, at }`, the launch checklist.
  - `goals/{id}`: `{ title, done: { [playerId]: true }, at }`. The "60 by Dec 9" goal is computed from levels, not stored.
  - `wants/{id}`: `{ by: playerId, item, src, wid?, q?, icon?, at }`, the loot wishlist. `wid`/`q`/`icon` come from Wowhead's tooltip JSON (`nether.wowhead.com/tooltip/item/{id}?dataEnv=16`, CORS-open, no script) when a Wowhead link or ID is pasted. A clash is the same item name from 2+ players.
  - `deaths/{id}`: `{ by: playerId, lvl, killer, words, at }`, the Hardcore graveyard.
  - All four collections use `deleted: true` for removal, like players.
- `orders/{id}`: `{ by, prof, rid, n, note, st: "open" | "taken" | "done", taker, doneAt, at, deleted }`, craft orders on the "Профессии" page. `patch_doc` lets the author create, comment and cancel; a player whose main or twink knows the recipe takes it and marks it done. `players/{id}.fav` `{ "Profession:recipeId": true | false }` holds favourite recipes. The menu badge (`renderOrderBadge()`) counts orders waiting for the logged-in player.
- "Таверна" (`#tavern`), "Ставки" (`#bets`) and "Зал славы" (`#fame`) tabs. "Ты —" (`#me`, localStorage `wf-me`) says who is acting there.
  - `rolls/{id}`: Roll to Death duels `{ a, b, start, stakeS (silver; older duels have stake in gold, read via stakeOf()), rolls: [{ by, max, r, at }], winner, loser, endedAt, at }`. Created and rolled only by the RPCs `deathroll_new` / `deathroll_roll` (dice rolled on the server, turns enforced). `patch_doc` lets the page set only `deleted` on them. A finished duel (`loser` set) is hidden only by an admin. Hiding a finished duel removes it from the debt ledger.
  - `bets/{id}`: `{ q, opts: [text], picks: { [playerId]: optionIndex | -1 }, result: optionIndex | -1, resolvedAt, at }`. `q`, `opts`, `cat` and `by` are fixed after creation; anyone sets the first `result`, only the author or an admin changes it.
  - `fame/{id}`: `{ who: playerId | "" (whole group), title, icon, at, auto }`. `fameCands()` derives achievements from the data, and `syncFame()` writes each new one once, under a deterministic id. Hidden ones (`deleted`) never come back. Manual entries come from the form.
  - Bets can carry gold: `bets.stakes: { [playerId]: silver }`. Pari-mutuel: losers' gold is split among the winners in proportion to their stakes. If no one with gold guessed right, nothing changes hands. Picks and stakes are frozen server-side once `result >= 0`.
  - `pays/{id}`: `{ from, to, s (silver), by, at }`, the "Рассчитались" settlements. Only the receiver (`to`, with `by` = themselves) or the admin records one, and it can't be edited afterwards.
  - The wallet (`walletDebts`/`walletPairs`) nets duels + bets − payments per pair. The rules shown in the Таверна panel must stay in sync with this logic.
  - Таверна shows who has the site open (Supabase Realtime presence via `db.presence()` in store.js, nothing stored). Online players also get a green dot on their party frame.
  - `data-view` can list several views separated by spaces (e.g. `"tavern bets"`).

- "Гильдия" tab (`#guild`): guild levels from Blizzard's WoW Forever API (undocumented so far; see the comment block in supabase.sql).
  - `guild_sync()` (pg_cron, hourly; `http` extension) fetches the guild roster server-side. The API client id/secret live in the hidden `bnet_config` table and are never committed.
  - The roster request only says who is in the guild; each level 10+ character is then fetched on its own, and `level` comes from that profile (the armory's source; Blizzard's roster lags by hours). Characters below 10 have no profile and keep the roster's level.
  - `guild/roster`: `{ name, at, members: { [slug]: { name, surname, level, cls, race, rank } } }` (`cls`/`race` are Blizzard ids, mapped by `BCLS`/`BRACE`).
  - `glevels/{YYYY-MM-DD}`: `{ at, lv: { [slug]: level }, pr: { [slug]: { [Profession]: skill } } }`, one row per day (Europe/Paris), overwritten until the day ends.
  - `gchars/{slug}`: `{ at, ilvl, ruleset, login, img, avatar, items: { [SLOT]: { id, name, q, lvl, icon, tip } }, profs: { [Profession]: { s, max, n } }, st, pvp, reps, q }`, the character sheet for level 10+ characters (opened by clicking a name in the roster). `SLOT` and `q` are Blizzard's types (`HEAD`, `FINGER_1`, `RARE`, ...). `profs` (skill, cap, known recipes; English names as in `PROFS`) also feeds the "Профессии гильдии" panel. `tip` is the item's tooltip as lines `[text, kind, right?]` (kind `g`/`y`/`m`/`""`), built on the server by `bnet_item_tip()` and shown by `gTipShow()`. `st` (attributes: `hp, pw, pt, str, agi, sta, int, spi, arm, ap, sp, mc, sc, dg`), `pvp` (`{ hk, rank, maps: [[name, played, won, lost]] }`), `reps` (`[[faction, standing, value, max, tier]]`) and `q` (`{ done, log: [quest names] }`) are drawn by `gSheetMore()`. Icon URLs are cached in the hidden `bnet_icons` table. The page only loads images from `render.worldofwarcraft.com` (`bimg()`).
  - "PvP" tab (`#pvp`): `renderPvp()` shows honorable kills per character (now, today, 7 days), the game's own PvP counters and two day-by-day charts. `glevels/{day}` also stores `hk: { [slug]: honorable kills }` and `pd: { [slug]: deaths from other players }`; kills made in a day are the difference between two consecutive rows. `gchars/{slug}.ast` is the game's statistics list `[[category, name, quantity, description]]` (kills, deaths, boss kills per dungeon, ...), read with `astOf(c, name)`.
  - "Подземелья" tab (`#dungeons`, `renderDgs()`): one card per dungeon the game tracks (`guild/dungeons`: `{ at, list: [[dungeon, achievement name]] }`). Per character the game only counts end-boss kills (`ast` entries like "Edwin VanCleef Kills (Deadmines)", mapped to cards by `BOSS_DG`), so cards use those wherever such a counter exists. The "Spelunker" achievements (`gchars/{slug}.dg`: `[[dungeon, times completed, done]]`, definitions cached in the hidden `bnet_ach` table) cover every dungeon and wing but are ACCOUNT-WIDE: a twink reports its main's numbers. They are used only for the dungeon list and, for dungeons with no boss counter (Excavation Site, three Scarlet Monastery wings), as one count per account, tagged «по аккаунту»; `dgAccounts()` groups characters with identical `dg` into accounts. `gchars/{slug}.ach` (`[[achievement, completed at (ms)]]`, also account-wide) is listed on the character sheet. Level ranges come from `DUNGEONS` via `dgInfo()` / `DG_ALIAS`. Quest progress per zone: `gzones/{slug}` is `{ at, z: [[zone, completed, quests in the zone]], other }` (zones with at least one completed quest; `other` = completed quests outside any zone). The zone lists (138 zones, one request each) are loaded by `guild_zones_fill()` from its own pg_cron job every 5 minutes until complete and cached in hidden tables (`bnet_quest_areas`, `bnet_quests`); each character's completed quest ids are kept in `bnet_char_quests`, and `guild_zones_publish()` counts them. Shown as bars on the character sheet and as a zone × character table in "Статистика". "Статистика" tab (`#stats`, `renderStats()`): record cards from the `FUN` list of `ast` counters, quests that several members have in their log (`q.log`), and a table of every counter. Both are page-only, built from `gchars`.
  - "Рецепты" tab (`#recipes`): `grecipes/{slug}`: `{ at, r: { [Profession]: [recipeId] } }` (what a level 10+ character knows) and `gcat/{Profession}`: `{ at, r: { [recipeId]: { n, c (category), ok (details loaded), i (crafted item), q, ds (description, e.g. what an enchant does), re: [[reagent, qty]], icon, iq, il, tip (crafted item tooltip lines) } } }` (the recipes someone in the guild knows plus, since 2026-11-18, the rest of the catalogue of the guild's professions; the page tells them apart with `grecipes` and shows them as «Неизученные». `iid` = the crafted item's id, linked to Wowhead). Details, icons and item tooltips are loaded in time-limited slices by `guild_recipes_fill()` (called by `guild_sync()` and by its own pg_cron job every 5 minutes; it makes no request when nothing is missing) and cached in the hidden `bnet_recipes` table. `renderRecipes()` redraws only when its data or filter changes; the search input is static markup, so `render()` never replaces it.
  - All of these are read-only for the page (not in `patch_doc`'s allow-list) and skipped by `docs_history`.
  - Dungeon page (`#dg/<dungeon name>`, view "dungeon", `renderDg()`; shared data from `dgData()`): records, who went how often, characters in the level range now, kills per day from `glevels/{day}.bk`. Art: Blizzard's `render.worldofwarcraft.com/<region>/zones/<slug>-small|large.jpg` (`DG_ART`); new Forever dungeons use Wowhead guide covers (`DG_WH`).
  - Comparison (`#cmp/<id>/<id>`, view "cmp", `renderCmp()`): two characters as mirrored bars plus two-line day-by-day charts; opened from «Сравнить с» on the character card. An id is a guild slug or `<region>.<slug>` for a watched character.
  - `wchars/{region}.{slug}`: characters outside the guild (streamers, friends), the same shape as `gchars` plus `label`, `region` and `hist: { day: { lv, il, qd, hk, dt } }`. The list lives in the hidden `bnet_watch` table; admins add and remove via `watch_add` / `watch_del`; `watch_sync()` (called by `guild_sync()`) refreshes them hourly. «Стримеры и друзья» (`#streamers`, `renderStreamers()`) shows them; a watched character opens the normal card (`#char/<region>.<slug>`).
  - Talents: `gtalents/forever` holds every class's talent trees from Wowhead's WoW Forever calculator (weekly, `talents_import()`; Blizzard has no layout API). `gchars/{slug}.tl` / `.tl2` = learned talents `[[blizzardTalentId, rank, spellId]]`; the page matches them by spell id (`talIndex()`), because Blizzard's talent ids differ from Wowhead's. Card tab «Таланты» (`cardTalents()`, `TAL_TREES`).
  - «Состав гильдии» on «Гильдия» (`renderMembers()`): joins and leaves from the daily `glevels/{day}.lv` (every member that day; the first day is the baseline).
  - «Рейды» (`#raids`): a big countdown to `RAIDS_AT` and cards from `RAIDS` (art per raid). Raid progress (Warcraft Logs) is planned for after the opening.
  - Views: "Главная" (`#home`, the default) shows the guild roster and the professions overview; "Гильдия" (`#guild`) shows the roster plus the day-by-day charts (levels, and one small chart per profession, all drawn by `lineChart()`). The original planning panels live in "Планирование (старое)" (`#plan`).
  - The chart shows characters from level 10. Line colours `--s1..--s8` follow the character (order of first reaching 10), never the rank.

## Auction («Аукцион», `#ah`)
- Our houses: 113 = PvP Horde, 116 = PvP Blackwater. WoW Forever has no realms: Blizzard lists every house of the region under any `ruleset/{n}/auctions/` path and doesn't say which ruleset is which; 113 was confirmed by an in-game price check.
- `scripts/ah.py --publish` (hourly) reads `auctions/{id}` (non-stackables, `buyout`) and `/commodities` (stackables, `unit_price`), and sends per item `[min, market (avg of the cheapest 10% of units), qty, lots, flip units?, flip cost?]` (copper) to `ah_publish` → hidden `ah_hour` (7 days, plus `t` snapshot totals and `g` per-item flow `[units now, new, gone]`) and `ah_day` (30 days). It also stores the price ladder of stackables (`ah_meta` 'ladder:<house>') and skips a snapshot it already published.
- "Gone" / "sold" numbers are estimates (previous units + new − now: sold, cancelled or expired) and must be labelled as such.
- Page reads: `ah_latest`, `ah_before`, `ah_item`, `ah_names`, `ah_totals`, `ah_ladder`, `ah_flow24`, `ah_spark`, `ah_prev_g`, `dim_item_get`, all cached per house and snapshot (`ahGet`, `ahFetch`). Tabs: Обзор, Тренды, Предметы (tracker-style list with filters, sparklines, hover card), Сырьё, Вендор флип, Крафт гильдии, Крафт → NPC.
- Money is shown as `12g 34s 5c` (`fmtCu` returns HTML with coloured letters via `--coin-g/s/c`; `fmtCuT` is the plain form for SVG text).
- GitHub's scheduler skipped the scheduled runs at first, so a TEMPORARY pg_cron job `ah-watchdog` (`ah_watchdog()`, :50 hourly) dispatches ah.yml / dims.yml when data is stale, with a fine-grained token in `bnet_config.gh_token`. Remove it (`select cron.unschedule('ah-watchdog');`) once GitHub runs them on its own.

## Reference data (see docs/DECISIONS.md)
- Reference data ("dimensions": item names and descriptions, recipes, achievements, quests) lives in the database and is refreshed daily; facts (characters, auction) hourly. Blizzard's API is the source; Wowhead only for what Blizzard lacks, marked with its source. The page never calls a game API itself (exception: «Хотелки», where a player pastes a Wowhead link).
- Item descriptions: hidden `dim_item` (`src` blizzard / wowhead / none), filled by `scripts/ah.py --dims` and for new items hourly. Recipes, achievement descriptions and quest lists: the 5-minute fill jobs re-fetch rows older than a day (`at` / `item_at`). Icons and 3D display ids are fetched once per id.

## Login and permissions
- A quiet "I'm kute expat" link fixed in the bottom-right corner opens the login dialog (logged in: account controls sit in the bottom-left corner on screens 900px+, in the footer below that) (pick a player, enter a password). The session token is kept in localStorage (`wf-token`) and sent with every write. Logged out, the site is read-only.
- Server side (supabase.sql): `accounts` (bcrypt hashes, `is_admin`, `must_change`) and `sessions` are hidden tables. RPCs: `login`, `whoami`, `logout`, `change_password` (min 4 characters, not "Forever"), `admin_accounts`, `admin_reset` (back to "Forever"), `admin_set_admin`.
- `patch_doc(p_token, ...)` enforces the rights: non-admins change only their own player row, vote, bet picks, goal ticks, wants and deaths; admin-only for meta, deleting players and adding players. `deathroll_*` take the token, so you always roll as yourself.
- The page mirrors those rules (`mine(id)`) to grey out other people's controls. The database is what actually enforces them.
- Initial passwords are never committed (the repo is public). Kirill's admin account comes from a one-off script kept outside the repo. Others start with "Forever" and must change it before they can write.

## Code conventions
- `render()` re-renders every section from state. `editing()` holds off re-rendering while an input or select has focus, so keep that guard working.
- Clicks are handled by one delegated listener that dispatches on `data-act`. Add new actions there.
- The countdown and roadmap band is shown on "Скоро" (`data-view="soon"`); the sidebar shows a small countdown and «Рейды» a big one, all updated by `tick()`.
- Colors, radii, shadows and the sidebar material are CSS custom properties on `:root` (`--radius-lg/md/sm`, `--shadow-1/2`, `--material`, `--bar` for neutral data bars, `--coin-g/s/c` for money), dark theme by default plus a light theme. Use the tokens, never hardcoded colors. The font is the system font (no web fonts). Gold (`--accent`) marks the current choice, not ordinary data.
- Key constants: `RELEASE`, `LAUNCH_AT`, `RAIDS_AT` (raid unlock, the first countdown), `HC_AT` (a guessed Hardcore start, a month after raids; no official date), `CORE` (players who can't be deleted), `CLASSES`, `RACES` and `PROFS`. The game is Classic-era, so it has 9 classes and 8 races, plus the WoW Forever race Skyborne (neutral: stored as `Skyborne-A` or `Skyborne-H` depending on the faction chosen).
- Escape all user text with `esc()`.

## Rules
- Don't change the shape of the stored data without also adding migration SQL to `supabase.sql`, written so it can be re-run safely.
- No build tools or npm dependencies in the app. External scripts come only from pinned CDN versions.
- Test locally with `py -m http.server 8000` (Python is `py` on this machine; plain `python` is the Microsoft Store stub), check the page at phone width (375px), and confirm the browser console has no errors.
- The Supabase connector (project `hgqjimpyxfcaaflapcnw`) can run SQL on the live database. Keep `supabase.sql` the source of truth and re-runnable; have SQL changes reviewed before applying them live.
- Keep changes small and show me the diff before any large refactor.

## Skills to use
- Load `supabase-postgres-best-practices` before any change to `supabase.sql` or the live database (tables, RPCs, `patch_doc`, triggers, pg_cron jobs, indexes, grants), and `supabase` for anything else Supabase (Realtime, Edge Functions, the connector, logs, advisors). Where their advice is generic, this project's rules win: one `docs` table with jsonb, anon is read-only, every write goes through a security-definer RPC, and `supabase.sql` must stay re-runnable.
- After applying SQL live, run the security advisors (`get_advisors`) and fix any new warnings.
- Use `playwright-cli` for the local page check (375px width, console errors) instead of only describing it; it's a dev tool only, never a dependency of the app.
