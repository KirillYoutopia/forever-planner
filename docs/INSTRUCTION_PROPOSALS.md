# Instruction proposals

Proposed changes to CLAUDE.md files. Not active until approved.

## 2026-11-18: project CLAUDE.md, after v2 became the main page (APPLIED 2026-11-20, approved by the user)

**Reason:** the redesigned site moved from `v2.html` to `index.html`; the old page is now `old.html`. The data model also gained
the full recipe catalogue in `gcat`, craft orders and favourites, none of which CLAUDE.md describes.

**Affected file:** `CLAUDE.md` (project)

**Proposed wording:**

1. In "Stack and files", after the `index.html` line:
   ```
   - `old.html`: the previous version of the site, kept unchanged. `v2.html` only redirects old links to `index.html` (keeping the `#...` part).
   - `supabase/functions/modelviewer`: Edge Function that proxies Wowhead's 3D model viewer files for the character card.
   ```
2. In the "Рецепты" bullet, replace "(only recipes someone in the guild knows)" with:
   ```
   (the recipes someone in the guild knows plus, since 2026-11-18, the rest of the catalogue of the guild's professions; the page tells them apart with `grecipes` and shows them as «Неизученные». `iid` = the crafted item's id, linked to Wowhead)
   ```
3. New bullet under the data model:
   ```
   - `orders/{id}`: `{ by, prof, rid, n, note, st: "open" | "taken" | "done", taker, doneAt, at, deleted }`, craft orders on the "Профессии" page. `patch_doc` lets the author create, comment and cancel; a player whose main or twink knows the recipe takes it and marks it done. `players/{id}.fav` `{ "Profession:recipeId": true | false }` holds favourite recipes. The menu badge (`renderOrderBadge()`) counts orders waiting for the logged-in player.
   ```

## 2026-11-20: project CLAUDE.md, dungeon page and the restyle

**Reason:** a new view (`#dg/<name>`) and new design tokens exist that CLAUDE.md does not describe; the old fonts are gone.

**Affected file:** `CLAUDE.md` (project)

**Proposed wording:**

1. At the end of the "Подземелья" bullet:
   ```
   Each tile opens a dungeon page (`#dg/<dungeon name>`, view "dungeon", `renderDg()`; shared data from `dgData()`): records, who went how often, characters in the level range now, kills per day from `glevels/{day}.bk`. Official art comes from `render.worldofwarcraft.com/<region>/zones/<slug>-small|large.jpg` (map `DG_ART`); the new Forever dungeons have none.
   ```
2. In "Code conventions", replace the Colors line with:
   ```
   - Colors, radii, shadows and the sidebar material are CSS custom properties on `:root` (`--radius-lg/md/sm`, `--shadow-1/2`, `--material`, `--bar` for neutral data bars), dark theme by default plus a light theme. Use the tokens, never hardcoded colors. The font is the system font (no web fonts). Gold (`--accent`) marks the current choice, not ordinary data.
   ```

## 2026-11-20: project CLAUDE.md, character comparison and watched characters

**Reason:** two new views/data the file does not describe.

**Affected file:** `CLAUDE.md` (project)

**Proposed wording** (new bullets under the "Гильдия" tab section):
```
- Comparison (`#cmp/<id>/<id>`, view "cmp", `renderCmp()`): two characters as mirrored bars plus two-line day-by-day charts; opened from «Сравнить с» on the character card. An id is a guild slug or `<region>.<slug>` for a watched character.
- `wchars/{region}.{slug}`: characters outside the guild (streamers, friends) `{ at, label, region, name, surname, level, cls, race, ilvl, avatar, items, st, pvp, profs, ast, achn, q, hist: { day: { lv, il, qd, hk, dt } }, deleted }`. The list lives in the hidden `bnet_watch` table; admins add and remove via `watch_add` / `watch_del` on the comparison page; `watch_sync()` (called by `guild_sync()`) refreshes them hourly. Read-only for the page.
```
