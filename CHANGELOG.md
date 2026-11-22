# Changelog

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
