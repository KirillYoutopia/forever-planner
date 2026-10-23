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
  - `patch_doc` is the only write path for the page (security definer, merge-only, validates collection names, vote values and that voters are group players). A new collection must be added to its allow-list. Anon can only `select` the table directly, never insert/update/delete.
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
- `votes/{playerId}`: `{ vote: "pve" | "pvp" | "", at }`. One vote per group player; `""` means the vote was withdrawn. The voter types their name; it must match a player name (case-insensitive) or the vote is silently refused with no hints. The name is remembered in localStorage as `wf-name`.
- `meta/settings`: `{ size: 5 | 10 }`
- "Скоро" tab (`#soon`). "Ближайшая игра" lives in the calendar tab. `DUNGEONS` follows Wowhead's WoW Forever dungeon guide (beta data):
  - Player fields: `level` (1–60), `xp` (0–100, % to next level), `dungeons: { [dungeonId]: true }` (ids in `DUNGEONS` / `RAIDS`).
  - `tasks/{id}`: `{ text, due, done, at }`, the launch checklist.
  - `goals/{id}`: `{ title, done: { [playerId]: true }, at }`. The "60 by Dec 9" goal is computed from levels, not stored.
  - `wants/{id}`: `{ by: playerId, item, src, wid?, q?, icon?, at }`, the loot wishlist. `wid`/`q`/`icon` come from Wowhead's tooltip JSON (`nether.wowhead.com/tooltip/item/{id}?dataEnv=16`, CORS-open, no script) when a Wowhead link or ID is pasted. A clash is the same item name from 2+ players.
  - `deaths/{id}`: `{ by: playerId, lvl, killer, words, at }`, the Hardcore graveyard.
  - All four collections use `deleted: true` for removal, like players.
- "Таверна" (`#tavern`), "Ставки" (`#bets`) and "Зал славы" (`#fame`) tabs. "Ты —" (`#me`, localStorage `wf-me`) says who is acting there.
  - `rolls/{id}`: Roll to Death duels `{ a, b, start, stakeS (silver; older duels have stake in gold, read via stakeOf()), rolls: [{ by, max, r, at }], winner, loser, endedAt, at }`. Created and rolled only by the RPCs `deathroll_new` / `deathroll_roll` (dice rolled on the server, turns enforced). `patch_doc` lets the page set only `deleted` on them. Hiding a finished duel removes it from the debt ledger.
  - `bets/{id}`: `{ q, opts: [text], picks: { [playerId]: optionIndex | -1 }, result: optionIndex | -1, resolvedAt, at }`.
  - `fame/{id}`: `{ who: playerId | "" (whole group), title, icon, at, auto }`. `fameCands()` derives achievements from the data, and `syncFame()` writes each new one once, under a deterministic id. Hidden ones (`deleted`) never come back. Manual entries come from the form.
  - Bets can carry gold: `bets.stakes: { [playerId]: silver }`. Pari-mutuel: losers' gold is split among the winners in proportion to their stakes. If no one with gold guessed right, nothing changes hands. Picks and stakes are frozen server-side once `result >= 0`.
  - `pays/{id}`: `{ from, to, s (silver), by, at }`, the "Рассчитались" settlements. Either party (or the admin) can record one, and it can't be edited afterwards.
  - The wallet (`walletDebts`/`walletPairs`) nets duels + bets − payments per pair. The rules shown in the Таверна panel must stay in sync with this logic.
  - `data-view` can list several views separated by spaces (e.g. `"tavern bets"`).

## Login and permissions
- A quiet "I'm kute expat" link fixed in the bottom-right corner opens the login dialog (logged in: controls sit under the party frames on wide screens, in the footer on narrow ones) (pick a player, enter a password). The session token is kept in localStorage (`wf-token`) and sent with every write. Logged out, the site is read-only.
- Server side (supabase.sql): `accounts` (bcrypt hashes, `is_admin`, `must_change`) and `sessions` are hidden tables. RPCs: `login`, `whoami`, `logout`, `change_password` (min 4 characters, not "Forever"), `admin_accounts`, `admin_reset` (back to "Forever"), `admin_set_admin`.
- `patch_doc(p_token, ...)` enforces the rights: non-admins change only their own player row, vote, bet picks, goal ticks, wants and deaths; admin-only for meta, deleting players and adding players. `deathroll_*` take the token, so you always roll as yourself.
- The page mirrors those rules (`mine(id)`) to grey out other people's controls. The database is what actually enforces them.
- Initial passwords are never committed (the repo is public). Kirill's admin account comes from a one-off script kept outside the repo. Others start with "Forever" and must change it before they can write.

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
