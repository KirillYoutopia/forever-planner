# Instruction proposals

Proposed changes to CLAUDE.md files. Not active until approved.

## 2026-11-18: project CLAUDE.md, after v2 became the main page

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
