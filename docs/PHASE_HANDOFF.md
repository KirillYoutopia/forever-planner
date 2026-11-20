# Phase handoff

Last updated: 2026-11-20 (design pass). Only verified facts; "not verified" says so explicitly.

## Current state

- Live site: https://kirillyoutopia.github.io/forever-planner/ (GitHub Pages from `main`).
  - `index.html` is the redesigned site (was `v2.html`). `old.html` is the previous site, unchanged.
    `v2.html` only redirects old links to `./` keeping the `#...` part.
- Work branch: `redesign/v2`, PRs into `main`. The user merges by saying «влей» / «вливай»; nothing is merged otherwise.
  Merges are done through the GitHub API (no `gh` CLI on this machine; token from `git credential fill`).
- Last merge: PR #31 (`01c0179`). `redesign/v2` has no commits beyond `main`.
- Supabase: everything server-side lives in `supabase.sql` (re-runnable). The user runs it by hand in the SQL Editor.
  Edge Function `modelviewer` (proxy for Wowhead's 3D viewer files) is deployed under that name, JWT verification off.

## In progress on `redesign/v2` (2026-11-20, character comparison, not merged)

- `#cmp/<slugA>/<slugB>` (view "cmp", `renderCmp()`, section `#cmp-box`): mirrored bars, the bigger value highlighted
  (deaths and game counters never), two-line day-by-day charts. Opened from «Сравнить с» on the card; swap button and
  two pickers on the page. Page-only, no data changes.
- Verified in headless Chrome (1600px dark/light, 390px), no console errors, no overflow.
- Characters outside the guild ("Стримеры и друзья"): hidden `bnet_watch` (id `<region>.<slug>`), `watch_fetch`/`watch_sync`
  (called at the end of `guild_sync`, no cron change), admin RPCs `watch_add` (fetches at once, fails on unknown names) and
  `watch_del` (soft delete). Page reads `wchars/{id}` incl. `hist` per day. Seeded: us.xaryu-forever, us.shobek-forever.
  Verified on the page only with injected fake `wchars` data and a faked admin login. NOT verified: the SQL itself
  (not run), Blizzard's profile field names for class/race (`character_class`/`race`, written defensively), US region access.

## Done earlier on 2026-11-20 (merged as PR #31, `01c0179`)

- Apple-style restyle: token values changed in all three theme blocks (spec by a design agent), Google Fonts removed
  (system font), one override block "Apple-style pass" at the end of the main <style>. Race/level bars use `--bar`.
- Dungeons: tiles with official art (`render.worldofwarcraft.com/eu/zones/<slug>-small|large.jpg`, map `DG_ART`; the new
  Forever dungeons have no art), dungeon page `#dg/<name>` (view "dungeon", `renderDg()`, data from `dgData()`):
  records, leaderboard, characters in level range now, kills per day from `glevels[].bk`. Page-only, no data changes.
- Verified: headless Chrome via DevTools, live data, 1600px dark/light and 375–390px; no console errors, no overflow.
- Not verified: every page after the restyle (checked home, character card, dungeons, dungeon page, PvP, recipes, phone home).

## Done in the design pass (2026-11-20, merged as PR #30, `8a7fecc`)

- «Профессии»: new first block «Профессии гильдии» with 0–300 bars (filled = skill, light = up to the rank cap, ticks at 75/150/225),
  switch «По профессиям» / «По персонажам» (`gpMode`). Order: block → orders → catalogue → «Профессии в цифрах» (folded `<details>`).
- Catalogue: «Изученные/Неизученные/Все» and «Порядок» live in the filter column now; «Сбросить фильтры» resets them too.
- Wide screens: `.wrap` 1500px from 1700px viewport, 1900px from 2300px. Hall of fame timeline in CSS columns from 1300px.
- News cards (Discord-like): `news_sync()` stores `[title, link, ts, kind, text, image]`; images only from `wow.zamimg.com`.
  Needs `supabase.sql` re-run; until then cards show without text and pictures.
- Apple-style touches (apple-design skill): press feedback, translucent mobile top bar, softer cards.
- Project CLAUDE.md: the 2026-11-18 proposals applied (user approved).
- Verified: headless Chrome via DevTools protocol against live data, 2400px / 1400px dark / 375px; no console errors,
  no horizontal overflow at 375px. NOT verified: the new `news_sync()` SQL (not run), news pictures on the page.

## Done in the previous phase (all merged)

- Character card: 3D model (Wowhead viewer in an iframe via the `modelviewer` proxy), character list on the left,
  «Прогресс по дням» tab (level, professions, PvP, deaths, item level, quests, reputation, dungeon bosses),
  achievements with icon/category/points (`guild/achinfo`, filled by `guild_ach_fill`).
- «Профессии» page:
  - «Профессии в цифрах» summary (learned of catalogue per profession, quality of crafted items).
  - Catalogue filters: category, quality, item level, required level, slot, stat, crafter (player with twinks or character),
    kind (item / enchant), «показать только» (★ favourites, with orders); sort order; Wowhead link per recipe.
  - «Изученные / Неизученные / Все»: `gcat` now holds the whole catalogue of the guild's professions
    (2494 recipes, 543 learned on 2026-11-18). `guild_recipes_fill` loads details for all of them, learned ones first.
  - Favourites (`players.fav`) and craft orders (`orders` collection, rules in `patch_doc`), «Заявки на крафт» panel,
    menu badge with orders waiting for the logged-in player.

## Verified

- Filters, learned/unlearned switch, orders panel and badge: in headless Chrome against live data, with a faked login
  and fake orders injected into the page (writes disabled). Layout at 1400px and inside a 375px frame.
- Page swap: `index.html` == former `v2.html`, `old.html` == former `index.html`; live site serves all three URLs
  and `v2.html#char/...` lands on `/#char/...` with the card open.

## Not verified

- `patch_doc` rules for `orders` against the real database with two different accounts (take / done / cancel / refuse).
- Whether the user re-ran `supabase.sql` after the orders change (without it, creating orders fails).
- Achievement fields from the Forever API (points, parent category, icons): written defensively, never seen.
- Size of the `gcat` documents once the whole catalogue is loaded, and page load time on the «Профессии» page.
- Dark theme on the new «Профессии» blocks; how the menu badge looks.
- Catalogue contents: 592 Leatherworking / 507 Blacksmithing recipes is far more than classic, so it likely includes
  recipes from other versions or not yet available. The API cannot tell them apart.

## Open ideas (not started, need the user's go-ahead)

1. ~~Compare two characters~~: done 2026-11-20.
2. Discord notifications for craft orders: webhook into a guild channel via a `docs` trigger and `pg_net`; webhook URL
   in a hidden table, never in the repo. Open question: @mentions of crafters (needs their Discord ids).
3. Cron load: news hourly instead of every 30 minutes; `guild_recipes_fill` / `guild_ach_fill` publish only when they
   loaded something; `guild_sync` calls `guild_ach_fill(5)`. The user said NOT to change cron for now (2026-11-18).
4. Recipe sources (trainer / vendor / drop / quest) parsed from Wowhead on the server. Deferred; links only for now.
5. Hide catalogue recipes Blizzard returns with neither reagents nor a crafted item, if they turn out to be noise.
6. Faster 3D load (Cloudflare cache in front of `modelviewer`). The user said it can wait.
7. Abandoned quests (diff the quest log between syncs): an idea only, not planned.
8. Raider.IO population stats (forever.raider.io/population/eu/pvp): no public API or CORS; the page is server-rendered HTML.
   Possible only as a server-side scrape (like news) into a read-only doc, which needs a new cron job. Not started.
9. Site-wide Apple-style restyle (type scale, materials, spacing): only touched blocks were restyled; a full pass needs the user's go-ahead.

## Pending decisions

- `docs/INSTRUCTION_PROPOSALS.md`: proposed project `CLAUDE.md` updates (old.html, full catalogue in `gcat`, orders,
  favourites). Not applied until the user approves.

## Next recommended step

Check craft orders end to end with two accounts on the live site (after re-running `supabase.sql`), then item 1
(character comparison) or item 2 (Discord), whichever the user picks.
