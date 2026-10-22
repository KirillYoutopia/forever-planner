-- WoW Forever Planner: Supabase schema + seed data
-- Run in Supabase → SQL Editor. Safe to re-run.

create table if not exists public.docs (
  coll       text        not null,
  id         text        not null,
  data       jsonb       not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (coll, id)
);

-- Recursive merge so two people editing different fields of the same player never overwrite each other.
create or replace function public.jsonb_deep_merge(a jsonb, b jsonb)
returns jsonb language sql immutable as $$
  select case
    when jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      (select coalesce(jsonb_object_agg(k,
         case when a ? k and b ? k then public.jsonb_deep_merge(a->k, b->k)
              when b ? k then b->k else a->k end), '{}'::jsonb)
       from (select jsonb_object_keys(a) k union select jsonb_object_keys(b)) keys)
    else b end
$$;

-- The only way the page can write: merge-only (no deletes, no full overwrite) and validated.
create or replace function public.patch_doc(p_coll text, p_id text, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_coll not in ('players', 'votes', 'meta') then raise exception 'unknown collection %', p_coll; end if;
  if p_coll = 'meta' and p_id <> 'settings' then raise exception 'unknown meta doc %', p_id; end if;
  if jsonb_typeof(p_patch) <> 'object' or octet_length(p_patch::text) > 20000 then raise exception 'bad patch'; end if;
  if p_coll = 'votes' then
    if not exists (select 1 from docs where coll = 'players' and id = p_id
                   and not coalesce((data->>'deleted')::boolean, false)) then
      raise exception 'only group players can vote';
    end if;
    if coalesce(p_patch->>'vote', '') not in ('pve', 'pvp', '') then raise exception 'bad vote'; end if;
  end if;
  insert into docs (coll, id, data) values (p_coll, p_id, p_patch)
  on conflict (coll, id) do update
    set data = jsonb_deep_merge(docs.data, excluded.data), updated_at = now();
end $$;

-- No login: anyone with the page link can read, but writes only go through patch_doc above.
alter table public.docs enable row level security;
drop policy if exists "open access" on public.docs;
drop policy if exists "read" on public.docs;
create policy "read" on public.docs for select to anon, authenticated using (true);
revoke insert, update, delete on public.docs from anon, authenticated;
grant select on public.docs to anon, authenticated;
grant execute on function public.patch_doc(text, text, jsonb) to anon, authenticated;

-- Every change keeps the previous version here (not readable from the page), so vandalism can be undone.
create table if not exists public.docs_history (
  hid        bigserial   primary key,
  coll       text        not null,
  id         text        not null,
  data       jsonb,
  changed_at timestamptz not null default now()
);
alter table public.docs_history enable row level security;
revoke all on public.docs_history from anon, authenticated;
create or replace function public.docs_keep_history()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into docs_history (coll, id, data) values (old.coll, old.id, old.data);
  return coalesce(new, old);
end $$;
drop trigger if exists docs_history on public.docs;
create trigger docs_history before update or delete on public.docs
  for each row execute function public.docs_keep_history();

-- Live sync
alter table public.docs replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- Data exported from the claude.ai artifact on 2026-10-22
insert into public.docs (coll, id, data) values
  ('meta', 'settings', $j${"size": 5}$j$::jsonb),
  ('players', 'p_denis', $j${"createdAt": 1, "main": {"cls": "", "race": "", "role": ""}, "name": "Denis", "picks": {"Druid": 2, "Hunter": -1, "Mage": -1, "Paladin": 1, "Priest": 2, "Rogue": -1, "Shaman": 2, "Warlock": -1, "Warrior": 1}, "profs": {}}$j$::jsonb),
  ('players', 'p_kirill', $j${"avail": {"2026-11-04": "no", "2026-11-05": "full", "2026-11-06": "full", "2026-11-07": "full", "2026-11-08": "", "2026-11-09": "full", "2026-11-10": "e", "2026-11-11": "e", "2026-11-12": "e", "2026-11-13": "e"}, "createdAt": 2, "main": {"cls": "Mage", "race": "Orc", "role": "dps"}, "name": "Kirill", "picks": {"Druid": 1, "Mage": 0, "Paladin": -1, "Priest": 2, "Rogue": -1, "Shaman": 1, "Warrior": -1}, "profs": {"Blacksmithing": true, "Cooking": true, "Enchanting": false, "First Aid": true, "Fishing": true, "Leatherworking": false, "Mining": false, "Tailoring": true}}$j$::jsonb),
  ('players', 'p_olesya', $j${"avail": {"2026-11-05": ""}, "createdAt": 3, "main": {"cls": "", "race": "", "role": ""}, "name": "Olesya", "picks": {"Druid": 2, "Hunter": 2, "Rogue": 2}, "profs": {"Leatherworking": true, "Skinning": true}}$j$::jsonb),
  ('players', 'p_yan', $j${"createdAt": 4, "main": {"cls": "", "race": "", "role": ""}, "name": "Yan", "picks": {"Priest": 2, "Shaman": 2, "Warlock": 2, "Warrior": 1}, "profs": {"Blacksmithing": true, "Mining": true}}$j$::jsonb),
  ('votes', 'p_kirill', $j${"at": 1792658307605, "vote": "pvp"}$j$::jsonb)
on conflict (coll, id) do nothing;

-- Migration 2026-10-23: votes moved from votes/{browserId} {vote, name, at} to votes/{playerId} {vote, at}.
insert into public.docs (coll, id, data)
select 'votes', p.id, jsonb_build_object('vote', v.data->'vote', 'at', v.data->'at')
from public.docs v
join public.docs p on p.coll = 'players' and lower(p.data->>'name') = lower(v.data->>'name')
where v.coll = 'votes' and v.id not like 'p\_%'
on conflict (coll, id) do nothing;
delete from public.docs where coll = 'votes' and id not in (select id from public.docs where coll = 'players');
