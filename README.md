# WoW Forever guild site

A ready-to-run website for a World of Warcraft: Forever guild. It reads your guild from Blizzard's API every hour and turns it
into a small portal for the group: roster and character sheets, professions and craft orders, dungeons, PvP, the auction house,
and a few things just for fun.

Live example: **[Kute Expats](https://kirillyoutopia.github.io/forever-planner/)** (EU, PvP, Horde). The interface is in Russian.

It is a static page plus a free Supabase project: no server to run, no build step, no npm.

## What's inside

**Guild**
- Roster with levels, classes, races, item level and GearScore, activity and day-by-day progress charts.
- Character cards: gear with tooltips, a 3D model, talents (both specs), stats, reputations, achievements, quests by zone.
- Compare any two characters, including streamers and friends outside the guild.
- Professions: who knows which recipe, the full catalogue of each profession, favourites and **craft orders** between members.
- Dungeons: runs and boss kills per character, who fits a dungeon by level right now.
- PvP: honorable kills now, per day and per week. Game statistics and guild records.
- News from Wowhead's WoW Forever feeds.

**Auction house** (hourly snapshot of your faction's house and the neutral one)
- Every item with its lowest and market price, quantity and price history (hourly for 7 days, daily for 30 days).
- Overview: listings over time, new and vanished listings per hour, the busiest hours of the day.
- Trends: biggest price moves, items being bought up or flooded, new and vanished items.
- Raw materials for gatherers, **vendor flips** (listings below what an NPC pays), the profit of every recipe the guild knows,
  and crafts worth selling to vendors with the most you can pay for their reagents.

**For the group**
- Login per player (passwords are bcrypt-hashed on the server); logged out, the site is read-only.
- Tavern: Roll to Death duels with server-side dice, bets with gold, a shared wallet of who owes whom.
- Hall of fame, calendar and planning pages, a Hardcore graveyard.

## How it works

```
Blizzard API ──hourly──► Supabase (Postgres, pg_cron) ──► docs table ──► index.html in the browser
                                                      (read-only for visitors, writes only through checked RPCs)
Blizzard auctions ──hourly──► GitHub Actions (scripts/ah.py) ──► auction tables in Supabase
Wowhead ──► talent trees, item tooltips, news, 3D model files (through a small Edge Function)
```

- `index.html` is the whole site: plain HTML, CSS and JavaScript in one file.
- `supabase.sql` holds everything on the server side: tables, the hourly sync jobs, login and permission checks. It is safe to run again after every update.
- API secrets live only in Supabase (and in GitHub Actions secrets for the auction job). Nothing secret is in this repository.

## Set up your own

You need a Supabase account (free tier is enough), a Blizzard developer account and a place to host static files (GitHub Pages works).

1. **Supabase project.** Create a project. In the SQL Editor, paste `supabase.sql` and run it.
2. **Connect the page.** Project Settings → API: copy the Project URL and the `anon` public key into `config.js`.
   The anon key is meant to be public: visitors can only read, and every write goes through server-side checks.
3. **Blizzard API.** On [develop.battle.net](https://develop.battle.net) create an API client. Then in the SQL Editor
   (don't commit these values):
   ```sql
   insert into public.bnet_config (k, v) values
     ('client_id', '...'), ('client_secret', '...'),
     ('region', 'eu'),           -- eu, us, kr or tw
     ('guild', 'your-guild-slug') -- as in the armory URL
   on conflict (k) do update set v = excluded.v;
   select public.guild_sync();    -- first sync now; after that it runs every hour by itself
   ```
4. **Players and an admin.** Players are rows in the `docs` table (`coll = 'players'`). Give yourself an admin login:
   ```sql
   insert into public.accounts (player_id, pass_hash, is_admin, must_change)
   values ('p_yourname', extensions.crypt('a long password', extensions.gen_salt('bf')), true, false)
   on conflict (player_id) do update set pass_hash = excluded.pass_hash, is_admin = true;
   ```
   Other players start with the password `Forever` and must change it on first login; an admin can reset passwords from the site.
5. **Host it.** Push the folder to a GitHub repository → Settings → Pages → deploy from the main branch. Or drag the folder
   into [Netlify Drop](https://app.netlify.com/drop). To try it locally: `python -m http.server 8000`.
6. **3D models (optional).** Deploy the Edge Function with JWT verification off:
   `supabase functions deploy modelviewer --no-verify-jwt`.
7. **Auction house (optional).**
   - Make up a long random secret and store it: `insert into public.bnet_config values ('ah_secret', '...');`
   - In the GitHub repository: Settings → Secrets and variables → Actions → add `BLIZZARD_CLIENT_ID`, `BLIZZARD_CLIENT_SECRET`
     and `AH_SECRET` (the same secret).
   - The workflow `.github/workflows/ah.yml` then runs every hour. Run it once by hand from the Actions tab to start.

### Things that are specific to our guild

The site was built for one group, so a few values are written into the code. Change them for yours:

- **Auction houses**: WoW Forever has no realms; each region lists one house per ruleset and faction, and Blizzard doesn't say
  which is which. Ours are `113` (PvP Horde) and `116` (PvP Blackwater) in `scripts/ah.py`, `index.html` (`AH_HOUSES`) and
  `ah_publish` in `supabase.sql`. Compare a price in the game with the snapshots to find yours.
- **Core players** who can't be removed: `CORE` in `index.html`, and the starter players in `supabase.sql`.
- **Dates** of the countdowns (`RAIDS_AT`, `HC_AT`) in `index.html`.

## Files

| File | What it is |
|---|---|
| `index.html` | the site |
| `store.js` | the page's data layer: loads the `docs` table, keeps it in sync live, sends writes |
| `config.js` | your Supabase URL and anon key |
| `supabase.sql` | database schema, sync jobs, login and permissions (re-runnable) |
| `scripts/ah.py` | auction snapshot job (Python, standard library only); also runs locally to keep raw snapshots |
| `.github/workflows/ah.yml` | runs the auction job every hour |
| `supabase/functions/modelviewer` | proxy for Wowhead's 3D model viewer files |
| `old.html`, `v2.html` | the previous design and a redirect for old links |

## Data and credits

Game data comes from the [Blizzard Battle.net API](https://develop.battle.net). Talent trees, item tooltips, news and the
3D model viewer come from [Wowhead](https://www.wowhead.com/forever). This is a fan project, not affiliated with Blizzard
Entertainment or Wowhead. World of Warcraft is a trademark of Blizzard Entertainment.
