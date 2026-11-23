# Changelog

## 2026-11-23 (English interface)

- The whole site is now in English (the group plays the English client): menus, pages, dates (22 Nov), numbers (7,040), money (12g 34s). Text the players wrote themselves (bets, goals, tasks) stays as written; older Hall of Fame entries are shown in English.
- Fixed: «Вчера» (now "Yesterday") showed on every page instead of only on the home page.

## 2026-11-23 (security rules, faster first load, raid readiness, yesterday)

- Writes are checked more strictly (already live in the database): a player row accepts only known fields, so one bad value can no longer break the page for everyone; a bet's question and options can't change after creation and only its author or an admin can change a result once set; only an admin hides a finished duel; «Рассчитались» is recorded by whoever received the gold. The page also keeps drawing other sections if one fails.
- The page loads about 0.5 MB instead of ~1.9 MB: the recipe catalogue and talent trees are fetched only when «Рецепты», a character card, the comparison or «Аукцион» is opened.
- «Аукцион»: the big tiles became one compact strip (2 columns on phones) with the snapshot time first and the value of all listings; «Ушло за час» is hidden until its estimate is checked.
- «Рейды»: «Готовность к рейду», a table of the group's characters with level, pace, an estimated date of 60 (marked as an estimate), item level and reputations.
- Home: «Вчера», what each character did yesterday (levels, quests, dungeon bosses, honorable kills, profession points, deaths).

## 2026-11-22 (raids page, guild membership, daily reference refresh)

- «Рейды»: a big countdown to the raid opening and cards for Barrow Deeps, Hyjal Summit and Onyxia's Lair with art; guild progress comes after the opening.
- «Гильдия» → «Состав гильдии»: members now, joins and leaves in the last week, a member-count chart and a log of who joined or left, from the daily roster snapshots.
- Recipes, achievement descriptions and quest lists are refreshed from Blizzard once a day instead of being loaded once (docs/DECISIONS.md).

## 2026-11-22 (auction: item list redesign)

- «Предметы» works like an auction tracker: categories with counts and sorts on the left, quick views (most turnover, selling fast, dropped in the last hour, under 1g, below market, rare and above, new in Forever, below vendor price, running low), filters by rarity, level, price, units gone and listed; columns for the last hour's change, market price (explained), listed, gone in 24 h and sell-through (both estimates), and a 7-day sparkline; 50/100/200 rows.
- Hovering an item shows its description with the lowest buyout, market price, listed and gone in 24 h. A new tile «Ушло за час» estimates the gold that left the auction in the last hour.
- Reference data (item names, prices, icons, descriptions) now lives in the database and is refreshed daily by a GitHub Actions job, Blizzard's API first and Wowhead's WoW Forever data (marked) only for what Blizzard lacks; the page no longer asks Wowhead for item descriptions. Needs `supabase.sql` re-run. See `docs/DECISIONS.md`.

## 2026-11-22 (auction: money format, flow data)

- Auction prices read like in the game: 12g 34s 5c, with gold, silver and copper letters in their colours.
- The hourly auction job now also counts, per item, the units listed, new this hour and gone this hour (sold, cancelled or expired: an estimate), for the upcoming item list. Needs `supabase.sql` re-run.

## 2026-11-22 (auction: trends)

- «Аукцион» → «Тренды»: the latest snapshot against one 1, 6 or 24 hours earlier: biggest price rises and drops, new vendor flips, items being bought up or flooded, new on the auction and gone.

## 2026-11-22 (auction: overview, craft for vendors)

- «Аукцион» → «Обзор»: lots, items, new and vanished lots per hour (and per day), and the hours of the day when most lots get listed. Starts filling after deploy.
- «Аукцион» → «Крафт → NPC»: guild recipes whose product a vendor pays more for than the reagents cost; the most to pay for the main reagent (with an optional profit per craft), how much of it is on sale up to that price, how many crafts that makes and the total profit. Needs `supabase.sql` re-run.

## 2026-11-22 (auction: vendor flip)

- «Аукцион» → «Вендор флип»: lots listed below what an NPC vendor pays: the most to pay per unit, how many units, what to invest, profit and margin; filters for guild profession reagents and a minimum margin.

## 2026-11-22 (auction: raw materials, vendor reagents)

- «Аукцион» → «Сырьё»: herbs, ore and stone, leather, cloth, cooking, elemental and enchanting materials on our auction, with the same prices, daily change and sorting as the item list.
- «Крафт гильдии»: reagents that NPC vendors sell (thread, vials, dyes, flux, spices, salt, rods) now count at the vendor's price when it's lower than the auction's.

## 2026-11-22 (auction: guild crafting)

- «Аукцион» → «Крафт гильдии»: every recipe someone in the guild knows, priced from the latest snapshot: reagent cost, sale price after the auction cut, profit and margin, who can craft it; reagents and products open the item card.

## 2026-11-22 (auction)

- «Аукцион» is live: our PvP Horde and Blackwater houses from Blizzard's hourly snapshot. Totals (lots, items, units, what got dearer or cheaper over a day, items cheaper than a vendor pays), a searchable list with type filter and sorting, and an item card with price and quantity charts by hour (7 days) and by day (30 days).
- Prices are collected every hour by a GitHub Actions job (`scripts/ah.py`), not by the database. Needs `supabase.sql` re-run (auction tables and item names).

## 2026-11-20 (talents, streamers)

- Character card: «Таланты» tab with the game's talent trees, rank badges, prerequisite arrows, a tooltip per talent and both sets (dual spec).
- «Стримеры и друзья» page: cards, levels day by day; each opens the full character card. Eight more streamers added.
- New dungeons of Forever get the cover picture of Wowhead's guide; race and level bars on the home page are coloured.
- «Аукцион»: placeholder page with the plan.

## 2026-11-20 (character comparison)

- Streamers and friends outside the guild can be compared too (Xaryu Forever, Shobek Forever to start); an admin adds or removes them on the comparison page. Needs `supabase.sql` re-run.
- Compare two characters: «Сравнить с» on the character card opens a side-by-side page with mirrored bars (level, gear, stats, PvP, professions, dungeons, game counters) and both characters on the day-by-day charts.

## 2026-11-20 (Apple-style redesign, dungeons)

- New look across the site: system font, borderless rounded surfaces, iOS-style segmented controls and capsule chips, translucent sidebar; gold is kept for the current choice.
- «Подземелья»: tiles with Blizzard's official dungeon art; each opens its own page (records, who went how often, who fits by level now, runs day by day).

## 2026-11-20 (design pass)

- «Профессии»: new top block with 0–300 skill bars, switchable between «По профессиям» and «По персонажам».
- Recipe catalogue: the learned/unlearned switch and sort order moved into the filter column; «Профессии в цифрах» folded at the bottom.
- Wide monitors: content grows to 1500px (1900px from 2300px); Hall of fame flows in columns.
- News: cards with a short text and the article picture (after `supabase.sql` is re-run).

## 2026-11-18 – 2026-11-20

- The redesigned site is now the main page; the previous version stays at `old.html`, and old `v2.html` links redirect.
- «Профессии»: summary infographics, catalogue filters (category, quality, item level, required level, slot, stat,
  crafter, kind), sort order and Wowhead links.
- Recipes nobody in the guild has learned yet, from each profession's full catalogue.
- Favourite recipes and craft orders («Заказать» → «Беру» → «Готово»), with a menu badge for orders waiting for you.
- Character card: achievements with icons, categories and points; card lists no longer hidden on narrow screens.

## 2026-11-16 – 2026-11-17

- Character card: 3D model with full screen view, character list on the left, «Прогресс по дням» tab
  (level, professions, PvP, deaths, item level, quests, reputation, dungeon bosses).
- WoW Forever news page.
