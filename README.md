# WoW Forever Planner (standalone)

Static site + Supabase. No claude.ai account needed: anyone with the link can view and edit.

## Setup (≈5 min)
1. supabase.com → New project (free tier).
2. SQL Editor → paste `supabase.sql` → Run. Creates the `docs` table, live sync, and loads the data
   exported from the claude.ai artifact (Denis, Kirill, Olesya, Yan, settings, 1 vote).
3. Project Settings → API → copy **Project URL** and **anon public** key into `config.js`.
4. Host the folder anywhere static:
   - **Netlify Drop** (app.netlify.com/drop): drag the folder in, done.
   - **GitHub Pages**: push to a repo → Settings → Pages → deploy from branch.
   - Local test: `python -m http.server` in this folder → http://localhost:8000

## Files
- `index.html` – the page (unchanged UI/logic)
- `store.js` – Supabase adapter (same API the page used on claude.ai)
- `config.js` – your Supabase URL + anon key
- `supabase.sql` – schema + seed data
- `roadmap.png` – roadmap image

## Behaviour differences vs claude.ai
- Edit access: anyone with the link (no read-only mode). Keep the link within the group.
- PvE/PvP poll: one vote per browser (random id in localStorage), not per account.
  The old PvP vote stays in the count but can't be changed from the new site; delete its row
  in Supabase (coll = votes) if you want to re-vote.
- Core players (Denis, Kirill, Olesya, Yan) still can't be deleted from the UI.
