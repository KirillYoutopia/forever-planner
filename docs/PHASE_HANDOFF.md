# Phase handoff

Last updated: 2026-11-22. Only verified facts; "not verified" says so explicitly.

## Current state

- Live site: https://kirillyoutopia.github.io/forever-planner/ (GitHub Pages from `main`). `index.html` is the site, `old.html` the
  previous one, `v2.html` only redirects.
- Everything is merged: last PR #34 (`0c7734b`). Branch `redesign/v2` has nothing beyond `main`; working tree was clean at 2026-11-22.
  The user merges only on «влей» / «вливай», via the GitHub API (no `gh` here; token from `git credential fill`).
- Supabase: all server code is in `supabase.sql` (re-runnable); the user runs it by hand in the SQL Editor. He has run it, plus
  `talents_import()` (467 talents saved) and `watch_fetch('us.xaryu-forever')`. Cron was NOT changed (his instruction since 2026-11-18).
- 2026-11-20 shipped (PRs #30–#34): Apple-style restyle (system font, borderless rounded surfaces, `--radius-*`, `--shadow-*`,
  `--material`, `--bar`); «Профессии» bars 0–300; dungeon tiles with art + dungeon page `#dg/<name>`; news cards with text/picture;
  character comparison `#cmp/<a>/<b>`; talents tab; «Стримеры и друзья» `#streamers`; `#ah` auction placeholder.

## Talents (what is verified)

- Layout comes from Wowhead's calculator file (`https://nether.wowhead.com/forever/data/talents-classic`), saved weekly by
  `talents_import()` into `gtalents/forever` (467 talents, 180 KB). Blizzard has no talent layout API for Classic-era.
- Blizzard's `/specializations` confirmed on real data (Xaryu): per talent `talent.id`, `talent_rank`, `spell_tooltip.spell.id`,
  `spell_tooltip.description` (text of the learned rank). Its talent ids (134xxx–135xxx) differ from Wowhead's (104xxx–113xxx), so
  `bnet_talents()` stores `[id, rank, spell id]` and the page matches by spell id against each talent's rank spells (`talIndex()`).
  Result for Xaryu: 16 of 16 learned talents matched. `tlx` keeps one raw talent entry per sheet for checking the shape.
- Dual spec: `tl` (active) / `tl2`; the other streamers already have a second set (e.g. Jokerd 20 talents).
- NOT yet seen: guild characters (`gchars`) have no `tl` until the next hourly `guild_sync` (check:
  `select id, data->'tl' from docs where coll = 'gchars' limit 3;`). The 9 other streamers were synced before the spell-id fix:
  their `tl` has no spell ids until the next sync; refresh one by one with `select public.watch_fetch('<id>');`
  (`watch_sync()` of all 10 makes >100 Blizzard requests and times out in the SQL Editor, although it does finish on the server).
- Idea: for learned talents show Blizzard's own `spell_tooltip.description` instead of Wowhead's text.

## Streamers («Стримеры и друзья»)

- Hidden `bnet_watch` (id `<region>.<slug>`), `watch_fetch(p_id, p_tok, p_icons, p_full)`, `watch_sync()` (called by `guild_sync`),
  admin RPCs `watch_add` (light fetch: profile + pictures only) / `watch_del`; page reads `wchars/{id}` incl. `hist` per day.
- Seeded 10: Xaryu Forever, Shobek Forever, Grubtor Steelheart (EU), Pshero Brickasso (EU), Black Lizard, Esfand Television,
  Savix Ashwalker, Pikaboo Themove, Asmongold Thereal, Jokerd Prime (EU). Names checked on forever.raider.io. US characters work.
- Their cards open as normal character cards (`#char/us.xaryu-forever`) and can be compared with guild characters.

## Auction («Аукцион», `#ah`, placeholder only)

User's answers (2026-11-22): Horde + neutral (Blackwater) houses, all items, history 30 days (Blizzard API terms: max 30-day TTL),
OK to add a new component (Edge Function or GitHub Actions) for parsing snapshots.
Research: Blizzard Game Data API `connected-realm/{id}/auctions/{2 Alliance | 6 Horde | 7 neutral}` in namespace `dynamic-forever-eu`
(NOT yet called by us; goblinkassa.vmikhailov.dev proves it works: EU PvP Horde ≈ 326k lots, hourly). No seller in data. Their own API
must not be used (their terms forbid it). One snapshot ≈ 30 MB JSON: too big to parse in free-tier Postgres (`http` extension).
Risks of the new component (to discuss before building):
- GitHub Actions: scheduled runs can lag by minutes and are paused after 60 days without repo activity; Blizzard secret goes into
  Actions secrets; writing back needs an RPC guarded by a shared secret (`ah_publish`), never the anon key. Plenty of memory.
- Edge Function: tight memory/time limits for a 30 MB response (not checked); secrets in Supabase.
- "All items" needs names/icons/quality for ~5–10k items: load in slices into a hidden cache table (like `bnet_recipes`).
- Storage: keep only aggregates per item (min buyout per unit, median, quantity, lots); ≈0.3–1 MB/day; delete after 30 days.
Recon DONE 2026-11-22 (node script with the creds from `../wow-guild-backend/.env`, values never printed; raw files only in the
session scratchpad):
- Forever has NO realms / connected realms (`connected-realm/index` in `dynamic-forever-eu` = 404; characters and guilds carry no
  realm). Instead: `ruleset/index` → 1 PvP, 2 Normal, 3 Roleplay, 15 Roleplay PvP. Our characters: `ruleset` = 1 (PvP).
- Houses: `ruleset/1/auctions/index` lists 15 ids: Alliance 110 111 112 119 123, Horde 113 114 115 120 124, Blackwater
  116 117 118 121 125. 112/115/118 are empty. Disjoint lot ids and very different prices (Peacebloom 2.40s in 113 vs 0.38s in 114)
  → each triple is a separate server economy. The API does NOT say which one is ours: identify with an in-game price check.
  SOLVED: the ruleset in the path is ignored (`ruleset/2|3|15/auctions/index` list the same ids; `ruleset/2/auctions/113` = same
  data). The 12 non-empty ids are ALL houses of the region: 4 rulesets × (Alliance, Horde, Blackwater), as wowfah.com describes
  ("no realms; everyone on your ruleset and faction in your region shares one house"; Blizzard doesn't say which ruleset is which).
  So 110/113/116 and 111/114/117 (big) = PvP and Normal, 119-121 and 123-125 (small) = RP / RP-PvP, 112/115/118 empty.
  Regions are split by host, not by id: us/kr/tw list the same 15 ids, but US 113 shares 0 lot ids with EU 113. So the 4 non-empty
  EU PvP economies (110/113/116, 111/114/117, 119/120/121, 123/124/125) are inside EU (guess, not verified: language servers).
  OURS = Horde 113 (user's in-game check 2026-11-22: Peacebloom min 2s40 = 113's price). Blackwater: probably 116 (id pattern
  110/113/116; prices only weakly closer to 113 than 117's are: median |log ratio| 0.51 vs 0.56), NOT confirmed in game.
  Lots incl. commodities: 113 = 308k, 114 = 284k, 120 = 34k, 124 = 40k (Goblin Kassa's "EU PvP Horde ≈ 326k" fits 113 or 114).
- Two endpoints per house: `ruleset/1/auctions/{id}` = non-stackables, every lot `quantity` 1, `buyout`/`bid` (copper), item
  `{id, context?, modifiers?, bonus_lists?}`, `time_left`; `ruleset/1/auctions/{id}/commodities` = stackables with `unit_price`.
  No seller. Top keys: `_links, auctions, id, name, commodities, ruleset`.
- Sizes (gzip on the wire, <0.6 s each): big Horde 113: 16.5 MB / 166k lots / 5.6k items + commodities 12.4 MB / 1.36k items /
  2.6M units; 114 similar; small houses (120, 124) ≈ 1.5–1.8 MB each. Last-Modified ≈ hourly. ~300 of 1360 commodity ids are > 200000
  (new Forever items, need names from the item API).
Decisions (2026-11-22): GitHub Actions + Python (stdlib only). Site: hourly per-item aggregates for 7 days + daily for 30 days.
Local: raw gzipped snapshots kept LONGER than 30 days in `D:\PythonProject\wow-ah-data` (user's choice, aware of the Blizzard terms
note above); run by hand for now (no Task Scheduler).
Done: `scripts/ah.py` (uncommitted at time of writing): fetches 113/116 items + commodities, archives raw gz as
`YYYY/MM/DD/HHMM_<house>_<kind>.json.gz` (time = Last-Modified UTC, no duplicates), prints [min, market (avg of cheapest 10% units),
qty, lots]. Verified: `--selftest`, a live run, a repeat run. Snapshot Last-Modified stayed 13:23 UTC for >1 h → roughly hourly.
Built (uncommitted, SQL NOT run yet): `supabase.sql` section "auction prices": hidden `ah_hour(house, at, d)` (7 days) and
`ah_day(house, day, at, d)` (30 days, Paris day: min of mins, avg of the rest, recomputed on every publish), `d` =
`{item id: [min, market, qty, lots]}`; `ah_publish(secret, house, at, d)` (anon-callable, guarded by `bnet_config` k='ah_secret',
houses 113/116 only, also deletes old rows), page reads `ah_latest(house)`, `ah_item(house, item)`. Kept out of `docs` because
the page loads all of `docs` + realtime. `scripts/ah.py --publish` (Supabase URL/anon key read from config.js);
`.github/workflows/ah.yml` hourly at :35 + manual run. Body ≈ 180 KB (113) / 104 KB (116). Reviewed by an independent agent:
no blocking issues. Verified: selftest; publish request reaches Supabase (404 = function not created yet).
LIVE since 2026-11-22: SQL run, `ah_secret` + GitHub secrets set by the user, merged as PR #35 (`40b3ad0`). Manual
workflow run succeeded; `ah_latest` returned 7003 items for 113 and 4226 for 116 (snapshot 14:23 UTC), `ah_item` returned one
hourly + one daily point. Anon can't read `ah_hour` directly (401); wrong secret → `denied`.
Page `#ah` LIVE 2026-11-22 (PR #36, `0e16b77`; names filled by the first run: 7083 ids, all named; checked on the live site): house switch (113/116, localStorage `wf-ah-house`), KPIs, search
(English names) + type filter + sortable list (100 rows, «Показать ещё»), item card `#ah/<id>` with price/quantity charts
(`ahChart`, same hover as `lineChart`; hourly 7 d / daily 30 d). Goblin Kassa note removed. Item names: hidden `ah_meta`
('items' / 'classes'), filled by `scripts/ah.py --publish` for ids it hasn't seen: Blizzard search in `static-forever-eu`, then
`static-classic1x-eu` (Forever's catalogue lacks lots of plain Classic gear), then Wowhead tooltip (`dataEnv=16`, max 400/run);
on live data all 7058 ids got names. New Forever icons (Skyborne) are not on Blizzard's image server: those show no icon.
Reads: `ah_names()`, `ah_before(house, at)` (24 h comparison). Verified in headless Chrome 1400/375 px with live snapshots and
names built by the same code; charts only with injected fake history (one real snapshot at the time). Reviewed by an independent
agent; its 3 findings fixed (Wowhead limit marked ids unknown forever; "no snapshots" state stuck on «Загружаю…»; a failed name
lookup failed the hourly run).
«Крафт гильдии» tab (2026-11-22, page-only, no data changes): `ahCraftRows` / `ahCraftHtml`. Recipes known by guild members
(`grec`), reagents matched by English NAME to ids via `ah_names` (`gcat.r[id].re` has names only), cost = Σ market × qty, sale =
product min × `q` (crafted quantity) × (1 − 5%, or 15% for Blackwater 116). Live check: 602 recipes, 2 with an unpriced reagent
(Raw Summer Bass unknown, SAF-T Casing not listed), 69 enchants without a product, 49 products not listed, 483 fully priced,
144 profitable. Known gap: NPC-vendor reagents (thread, vials, flux) are priced at the auction (shortcut comment in code);
rare reagents with few lots skew the cost (e.g. Refined Deeprock Salt ≈ 70g in one snapshot).
Vendor reagents + «Сырьё» (2026-11-22): `ah_meta.items` entries got a 9th field = vendor buy price per unit
(`purchase_price / purchase_quantity`); `scripts/ah.py` re-looks up once every Blizzard-sourced entry with < 9 fields. Blizzard's
API doesn't say WHICH items vendors sell, so `AH_VENDOR` (31 ids: thread, vials, dyes, flux, spices, salt, rods, wood, milk,
water, flour, bleach) is hand-made (inferred, flagged in the page note); such reagents count at min(vendor, auction).
Local check with the new catalogue: 15 vendor reagents used in 208 places, profitable recipes 144 → 147. «Сырьё» tab = item
list filtered by Trade Goods subclass (`AH_RAW`: 7.9 herbs, 7.7 metal & stone, 7.6 leather, 7.5 cloth, 7.8 cooking,
7.10 elemental, 7.12 enchanting). Until the first run after deploy the live catalogue has no vendor prices (page falls back to
the auction price).
LIVE: PR #38 (`f5ce89f`) + #39 (search retries). On GitHub's runner Blizzard's search answered HTTP 500 twice in a row (locally
the same lookups passed), so `search()` now retries 5xx twice and logs the failing query; the next run backfilled 6920 entries
(vendor price present on 6920 of 7130; the rest are Wowhead-sourced or unknown). Live check: 15 vendor reagents, «Сырьё» 40 herbs.
Next ideas: craft profit on the recipe cards in «Профессии»; stack size per item for gatherers.

## Pending decisions

- `docs/INSTRUCTION_PROPOSALS.md`: proposals for project `CLAUDE.md` NOT applied (dungeon page + design tokens; comparison + `wchars`;
  talents, `#streamers`, `#ah`). Apply only on the user's approval.

## Open ideas (need a go-ahead)

1. Discord notifications for craft orders (webhook via `pg_net`, URL in a hidden table; open question: @mentions need Discord ids).
2. Raider.IO population stats (no public API; server-side scrape of forever.raider.io/population/eu/pvp, needs a new cron job).
3. Picture for Shaper's Terrace (Wowhead has no guide yet); dungeon art is `DG_ART` (Blizzard zones) / `DG_WH` (Wowhead guide covers).
4. Recipe sources (trainer/vendor/drop) parsed from Wowhead; cron-load tidy-ups (not allowed for now); Cloudflare cache for `modelviewer`.

## Not verified / known gaps

- News pictures and descriptions on the live page (SQL was re-run; `news_sync` runs every 30 min): not looked at.
- Talents for guild characters on the live page; `patch_doc` rules for `orders` with two real accounts.
- Everything was checked in headless Chrome with live data; the user's own phone screenshots are the only real-device check.

## Working notes for the next session

- Python 3.13.9 IS installed: run it as `py` (plain `python` hits the Microsoft Store stub). `gh` CLI not found in PATH (checked
  2026-11-22). Node 24 is also there. Old note: served with a tiny node static server on port 8000; screenshots via Chrome headless + DevTools (scripts
  lived in the session scratchpad and may be gone).
- Editing `supabase.sql` / `index.html` from scripts: NEVER use `String.replace` with text containing `$$` or `$'` (it corrupted the SQL
  once; caught by review). Use plain splices (`indexOf` + `slice`). Line endings (checked 2026-11-22): git stores LF; the working
  copy of `supabase.sql` is CRLF, `index.html` / `CHANGELOG.md` / docs are LF. Keep whatever the file already has.
- Send risky or SQL changes past an independent reviewer agent; report only what was actually run.
