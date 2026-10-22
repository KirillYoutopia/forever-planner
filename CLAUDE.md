# WoW Forever Planner — project context

You're working on a planner page for a small WoW Forever group (4 core players). The UI text is in Russian, so keep all user-facing text in Russian. It started as a claude.ai artifact and has been moved to a standalone static site backed by Supabase, so the group can use it without a Claude account. It needs no login.

## Stack and files
- `index.html`: the entire app. Vanilla JS and CSS in one file. No framework, no build step.
- `store.js`: Supabase adapter. It copies the old claude.ai storage interface, so the page code stays the same:
  - `db.collection(name).onSnapshot(cb)` gets `{ docs: [{ id, data() }] }`. `.add(data)` and `.doc(id)` are also available.
  - `db.doc("coll/id")` has `.update(patch)` (deep merge), `.set(data)`, `.delete()` and `.onSnapshot(cb)`.
  - Updates are applied locally first, then confirmed by Supabase realtime. The data is fully reloaded when the tab becomes visible again.
- `config.js`: Supabase URL and anon key.
- `supabase.sql`: schema and seed data. It's safe to re-run.
  - One table, `docs(coll, id, data jsonb)`, primary key `(coll, id)`.
  - RPC `patch_doc(p_coll, p_id, p_patch)` deep-merges a patch on the server, so two people editing different fields don't overwrite each other.
  - `patch_doc` is the only write path for the page (security definer, merge-only, validates collection names, vote values and that voters are group players). Anon can only `select` the table directly, never insert/update/delete.
  - `docs_history` keeps the previous version of every changed row (not readable by anon), for undoing vandalism.
  - Realtime is enabled on the table.
- `roadmap.png`: the roadmap image used in the header.
- `README.md`: setup and hosting steps (Supabase project, Netlify Drop / GitHub Pages).

## Data model (`data` is jsonb)
- `players/{id}`, where core ids are `p_denis`, `p_kirill`, `p_olesya`, `p_yan` and new ids look like `p_xxxxxxxxxxxx`:
  - `name`: string
  - `createdAt`: number, used for sort order
  - `picks`: `{ [Class]: 1 | 2 | -1 (ban) | 0 }`
  - `main`: `{ cls, race, role }`. A ★ in the grid means `main.cls` is set.
  - `profs`: `{ [Profession]: boolean }`
  - `avail`: `{ "YYYY-MM-DD": "full" | "no" | a subset of "mde" (morning/day/evening) | "hA-B" (hours) | "" }`
  - `deleted`: `true` hides a (non-core) player. The database allows no deletes, so removal is a soft delete.
- `votes/{playerId}`: `{ vote: "pve" | "pvp" | "", at }`. One vote per group player; `""` means the vote was withdrawn. The voter picks themselves from the player list (remembered in localStorage as `wf-voter`).
- `meta/settings`: `{ size: 5 | 10 }`

## Code conventions
- `render()` re-renders every section from state. `editing()` holds off re-rendering while an input or select has focus, so keep that guard working.
- Clicks are handled by one delegated listener that dispatches on `data-act`. Add new actions there.
- Colors are CSS custom properties on `:root`, with a dark theme by default and a light theme. Use the tokens, never hardcoded colors.
- Key constants: `RELEASE`, `LAUNCH_AT`, `HC_AT` (an estimated Hardcore start), `CORE` (players who can't be deleted), `CLASSES`, `RACES` and `PROFS`. The game is Classic-era, so it has 9 classes and 8 races, plus the WoW Forever race Skyborne (neutral: stored as `Skyborne-A` or `Skyborne-H` depending on the faction chosen).
- Escape all user text with `esc()`.

## Rules
- Don't change the shape of the stored data without also adding migration SQL to `supabase.sql`, written so it can be re-run safely.
- No build tools or npm dependencies in the app. External scripts come only from pinned CDN versions.
- Test locally with `python -m http.server 8000`, check the page at phone width (375px), and confirm the browser console has no errors.
- Keep changes small and show me the diff before any large refactor.
