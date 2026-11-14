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

-- ===== Login =====
-- accounts and sessions are invisible to the page (RLS on, no grants); only the functions below use them.
-- Passwords are stored as bcrypt hashes. Initial passwords are NOT in this file (the repo is public): Kirill's admin
-- account is created by a one-off script, the others start with the shared password "Forever" and must change it.
create extension if not exists pgcrypto with schema extensions;
create table if not exists public.accounts (
  player_id   text        primary key,
  pass_hash   text        not null,
  must_change boolean     not null default true,
  is_admin    boolean     not null default false,
  updated_at  timestamptz not null default now()
);
create table if not exists public.sessions (
  token      uuid        primary key default gen_random_uuid(),
  player_id  text        not null references public.accounts (player_id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.accounts enable row level security;
alter table public.sessions enable row level security;
revoke all on public.accounts, public.sessions from anon, authenticated;

-- Who is calling: the session's player (null if the token is unknown or older than 90 days).
create or replace function public.auth_session(p_token text, out pid text, out admin boolean, out must_change boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_token is null or p_token !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return; end if;
  select a.player_id, a.is_admin, a.must_change into pid, admin, must_change
  from sessions s join accounts a on a.player_id = s.player_id
  where s.token = p_token::uuid and s.created_at > now() - interval '90 days';
end $$;
revoke execute on function public.auth_session(text) from public, anon, authenticated;

create or replace function public.login(p_player text, p_pass text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.accounts; t uuid;
begin
  select * into a from accounts where player_id = p_player;
  if not found or a.pass_hash <> crypt(coalesce(p_pass, ''), a.pass_hash) then
    perform pg_sleep(0.7);  -- slows down password guessing
    raise exception 'bad login';
  end if;
  delete from sessions where created_at < now() - interval '90 days';
  insert into sessions (player_id) values (a.player_id) returning token into t;
  return jsonb_build_object('token', t, 'player', a.player_id, 'admin', a.is_admin, 'must_change', a.must_change);
end $$;

create or replace function public.whoami(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from auth_session(p_token);
  if s.pid is null then return null; end if;
  return jsonb_build_object('player', s.pid, 'admin', s.admin, 'must_change', s.must_change);
end $$;

create or replace function public.logout(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_token ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    delete from sessions where token = p_token::uuid;
  end if;
end $$;

create or replace function public.change_password(p_token text, p_old text, p_new text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s record; h text;
begin
  select * into s from auth_session(p_token);
  if s.pid is null then raise exception 'login required'; end if;
  select pass_hash into h from accounts where player_id = s.pid;
  if h <> crypt(coalesce(p_old, ''), h) then perform pg_sleep(0.7); raise exception 'bad old password'; end if;
  if char_length(coalesce(p_new, '')) < 4 or char_length(p_new) > 64 or p_new = 'Forever' then
    raise exception 'bad new password';
  end if;
  update accounts set pass_hash = crypt(p_new, gen_salt('bf')), must_change = false, updated_at = now() where player_id = s.pid;
  delete from sessions where player_id = s.pid and token <> p_token::uuid;  -- log out other devices
end $$;

-- Admin tools: list accounts (never the hashes), reset a password to "Forever", grant or take admin.
create or replace function public.admin_accounts(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from auth_session(p_token);
  if not coalesce(s.admin, false) then raise exception 'admin only'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('player', player_id, 'admin', is_admin, 'must_change', must_change)), '[]'::jsonb) from accounts);
end $$;

create or replace function public.admin_reset(p_token text, p_player text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s record;
begin
  select * into s from auth_session(p_token);
  if not coalesce(s.admin, false) then raise exception 'admin only'; end if;
  if not exists (select 1 from docs where coll = 'players' and id = p_player) then raise exception 'unknown player'; end if;
  insert into accounts (player_id, pass_hash, must_change) values (p_player, crypt('Forever', gen_salt('bf')), true)
  on conflict (player_id) do update set pass_hash = excluded.pass_hash, must_change = true, updated_at = now();
  delete from sessions where player_id = p_player;
end $$;

create or replace function public.admin_set_admin(p_token text, p_player text, p_admin boolean)
returns void language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from auth_session(p_token);
  if not coalesce(s.admin, false) then raise exception 'admin only'; end if;
  if p_player = s.pid and not p_admin then raise exception 'cannot remove own admin'; end if;
  update accounts set is_admin = p_admin, updated_at = now() where player_id = p_player;
end $$;

-- Starting accounts for the group (Kirill's comes from the one-off admin script). Existing accounts are left alone.
insert into public.accounts (player_id, pass_hash, must_change)
select id, extensions.crypt('Forever', extensions.gen_salt('bf')), true
from public.docs where coll = 'players' and id in ('p_denis', 'p_yan', 'p_olesya')
on conflict (player_id) do nothing;

-- ===== Writes =====
-- The only way the page can write: merge-only (no deletes, no full overwrite), validated, and limited to what the
-- logged-in player may change. Admins may change anything.
drop function if exists public.patch_doc(text, text, jsonb);  -- the old version without a login
create or replace function public.patch_doc(p_token text, p_coll text, p_id text, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare s record; owner text;
begin
  select * into s from auth_session(p_token);
  if s.pid is null then raise exception 'login required'; end if;
  if s.must_change then raise exception 'change password first'; end if;
  if p_coll not in ('players', 'votes', 'meta', 'tasks', 'goals', 'wants', 'deaths', 'bets', 'fame', 'rolls', 'pays') then
    raise exception 'unknown collection %', p_coll;
  end if;
  -- Roll to Death duels are created and rolled only by deathroll_new / deathroll_roll; the page may only hide one.
  if p_coll = 'rolls' and exists (select 1 from jsonb_object_keys(p_patch) k where k <> 'deleted') then
    raise exception 'rolls are changed only by deathroll functions';
  end if;
  if p_coll = 'meta' and p_id <> 'settings' then raise exception 'unknown meta doc %', p_id; end if;
  -- Bets: once there is a result, picks and gold are frozen. Gold is whole silver, 0..100000000.
  if p_coll = 'bets' and (p_patch ? 'picks' or p_patch ? 'stakes') then
    if exists (select 1 from docs where coll = 'bets' and id = p_id and coalesce((data->>'result')::int, -1) >= 0) then
      raise exception 'bet closed';
    end if;
    if jsonb_typeof(p_patch->'stakes') = 'object' and exists (
      select 1 from jsonb_each(p_patch->'stakes') e
      where jsonb_typeof(e.value) <> 'number' or (e.value)::numeric < 0 or (e.value)::numeric > 100000000 or (e.value)::numeric <> trunc((e.value)::numeric)) then
      raise exception 'bad stake';
    end if;
  end if;
  -- Wallet settlements ("Рассчитались"): written once, never edited; amount in silver.
  if p_coll = 'pays' then
    if exists (select 1 from docs where coll = 'pays' and id = p_id) and not s.admin then raise exception 'not yours'; end if;
    if coalesce(p_patch->>'from', '') = '' or coalesce(p_patch->>'to', '') = '' or jsonb_typeof(p_patch->'s') <> 'number'
       or (p_patch->>'s')::numeric <= 0 or (p_patch->>'s')::numeric > 100000000 then
      raise exception 'bad payment';
    end if;
    if not s.admin and s.pid not in (p_patch->>'from', p_patch->>'to') then raise exception 'not yours'; end if;
  end if;
  if jsonb_typeof(p_patch) <> 'object' or octet_length(p_patch::text) > 20000 then raise exception 'bad patch'; end if;
  if p_coll = 'votes' then
    if not exists (select 1 from docs where coll = 'players' and id = p_id
                   and not coalesce((data->>'deleted')::boolean, false)) then
      raise exception 'only group players can vote';
    end if;
    if coalesce(p_patch->>'vote', '') not in ('pve', 'pvp', '') then raise exception 'bad vote'; end if;
  end if;
  if not s.admin then
    if p_coll = 'meta' then raise exception 'admin only'; end if;
    if p_coll = 'players' and p_patch ? 'deleted' then raise exception 'admin only'; end if;
    if p_coll in ('players', 'votes') and p_id <> s.pid then raise exception 'not yours'; end if;
    if p_coll = 'bets' and jsonb_typeof(p_patch->'picks') = 'object'
       and exists (select 1 from jsonb_object_keys(p_patch->'picks') k where k <> s.pid) then raise exception 'not yours'; end if;
    if p_coll = 'bets' and jsonb_typeof(p_patch->'stakes') = 'object'
       and exists (select 1 from jsonb_object_keys(p_patch->'stakes') k where k <> s.pid) then raise exception 'not yours'; end if;
    if p_coll = 'goals' and jsonb_typeof(p_patch->'done') = 'object'
       and exists (select 1 from jsonb_object_keys(p_patch->'done') k where k <> s.pid) then raise exception 'not yours'; end if;
    if p_coll in ('wants', 'deaths') then
      select data->>'by' into owner from docs where coll = p_coll and id = p_id;
      if coalesce(owner, p_patch->>'by') is distinct from s.pid or (p_patch ? 'by' and p_patch->>'by' <> s.pid) then
        raise exception 'not yours';
      end if;
    end if;
    if p_coll = 'bets' then
      select data->>'by' into owner from docs where coll = 'bets' and id = p_id;
      if p_patch ? 'deleted' and owner is distinct from s.pid then raise exception 'not yours'; end if;
      if p_patch ? 'by' and p_patch->>'by' <> s.pid then raise exception 'not yours'; end if;
    end if;
    if p_coll = 'fame' and p_patch ? 'deleted' then
      select coalesce(data->>'who', '') into owner from docs where coll = 'fame' and id = p_id;
      if coalesce(owner, '') not in ('', s.pid) then raise exception 'not yours'; end if;
    end if;
    if p_coll = 'rolls' and not exists (select 1 from docs where coll = 'rolls' and id = p_id and s.pid in (data->>'a', data->>'b')) then
      raise exception 'not yours';
    end if;
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
grant execute on function public.patch_doc(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.login(text, text), public.whoami(text), public.logout(text),
  public.change_password(text, text, text), public.admin_accounts(text), public.admin_reset(text, text),
  public.admin_set_admin(text, text, boolean) to anon, authenticated;

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
  for each row when (old.coll not in ('guild', 'glevels', 'gchars', 'grecipes', 'gcat', 'gzones'))  -- hourly Blizzard sync rows: nothing to undo there
  execute function public.docs_keep_history();

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

-- 2026-10-23: "Скоро" tab. New collections (soft delete via data.deleted = true, like players):
--   tasks/{id} {text, due, done, at}   goals/{id} {title, done: {playerId: true}, at}
--   wants/{id} {by: playerId, item, src, at}   deaths/{id} {by: playerId, lvl, killer, words, at}
-- New optional player fields: level (1-60), xp (0-100, % to next level), dungeons {dungeonId: true}.
-- Starter checklist and goals. A re-run refreshes their wording and order but keeps who ticked what.
insert into public.docs (coll, id, data) values
  ('tasks', 't_server',  $j${"text": "Выбрать сервер и фракцию", "due": "до 27 окт", "done": false, "at": 1}$j$::jsonb),
  ('tasks', 't_names',   $j${"text": "Зарезервировать имена (все 4)", "due": "27 окт", "done": false, "at": 2}$j$::jsonb),
  ('tasks', 't_addons',  $j${"text": "Поставить аддоны: Questie, Details", "due": "до 4 ноя", "done": false, "at": 3}$j$::jsonb),
  ('tasks', 't_chars',   $j${"text": "Создать персонажей", "due": "27 окт", "done": false, "at": 4}$j$::jsonb),
  ('tasks', 't_launch',  $j${"text": "Старт в 00:00, все онлайн", "due": "5 ноя", "done": false, "at": 5}$j$::jsonb),
  ('goals', 'g_mount',   $j${"title": "Маунт на 40 у всех (100 золота каждому)", "done": {}, "at": 1}$j$::jsonb),
  ('goals', 'g_artisan', $j${"title": "Артизан в основных профессиях (300)", "done": {}, "at": 2}$j$::jsonb)
on conflict (coll, id) do update
  set data = public.docs.data
    || jsonb_strip_nulls(jsonb_build_object('text', excluded.data->'text', 'due', excluded.data->'due',
                                            'title', excluded.data->'title', 'at', excluded.data->'at'));

-- 2026-10-23: Таверна (Roll to Death), Ставки, Зал славы.
--   bets/{id}  {q, opts: [text], picks: {playerId: optionIndex | -1}, result: optionIndex | -1, resolvedAt, at}
--   bets also get stakes: {playerId: silver}. pays/{id} {from, to, s (silver), by, at}: "Рассчитались" settlements.
--   fame/{id}  {who: playerId | "" (whole group), title, icon, at, auto}. Auto ids are deterministic (e.g. lvl20_p_kirill).
--   rolls/{id} {a, b, start, stakeS, rolls: [{by, max, r, at}], winner, loser, endedAt, at}. Written only by the functions
--   below, so the dice are rolled on the server and turns are enforced. stakeS is in silver (1 gold = 100 silver);
--   duels created before 2026-10-23 evening have "stake" in gold instead, and the page reads both.
drop function if exists public.deathroll_new(text, text, text, int, int);  -- older versions without a login
create or replace function public.deathroll_new(p_token text, p_id text, p_a text, p_b text, p_start int, p_stake_s int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; s record;
begin
  select * into s from auth_session(p_token);
  if s.pid is null then raise exception 'login required'; end if;
  if s.must_change then raise exception 'change password first'; end if;
  if not s.admin and s.pid not in (p_a, p_b) then raise exception 'not yours'; end if;
  if p_id !~ '^[a-z0-9]{6,32}$' then raise exception 'bad id'; end if;
  if p_a = p_b then raise exception 'need two different players'; end if;
  if (select count(*) from docs where coll = 'players' and id in (p_a, p_b)
      and not coalesce((data->>'deleted')::boolean, false)) <> 2 then
    raise exception 'unknown player';
  end if;
  if p_start < 2 or p_start > 1000000 or p_stake_s < 0 or p_stake_s > 100000000 then raise exception 'bad numbers'; end if;
  g := jsonb_build_object('a', p_a, 'b', p_b, 'start', p_start, 'stakeS', p_stake_s, 'rolls', '[]'::jsonb,
                          'at', floor(extract(epoch from clock_timestamp()) * 1000));
  insert into docs (coll, id, data) values ('rolls', p_id, g);
  return g;
end $$;

drop function if exists public.deathroll_roll(text, text);  -- older version took the player id instead of a login
create or replace function public.deathroll_roll(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; rs jsonb; n int; mx int; r int; turn text; now_ms numeric; s record; p_by text;
begin
  select * into s from auth_session(p_token);
  if s.pid is null then raise exception 'login required'; end if;
  if s.must_change then raise exception 'change password first'; end if;
  p_by := s.pid;  -- you always roll as yourself
  select data into g from docs where coll = 'rolls' and id = p_id for update;
  if g is null or coalesce((g->>'deleted')::boolean, false) then raise exception 'no such duel'; end if;
  if coalesce(g->>'loser', '') <> '' then raise exception 'game over'; end if;
  rs := coalesce(g->'rolls', '[]'::jsonb);
  n := jsonb_array_length(rs);
  turn := case when n % 2 = 0 then g->>'a' else g->>'b' end;
  if p_by is distinct from turn then raise exception 'not your turn'; end if;
  mx := case when n = 0 then (g->>'start')::int else (rs->(n - 1)->>'r')::int end;
  r := floor(random() * mx)::int + 1;
  now_ms := floor(extract(epoch from clock_timestamp()) * 1000);
  g := g || jsonb_build_object('rolls', rs || jsonb_build_array(jsonb_build_object('by', p_by, 'max', mx, 'r', r, 'at', now_ms)));
  if r = 1 then
    g := g || jsonb_build_object('loser', p_by, 'winner', case when p_by = g->>'a' then g->>'b' else g->>'a' end, 'endedAt', now_ms);
  end if;
  update docs set data = g, updated_at = now() where coll = 'rolls' and id = p_id;
  return g;
end $$;

grant execute on function public.deathroll_new(text, text, text, text, int, int) to anon, authenticated;
grant execute on function public.deathroll_roll(text, text) to anon, authenticated;

-- 2026-10-23: the "story so far" Hall of Fame entries. Existing rows are left alone.
insert into public.docs (coll, id, data) values
  ('fame', 'f_site',   $j${"who": "", "title": "Планировщик переехал с claude.ai на свой сайт", "icon": "inv_misc_book_09", "at": 1792701000000, "auto": true}$j$::jsonb),
  ('fame', 'f_bots',   $j${"who": "", "title": "Пережили набег ботов: Pipiska, Donald Trump и компания", "icon": "spell_shadow_deathcoil", "at": 1792702800000, "auto": true}$j$::jsonb),
  ('fame', 'f_dropdb', $j${"who": "", "title": "Отбили атаку «DROP DATABASE»", "icon": "spell_holy_divineprotection", "at": 1792703460000, "auto": true}$j$::jsonb),
  ('fame', 'f_pvp',    $j${"who": "", "title": "Группа выбрала PvP (3:0)", "icon": "inv_bannerpvp_02", "at": 1792746000000, "auto": true}$j$::jsonb),
  ('fame', 'f_pie',    $j${"who": "p_denis", "title": "Получил уникальную роль Pirozochek", "icon": "inv_misc_food_11", "at": 1792749600000, "auto": true}$j$::jsonb),
  ('fame', 'f_tavern', $j${"who": "", "title": "Открылась Таверна: первые дуэли Roll to Death", "icon": "inv_misc_dice_02", "at": 1792760400000, "auto": true}$j$::jsonb)
on conflict (coll, id) do nothing;

-- Starter bets (26, grouped by cat). A re-run refreshes wording, options, category and order but keeps picks and results.
insert into public.docs (coll, id, data) values
  ('bets', 'b_l10', $j${"q":"Кто первым возьмёт 10 уровень?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778400000}$j$::jsonb),
  ('bets', 'b_l20', $j${"q":"Кто первым возьмёт 20 уровень?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778401000}$j$::jsonb),
  ('bets', 'b_l30', $j${"q":"Кто первым возьмёт 30 уровень?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778402000}$j$::jsonb),
  ('bets', 'b_l40', $j${"q":"Кто первым возьмёт 40 уровень?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778403000}$j$::jsonb),
  ('bets', 'b_l50', $j${"q":"Кто первым возьмёт 50 уровень?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778404000}$j$::jsonb),
  ('bets', 'b_60', $j${"q":"Кто первым дойдёт до 60?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778405000}$j$::jsonb),
  ('bets', 'b_last60', $j${"q":"Кто дойдёт до 60 последним?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Уровни","picks":{},"result":-1,"at":1792778406000}$j$::jsonb),
  ('bets', 'b_fish', $j${"q":"Кто первым прокачает рыбалку до 300?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Профессии","picks":{},"result":-1,"at":1792778407000}$j$::jsonb),
  ('bets', 'b_aid', $j${"q":"Кто первым прокачает первую помощь до 300?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Профессии","picks":{},"result":-1,"at":1792778408000}$j$::jsonb),
  ('bets', 'b_cook', $j${"q":"Кто первым прокачает кулинарию до 300?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Профессии","picks":{},"result":-1,"at":1792778409000}$j$::jsonb),
  ('bets', 'b_artisan', $j${"q":"Кто первым станет артизаном (300) в основной профессии?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Профессии","picks":{},"result":-1,"at":1792778410000}$j$::jsonb),
  ('bets', 'b_craftsell', $j${"q":"Кто первым продаст скрафченную вещь на аукционе?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Профессии","picks":{},"result":-1,"at":1792778411000}$j$::jsonb),
  ('bets', 'b_epic1', $j${"q":"Кто первым получит эпик?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Подземелья и рейды","picks":{},"result":-1,"at":1792778412000}$j$::jsonb),
  ('bets', 'b_epic', $j${"q":"Когда у группы будет первый эпик?","opts":["Первая неделя","Первый месяц","К рейдам","Не дождёмся"],"cat":"Подземелья и рейды","picks":{},"result":-1,"at":1792778413000}$j$::jsonb),
  ('bets', 'b_newdg', $j${"q":"Какое новое подземелье пройдём первым?","opts":["Ruins of Lordaeron","Excavation Site","City of Dalaran","The Drowned City"],"cat":"Подземелья и рейды","picks":{},"result":-1,"at":1792778414000}$j$::jsonb),
  ('bets', 'b_pie', $j${"q":"Pirozochek удержит агро на первом боссе?","opts":["Да","Нет","Агро? Какое агро?"],"cat":"Подземелья и рейды","picks":{},"result":-1,"at":1792778415000}$j$::jsonb),
  ('bets', 'b_dgdeath', $j${"q":"Кто чаще всех будет умирать в подземельях?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Подземелья и рейды","picks":{},"result":-1,"at":1792778416000}$j$::jsonb),
  ('bets', 'b_ony', $j${"q":"Сколько вайпов на Onyxia в первый вечер?","opts":["0–2","3–5","6–10","Больше 10"],"cat":"Подземелья и рейды","picks":{},"result":-1,"at":1792778417000}$j$::jsonb),
  ('bets', 'b_hc', $j${"q":"Кто первым умрёт в Hardcore?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Hardcore","picks":{},"result":-1,"at":1792778418000}$j$::jsonb),
  ('bets', 'b_hclvl', $j${"q":"На каком уровне будет первая смерть в Hardcore?","opts":["1–10","11–20","21–30","31+"],"cat":"Hardcore","picks":{},"result":-1,"at":1792778419000}$j$::jsonb),
  ('bets', 'b_hc60', $j${"q":"Кто первым дойдёт до 60 в Hardcore?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Hardcore","picks":{},"result":-1,"at":1792778420000}$j$::jsonb),
  ('bets', 'b_mount', $j${"q":"Кто первым купит маунта?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Таверна и разное","picks":{},"result":-1,"at":1792778421000}$j$::jsonb),
  ('bets', 'b_100g', $j${"q":"Кто первым заработает 100 золота?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Таверна и разное","picks":{},"result":-1,"at":1792778422000}$j$::jsonb),
  ('bets', 'b_drloss', $j${"q":"Кто больше всех проиграет в Roll to Death за первый месяц?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Таверна и разное","picks":{},"result":-1,"at":1792778423000}$j$::jsonb),
  ('bets', 'b_afk', $j${"q":"Кто первым скажет «я на минутку» и пропадёт на час?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Таверна и разное","picks":{},"result":-1,"at":1792778424000}$j$::jsonb),
  ('bets', 'b_late', $j${"q":"Кто первым опоздает на собранную группу?","opts":["Denis","Kirill","Olesya","Yan"],"cat":"Таверна и разное","picks":{},"result":-1,"at":1792778425000}$j$::jsonb)
on conflict (coll, id) do update
  set data = public.docs.data || jsonb_build_object('q', excluded.data->'q', 'opts', excluded.data->'opts',
                                                    'cat', excluded.data->'cat', 'at', excluded.data->'at');

-- 2026-11-13: "Гильдия" tab. Guild levels come from Blizzard's WoW Forever API (undocumented so far), fetched here on
-- the server once an hour, so the API secret never reaches the page. The page only reads these rows:
--   guild/roster          {name, at (ms), members: {slug: {name, surname, level, cls, race, rank}}}  (cls/race: Blizzard ids)
--   glevels/{YYYY-MM-DD}  {at, lv: {slug: level}, pr: {slug: {Profession: skill}}}  one row per day (Central European time),
--                         overwritten until the day ends (pr since 2026-11-13, older rows have none);
--                         since 2026-11-14 also hk: {slug: honorable kills}, pd: {slug: deaths from other players}
-- Neither collection is in patch_doc's allow-list, so nobody can write them from the page.
-- One-off setup, in the SQL Editor (NOT in this file, the repo is public):
--   insert into public.bnet_config (k, v) values ('client_id', '...'), ('client_secret', '...')
--   on conflict (k) do update set v = excluded.v;
--   select public.guild_sync();   -- first snapshot right away; after that it runs hourly
-- Optional keys: 'region' (default eu), 'guild' (guild slug, default kute-expats).
create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

create table if not exists public.bnet_config (k text primary key, v text not null);
alter table public.bnet_config enable row level security;
revoke all on public.bnet_config from anon, authenticated;

-- Item icon URLs, looked up once per item (Blizzard media ids). '' = Blizzard has no icon for it.
create table if not exists public.bnet_icons (id bigint primary key, icon text not null);
alter table public.bnet_icons enable row level security;
revoke all on public.bnet_icons from anon, authenticated;

-- 2026-11-14: "Рецепты" tab: who in the guild can craft what.
-- Hidden cache of every recipe seen: its profession, category (from the profession's recipe catalogue) and details.
--   detail: null = not fetched yet, else {v: 2, i: crafted item, iid, q: quantity, ds: description, re: [[reagent, quantity], ...]}
--   icon:   null = not fetched yet, '' = none
create table if not exists public.bnet_recipes (
  id bigint primary key, prof text not null, name text not null, cat text, detail jsonb, icon text);
create table if not exists public.bnet_prof_cat (prof text primary key, at timestamptz not null default now());
-- 2026-11-14 (later): details gain the recipe's description (ds: what an enchant does) and the crafted item's id (iid);
-- item = the crafted item's tooltip: null = not fetched yet, {} = none, else {iq: quality, il: item level, tip: lines}.
-- Details saved before this (no "v" marker) are fetched again once.
alter table public.bnet_recipes add column if not exists item jsonb;
update public.bnet_recipes set detail = null, item = null where detail is not null and not (detail ? 'v');
update public.bnet_recipes set icon = null where icon = '' and detail is null;
alter table public.bnet_recipes enable row level security;
alter table public.bnet_prof_cat enable row level security;
revoke all on public.bnet_recipes, public.bnet_prof_cat from anon, authenticated;
-- What the page reads (written only by guild_sync):
--   grecipes/{slug}     {at, r: {Profession: [recipe id, ...]}}   the recipes a level 10+ character knows
--   gcat/{Profession}   {at, r: {recipe id: {n: name, c: category, ok (details loaded), i, q, ds, re, icon, iq, il, tip}}}
--                       details of the recipes someone in the guild knows

-- 2026-11-14: dungeons per character come from the "Spelunker" achievements, whose criteria are the dungeons themselves
-- (Excavation Site: Wetlands, each Scarlet Monastery wing, ...) with a completion count.
-- Hidden cache of those achievement definitions: crit = {criterion id: dungeon name}, ord = the order of its dungeons.
create table if not exists public.bnet_ach (id bigint primary key, name text not null, crit jsonb not null, ord jsonb not null);
alter table public.bnet_ach enable row level security;
revoke all on public.bnet_ach from anon, authenticated;
-- What the page reads: guild/dungeons {at, list: [[dungeon, achievement name], ...]}  every dungeon the game tracks, in order;
--   gchars/{slug}.dg  [[dungeon, times completed, done], ...]   and   gchars/{slug}.ach  [[achievement, completed at (ms)], ...]

-- 2026-11-14: quest progress per zone. Hidden caches: the game's zones with their quests, and each character's completed quests.
create table if not exists public.bnet_quest_areas (id bigint primary key, name text not null, total int not null default 0, loaded boolean not null default false);
create table if not exists public.bnet_quests (id bigint primary key, area_id bigint not null);
create table if not exists public.bnet_char_quests (char_slug text primary key, ids jsonb not null);
alter table public.bnet_quest_areas enable row level security;
alter table public.bnet_quests enable row level security;
alter table public.bnet_char_quests enable row level security;
revoke all on public.bnet_quest_areas, public.bnet_quests, public.bnet_char_quests from anon, authenticated;
-- What the page reads: gzones/{slug} {at, z: [[zone, completed, quests in the zone], ...], other: completed quests outside any zone}
--   (zones with at least one completed quest, most completed first).
create or replace function public.guild_zones_publish()
returns void language plpgsql security definer set search_path = public as $$
declare members jsonb; now_ms numeric := floor(extract(epoch from clock_timestamp()) * 1000);
begin
  if not exists (select 1 from bnet_quest_areas where loaded) then return; end if;  -- nothing to count against yet
  select data->'members' into members from docs where coll = 'guild' and id = 'roster';
  insert into docs (coll, id, data)
  select 'gzones', c.char_slug, jsonb_build_object('at', now_ms,
    'z', coalesce((select jsonb_agg(jsonb_build_array(t.name, t.done, t.total) order by t.done desc, t.name)
                   from (select a.name, count(*) done, a.total from jsonb_array_elements(c.ids) e
                         join bnet_quests q on q.id = (e #>> '{}')::bigint join bnet_quest_areas a on a.id = q.area_id
                         group by a.id, a.name, a.total) t), '[]'::jsonb),
    'other', (select count(*) from jsonb_array_elements(c.ids) e where not exists (select 1 from bnet_quests q where q.id = (e #>> '{}')::bigint)))
  from bnet_char_quests c where members ? c.char_slug
  on conflict (coll, id) do update set data = excluded.data, updated_at = now()
  where docs.data->'z' is distinct from excluded.data->'z' or docs.data->'other' is distinct from excluded.data->'other';
end $$;
revoke execute on function public.guild_zones_publish() from public, anon, authenticated;

-- Loads the zones and their quest lists, one request per zone, for at most p_seconds; makes no request once all are loaded.
create or replace function public.guild_zones_fill(p_seconds int default 30)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare cid text; sec text; region text; st int; body text; hdr http_header[]; aid bigint; did boolean := false;
        t0 timestamptz := clock_timestamp(); lim interval := make_interval(secs => greatest(1, least(coalesce(p_seconds, 30), 50)));
begin
  if not pg_try_advisory_xact_lock(4273002) then return jsonb_build_object('busy', true); end if;
  if exists (select 1 from bnet_quest_areas) and not exists (select 1 from bnet_quest_areas where not loaded) then
    return jsonb_build_object('zones_to_load', 0);
  end if;
  select v into cid from bnet_config where k = 'client_id';
  select v into sec from bnet_config where k = 'client_secret';
  if coalesce(cid, '') = '' or coalesce(sec, '') = '' then raise exception 'bnet_config: client_id / client_secret are not set'; end if;
  region := coalesce((select v from bnet_config where k = 'region'), 'eu');
  if region !~ '^[a-z]{2}$' then raise exception 'bnet_config: bad region'; end if;
  perform http_set_curlopt('CURLOPT_TIMEOUT', '20');
  select h.status, h.content into st, body from http(('POST', 'https://oauth.battle.net/token',
    array[http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || sec, 'utf8'), 'base64'), E'\n', ''))],
    'application/x-www-form-urlencoded', 'grant_type=client_credentials')::http_request) h;
  if st <> 200 then raise exception 'battle.net token: HTTP %', st; end if;
  hdr := array[http_header('Authorization', 'Bearer ' || (body::jsonb->>'access_token'))];
  if not exists (select 1 from bnet_quest_areas) then
    select h.status, h.content into st, body from http(('GET',
      format('https://%s.api.blizzard.com/data/wow/quest/area/index?namespace=static-forever-%s&locale=en_US', region, region), hdr, null, null)::http_request) h;
    if st <> 200 then raise exception 'quest areas: HTTP %', st; end if;
    insert into bnet_quest_areas (id, name)
    select distinct on ((a->>'id')::bigint) (a->>'id')::bigint, a->>'name' from jsonb_array_elements(coalesce(body::jsonb->'areas', '[]'::jsonb)) a
    where a->>'id' ~ '^[0-9]+$' and coalesce(a->>'name', '') <> ''
    on conflict (id) do nothing;
  end if;
  for aid in select a.id from bnet_quest_areas a where not a.loaded order by a.id loop
    exit when clock_timestamp() - t0 > lim;
    select h.status, h.content into st, body from http(('GET',
      format('https://%s.api.blizzard.com/data/wow/quest/area/%s?namespace=static-forever-%s&locale=en_US', region, aid, region), hdr, null, null)::http_request) h;
    continue when st not in (200, 404);
    if st = 200 then
      insert into bnet_quests (id, area_id)
      select distinct on ((x->>'id')::bigint) (x->>'id')::bigint, aid from jsonb_array_elements(coalesce(body::jsonb->'quests', '[]'::jsonb)) x where x->>'id' ~ '^[0-9]+$'
      on conflict (id) do nothing;
    end if;
    update bnet_quest_areas set loaded = true, total = (select count(*) from bnet_quests q where q.area_id = aid) where id = aid;
    did := true;
  end loop;
  if did then perform guild_zones_publish(); end if;
  return jsonb_build_object('zones_to_load', (select count(*) from bnet_quest_areas where not loaded));
end $$;
revoke execute on function public.guild_zones_fill(int) from public, anon, authenticated;

-- Tooltip lines for one equipped item, in the armory's order: [[text, kind, right?], ...].
-- kind: '' plain, 'g' green (bonuses, enchants, use effects), 'y' gold (set name, flavour text), 'm' muted (inactive, sell price).
-- "right" is the right-aligned half of a two-part line (Head | Mail, 39 - 74 Damage | Speed 1.90).
create or replace function public.bnet_item_tip(i jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(l order by ord), '[]'::jsonb) from (
    select 1::numeric ord, jsonb_build_array(i->'binding'->>'name', '') l where i->'binding'->>'name' is not null
    union all select 2, jsonb_build_array(i->>'unique_equipped', '') where jsonb_typeof(i->'unique_equipped') = 'string'
    union all select 3, jsonb_build_array(i->'inventory_type'->>'name', '',
        case when coalesce((i->>'is_subclass_hidden')::boolean, false) then '' else coalesce(i->'item_subclass'->>'name', '') end)
      where i->'inventory_type'->>'name' is not null
    union all select 3.5, jsonb_build_array(i->'container_slots'->>'display_string', '') where i->'container_slots'->>'display_string' is not null
    union all select 4, jsonb_build_array(i->'weapon'->'damage'->>'display_string', '', coalesce(i->'weapon'->'attack_speed'->>'display_string', ''))
      where i->'weapon'->'damage'->>'display_string' is not null
    union all select 5, jsonb_build_array(i->'weapon'->'dps'->>'display_string', '') where i->'weapon'->'dps'->>'display_string' is not null
    union all select 6, jsonb_build_array(i->'armor'->'display'->>'display_string', '') where i->'armor'->'display'->>'display_string' is not null
    union all select 7, jsonb_build_array(i->'shield_block'->'display'->>'display_string', '') where i->'shield_block'->'display'->>'display_string' is not null
    union all select 8 + case when coalesce((s.v->>'is_equip_bonus')::boolean, false) then 0.5 else 0 end + s.n / 1000.0,
        jsonb_build_array(s.v->'display'->>'display_string', case when coalesce((s.v->>'is_equip_bonus')::boolean, false) then 'g' else '' end)
      from jsonb_array_elements(case when jsonb_typeof(i->'stats') = 'array' then i->'stats' else '[]'::jsonb end) with ordinality s(v, n)
      where s.v->'display'->>'display_string' is not null
    union all select 10 + e.n / 1000.0, jsonb_build_array(e.v->>'display_string', 'g')
      from jsonb_array_elements(case when jsonb_typeof(i->'enchantments') = 'array' then i->'enchantments' else '[]'::jsonb end) with ordinality e(v, n)
      where e.v->>'display_string' is not null
    union all select 11, jsonb_build_array(i->'durability'->>'display_string', '') where i->'durability'->>'display_string' is not null
    union all select 12, jsonb_build_array(i->'requirements'->'level'->>'display_string', '') where i->'requirements'->'level'->>'display_string' is not null
    union all select 13 + p.n / 1000.0, jsonb_build_array(p.v->>'description', 'g')
      from jsonb_array_elements(case when jsonb_typeof(i->'spells') = 'array' then i->'spells' else '[]'::jsonb end) with ordinality p(v, n)
      where coalesce(p.v->>'description', '') <> ''
    union all select 14, jsonb_build_array(coalesce(i->'set'->>'display_string', i->'set'->'item_set'->>'name'), 'y')
      where coalesce(i->'set'->>'display_string', i->'set'->'item_set'->>'name') is not null
    union all select 14.1 + t.n / 1000.0, jsonb_build_array(t.v->'item'->>'name', case when coalesce((t.v->>'is_equipped')::boolean, false) then 'y' else 'm' end)
      from jsonb_array_elements(case when jsonb_typeof(i->'set'->'items') = 'array' then i->'set'->'items' else '[]'::jsonb end) with ordinality t(v, n)
      where t.v->'item'->>'name' is not null
    union all select 14.5 + f.n / 1000.0, jsonb_build_array(f.v->>'display_string', case when coalesce((f.v->>'is_active')::boolean, false) then 'g' else 'm' end)
      from jsonb_array_elements(case when jsonb_typeof(i->'set'->'effects') = 'array' then i->'set'->'effects' else '[]'::jsonb end) with ordinality f(v, n)
      where f.v->>'display_string' is not null
    union all select 15, jsonb_build_array('"' || (i->>'description') || '"', 'y') where jsonb_typeof(i->'description') = 'string' and i->>'description' <> ''
    union all select 16, jsonb_build_array(concat_ws(' ', coalesce(i->'sell_price'->'display_strings'->>'header', 'Sell Price:'),
        nullif(i->'sell_price'->'display_strings'->>'gold', '0') || 'g', nullif(i->'sell_price'->'display_strings'->>'silver', '0') || 's',
        nullif(i->'sell_price'->'display_strings'->>'copper', '0') || 'c'), 'm')
      where coalesce((i->'sell_price'->>'value')::numeric, 0) > 0
  ) x
$$;
revoke execute on function public.bnet_item_tip(jsonb) from public, anon, authenticated;

-- 2026-11-13: character sheets. For every guild character of level 10+ (Blizzard has no profile below that):
--   gchars/{slug}  {at, ilvl, ruleset, login (ms), img (full-body render), avatar,
--                   items: {SLOT: {id, name, q (POOR..LEGENDARY), lvl, icon, tip}},   SLOT is Blizzard's slot type (HEAD, FINGER_1, ...);
--                          tip = tooltip lines from bnet_item_tip() above
--                   profs: {Profession: {s (skill), max, n (known recipes)}}}    English names, as in the page's PROFS
-- A character that fails to load keeps its previous sheet. At most 60 new icons are fetched per run, the rest next hour.
create or replace function public.guild_sync()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare cid text; sec text; region text; slug text; tok text; st int; body text; r jsonb; members jsonb; lv jsonb;
        hdr http_header[]; ch text; base text; q text; pr jsonb; eq jsonb; md jsonb; items jsonb; mid bigint; profs jsonb;
        pf jsonb; ptiers jsonb := '{}'::jsonb; pk text; rid bigint; rd jsonb; t0 timestamptz;
        oldd jsonb; stt jsonb; pvp jsonb; reps jsonb; qs jsonb; j jsonb; ast jsonb; ach jsonb; dgs jsonb; aid bigint;
        icons_left int := 60; sheets int := 0;
        now_ms numeric := floor(extract(epoch from clock_timestamp()) * 1000);
begin
  select v into cid from bnet_config where k = 'client_id';
  select v into sec from bnet_config where k = 'client_secret';
  if coalesce(cid, '') = '' or coalesce(sec, '') = '' then raise exception 'bnet_config: client_id / client_secret are not set'; end if;
  region := coalesce((select v from bnet_config where k = 'region'), 'eu');
  slug := coalesce((select v from bnet_config where k = 'guild'), 'kute-expats');
  if region !~ '^[a-z]{2}$' or slug !~ '^[a-z0-9-]{1,64}$' then raise exception 'bnet_config: bad region or guild'; end if;
  perform http_set_curlopt('CURLOPT_TIMEOUT', '20');
  -- encode() wraps base64 at 76 characters, so the line breaks have to go
  select h.status, h.content into st, body from http(('POST', 'https://oauth.battle.net/token',
    array[http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || sec, 'utf8'), 'base64'), E'\n', ''))],
    'application/x-www-form-urlencoded', 'grant_type=client_credentials')::http_request) h;
  if st <> 200 then raise exception 'battle.net token: HTTP %', st; end if;
  tok := body::jsonb->>'access_token';
  hdr := array[http_header('Authorization', 'Bearer ' || tok)];
  select h.status, h.content into st, body from http(('GET',
    format('https://%s.api.blizzard.com/data/wow/guild/%s/roster?namespace=profile-forever-%s&locale=en_US', region, slug, region),
    hdr, null, null)::http_request) h;
  if st <> 200 then raise exception 'guild roster: HTTP %', st; end if;
  r := body::jsonb;
  select jsonb_object_agg(m->'character'->>'slug', jsonb_build_object(
           'name', m->'character'->'name', 'surname', coalesce(m->'character'->'surname', '""'::jsonb),
           'level', m->'character'->'level', 'cls', m->'character'->'playable_class'->'id',
           'race', m->'character'->'playable_race'->'id', 'rank', m->'rank')),
         jsonb_object_agg(m->'character'->>'slug', m->'character'->'level')
    into members, lv
  from jsonb_array_elements(r->'members') m
  where coalesce(m->'character'->>'slug', '') <> '' and jsonb_typeof(m->'character'->'level') = 'number';
  if members is null then raise exception 'guild roster: no members'; end if;
  insert into docs (coll, id, data) values
    ('guild', 'roster', jsonb_build_object('name', coalesce(r->'guild'->>'name', slug), 'at', now_ms, 'members', members)),
    ('glevels', to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD'), jsonb_build_object('at', now_ms, 'lv', lv))
  on conflict (coll, id) do update set data = excluded.data, updated_at = now();

  -- Character sheets: profile, equipment and renders. One character failing must not stop the rest.
  q := format('?namespace=profile-forever-%s&locale=en_US', region);
  for ch in select e.key from jsonb_each(members) e where (e.value->>'level')::int >= 10 order by e.key loop
    begin
      base := format('https://%s.api.blizzard.com/profile/wow/character/%s', region, urlencode(ch));
      select h.status, h.content into st, body from http(('GET', base || q, hdr, null, null)::http_request) h;
      if st <> 200 then continue; end if;
      pr := body::jsonb;
      -- The roster and the profile are cached separately by Blizzard and either can lag after a level-up: keep the higher level.
      if pr->>'level' ~ '^[0-9]+$' and (pr->>'level')::int > coalesce((members->ch->>'level')::int, 0) then
        members := jsonb_set(members, array[ch, 'level'], pr->'level');
        lv := jsonb_set(lv, array[ch], pr->'level');
      end if;
      select h.status, h.content into st, body from http(('GET', base || '/equipment' || q, hdr, null, null)::http_request) h;
      if st <> 200 then continue; end if;
      eq := body::jsonb;
      select h.status, h.content into st, body from http(('GET', base || '/character-media' || q, hdr, null, null)::http_request) h;
      md := case when st = 200 then body::jsonb else null end;  -- renders can lag the profile by hours
      select h.status, h.content into st, body from http(('GET', base || '/professions' || q, hdr, null, null)::http_request) h;
      profs := null;
      if st = 200 then
        select coalesce(jsonb_object_agg(x->'profession'->>'name', jsonb_build_object(
                 's', coalesce(x->'tiers'->0->'skill_points', '0'::jsonb), 'max', coalesce(x->'tiers'->0->'max_skill_points', '0'::jsonb),
                 'n', jsonb_array_length(coalesce(x->'tiers'->0->'known_recipes', '[]'::jsonb)))), '{}'::jsonb)
          into profs
        from jsonb_array_elements(coalesce(body::jsonb->'primaries', '[]'::jsonb) || coalesce(body::jsonb->'secondaries', '[]'::jsonb)) x
        where x->'profession'->>'name' is not null;
        -- Known recipes: remember each one (name, profession) and store the character's list for the "Рецепты" tab.
        pf := coalesce(body::jsonb->'primaries', '[]'::jsonb) || coalesce(body::jsonb->'secondaries', '[]'::jsonb);
        insert into bnet_recipes (id, prof, name)
        select distinct on ((k->>'id')::bigint) (k->>'id')::bigint, x->'profession'->>'name', k->>'name'
        from jsonb_array_elements(pf) x, jsonb_array_elements(coalesce(x->'tiers'->0->'known_recipes', '[]'::jsonb)) k
        where x->'profession'->>'name' is not null and k->>'id' ~ '^[0-9]+$' and coalesce(k->>'name', '') <> ''
        on conflict (id) do nothing;
        insert into docs (coll, id, data) values ('grecipes', ch, jsonb_build_object('at', now_ms, 'r', (
          select coalesce(jsonb_object_agg(x->'profession'->>'name', (
                   select coalesce(jsonb_agg((k->>'id')::bigint), '[]'::jsonb)
                   from jsonb_array_elements(coalesce(x->'tiers'->0->'known_recipes', '[]'::jsonb)) k where k->>'id' ~ '^[0-9]+$')), '{}'::jsonb)
          from jsonb_array_elements(pf) x where x->'profession'->>'name' is not null)))
        on conflict (coll, id) do update set data = excluded.data, updated_at = now();
        ptiers := ptiers || coalesce((select jsonb_object_agg(x->'profession'->>'name', jsonb_build_array(x->'profession'->'id', x->'tiers'->0->'tier'->'id'))
          from jsonb_array_elements(pf) x
          where x->'profession'->>'name' is not null and x->'profession'->>'id' ~ '^[0-9]+$' and x->'tiers'->0->'tier'->>'id' ~ '^[0-9]+$'), '{}'::jsonb);
      end if;
      -- 2026-11-14: more of the character sheet. Each part keeps its previous value when its request fails.
      --   st   {hp, pw, pt (power type), str, agi, sta, int, spi, arm, ap, sp, mc, sc, dg}   attributes (crit and dodge in %)
      --   pvp  {hk, rank, maps: [[battleground, played, won, lost]]}
      --   reps [[faction, standing, value, max, tier]]   highest first
      --   q    {done: completed quests, log: [quest names in progress]}
      select d.data into oldd from docs d where d.coll = 'gchars' and d.id = ch;
      stt := oldd->'st'; pvp := oldd->'pvp'; reps := oldd->'reps'; qs := oldd->'q'; ast := oldd->'ast'; ach := oldd->'ach'; dgs := oldd->'dg';
      select h.status, h.content into st, body from http(('GET', base || '/achievements' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        j := case when jsonb_typeof(body::jsonb->'achievements') = 'array' then body::jsonb->'achievements' else '[]'::jsonb end;
        select coalesce(jsonb_agg(jsonb_build_array(x->'achievement'->'name', x->'completed_timestamp') order by (x->>'completed_timestamp')::numeric), '[]'::jsonb)
          into ach
        from jsonb_array_elements(j) x where jsonb_typeof(x->'completed_timestamp') = 'number' and x->'achievement'->>'name' is not null;
        -- definitions of the Spelunker achievements this character has, fetched once each
        for aid in select (x->'achievement'->>'id')::bigint from jsonb_array_elements(j) x
                   where x->'achievement'->>'name' like '%Spelunker' and x->'achievement'->>'id' ~ '^[0-9]+$'
                     and not exists (select 1 from bnet_ach b where b.id = (x->'achievement'->>'id')::bigint) loop
          select h.status, h.content into st, body from http(('GET',
            format('https://%s.api.blizzard.com/data/wow/achievement/%s?namespace=static-forever-%s&locale=en_US', region, aid, region), hdr, null, null)::http_request) h;
          continue when st <> 200;
          insert into bnet_ach (id, name, crit, ord)
          select aid, body::jsonb->>'name', coalesce(jsonb_object_agg(c.v->>'id', c.v->'description'), '{}'::jsonb), coalesce(jsonb_agg(c.v->'description' order by c.n), '[]'::jsonb)
          from jsonb_array_elements(case when jsonb_typeof(body::jsonb->'criteria'->'child_criteria') = 'array' then body::jsonb->'criteria'->'child_criteria' else '[]'::jsonb end)
               with ordinality c(v, n)
          where c.v->>'id' is not null and coalesce(c.v->>'description', '') <> ''
          having body::jsonb->>'name' is not null
          on conflict (id) do nothing;
        end loop;
        select coalesce(jsonb_agg(jsonb_build_array(b.crit->(cc->>'id'), coalesce(cc->'amount', '0'::jsonb), coalesce(cc->'is_completed', 'false'::jsonb)) order by b.id), '[]'::jsonb)
          into dgs
        from jsonb_array_elements(j) x
        join bnet_ach b on b.id = (x->'achievement'->>'id')::bigint,
             jsonb_array_elements(case when jsonb_typeof(x->'criteria'->'child_criteria') = 'array' then x->'criteria'->'child_criteria' else '[]'::jsonb end) cc
        where x->'achievement'->>'id' ~ '^[0-9]+$' and b.crit ? (cc->>'id');
      end if;
      -- 2026-11-14: ast = the game's own statistics ("Total deaths", "World Honorable Kills", boss kills per dungeon, ...):
      --   [[category, name, quantity, description], ...]; sub-categories appear as "Category / Sub-category".
      select h.status, h.content into st, body from http(('GET', base || '/achievements/statistics' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        j := case when jsonb_typeof(body::jsonb->'categories') = 'array' then body::jsonb->'categories' else '[]'::jsonb end;
        select coalesce(jsonb_agg(jsonb_build_array(t.cat, t.v->'name', t.v->'quantity', coalesce(t.v->'description', '""'::jsonb)) order by t.o), '[]'::jsonb)
          into ast
        from (
          select c.v->>'name' cat, x.v, c.n * 1000000 + x.n o
          from jsonb_array_elements(j) with ordinality c(v, n),
               jsonb_array_elements(case when jsonb_typeof(c.v->'statistics') = 'array' then c.v->'statistics' else '[]'::jsonb end) with ordinality x(v, n)
          union all
          select (c.v->>'name') || ' / ' || (sc.v->>'name'), x.v, c.n * 1000000 + sc.n * 1000 + x.n
          from jsonb_array_elements(j) with ordinality c(v, n),
               jsonb_array_elements(case when jsonb_typeof(c.v->'sub_categories') = 'array' then c.v->'sub_categories' else '[]'::jsonb end) with ordinality sc(v, n),
               jsonb_array_elements(case when jsonb_typeof(sc.v->'statistics') = 'array' then sc.v->'statistics' else '[]'::jsonb end) with ordinality x(v, n)
        ) t where t.v->>'name' is not null;
      end if;
      select h.status, h.content into st, body from http(('GET', base || '/statistics' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        j := body::jsonb;
        stt := jsonb_strip_nulls(jsonb_build_object('hp', j->'health', 'pw', j->'power', 'pt', j->'power_type'->'name',
          'str', j->'strength'->'effective', 'agi', j->'agility'->'effective', 'sta', j->'stamina'->'effective',
          'int', j->'intellect'->'effective', 'spi', j->'spirit'->'effective', 'arm', j->'armor'->'effective',
          'ap', j->'attack_power', 'sp', j->'spell_power', 'mc', round((j->'melee_crit'->>'value')::numeric, 2),
          'sc', round((j->'spell_crit'->>'value')::numeric, 2), 'dg', round((j->'dodge'->>'value')::numeric, 2)));
      end if;
      select h.status, h.content into st, body from http(('GET', base || '/pvp-summary' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        j := body::jsonb;
        pvp := jsonb_strip_nulls(jsonb_build_object('hk', j->'honorable_kills', 'rank', j->'pvp_rank', 'maps', (
          select jsonb_agg(jsonb_build_array(m->'world_map'->'name', m->'match_statistics'->'played', m->'match_statistics'->'won', m->'match_statistics'->'lost'))
          from jsonb_array_elements(case when jsonb_typeof(j->'pvp_map_statistics') = 'array' then j->'pvp_map_statistics' else '[]'::jsonb end) m)));
      end if;
      select h.status, h.content into st, body from http(('GET', base || '/reputations' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        select coalesce(jsonb_agg(jsonb_build_array(x->'faction'->'name', x->'standing'->'name', x->'standing'->'value', x->'standing'->'max', x->'standing'->'tier')
                 order by (x->'standing'->>'raw')::numeric desc nulls last, x->'faction'->>'name'), '[]'::jsonb)
          into reps
        from jsonb_array_elements(case when jsonb_typeof(body::jsonb->'reputations') = 'array' then body::jsonb->'reputations' else '[]'::jsonb end) x
        where x->'faction'->>'name' is not null;
      end if;
      select h.status, h.content into st, body from http(('GET', base || '/quests' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        qs := coalesce(qs, '{}'::jsonb) || jsonb_build_object('log', coalesce((
          select jsonb_agg(x->'name') from jsonb_array_elements(case when jsonb_typeof(body::jsonb->'in_progress') = 'array' then body::jsonb->'in_progress' else '[]'::jsonb end) x
          where x->>'name' is not null), '[]'::jsonb));
      end if;
      select h.status, h.content into st, body from http(('GET', base || '/quests/completed' || q, hdr, null, null)::http_request) h;
      if st = 200 then
        qs := coalesce(qs, '{}'::jsonb) || jsonb_build_object('done',
          jsonb_array_length(case when jsonb_typeof(body::jsonb->'quests') = 'array' then body::jsonb->'quests' else '[]'::jsonb end));
        insert into bnet_char_quests (char_slug, ids) values (ch, coalesce((
          select jsonb_agg((x->>'id')::bigint) from jsonb_array_elements(case when jsonb_typeof(body::jsonb->'quests') = 'array' then body::jsonb->'quests' else '[]'::jsonb end) x
          where x->>'id' ~ '^[0-9]+$'), '[]'::jsonb))
        on conflict (char_slug) do update set ids = excluded.ids;
      end if;
      for mid in select distinct (i->'media'->>'id')::bigint from jsonb_array_elements(coalesce(eq->'equipped_items', '[]'::jsonb)) i
                 where i->'media'->>'id' is not null and not exists (select 1 from bnet_icons b where b.id = (i->'media'->>'id')::bigint) loop
        exit when icons_left <= 0;
        icons_left := icons_left - 1;
        select h.status, h.content into st, body from http(('GET',
          format('https://%s.api.blizzard.com/data/wow/media/item/%s?namespace=static-forever-%s', region, mid, region), hdr, null, null)::http_request) h;
        if st in (200, 404) then
          insert into bnet_icons (id, icon) values (mid, coalesce((select a->>'value' from jsonb_array_elements(
            case when st = 200 then body::jsonb->'assets' else '[]'::jsonb end) a where a->>'key' = 'icon' limit 1), ''))
          on conflict (id) do nothing;
        end if;
      end loop;
      select coalesce(jsonb_object_agg(i->'slot'->>'type', jsonb_strip_nulls(jsonb_build_object(
               'id', i->'item'->'id', 'name', i->'name', 'q', i->'quality'->'type', 'lvl', i->'level'->'value', 'icon', nullif(b.icon, ''), 'tip', bnet_item_tip(i)))), '{}'::jsonb)
        into items
      from jsonb_array_elements(coalesce(eq->'equipped_items', '[]'::jsonb)) i
      left join bnet_icons b on b.id = (i->'media'->>'id')::bigint
      where i->'slot'->>'type' is not null;
      insert into docs (coll, id, data) values ('gchars', ch, jsonb_strip_nulls(jsonb_build_object(
        'at', now_ms, 'ilvl', pr->'equipped_item_level', 'ruleset', pr->'ruleset'->'name', 'login', pr->'last_login_timestamp',
        'img', coalesce((select a->'value' from jsonb_array_elements(md->'assets') a where a->>'key' = 'main-raw' limit 1),
                        (select d.data->'img' from docs d where d.coll = 'gchars' and d.id = ch)),
        'avatar', coalesce((select a->'value' from jsonb_array_elements(md->'assets') a where a->>'key' = 'avatar' limit 1),
                           (select d.data->'avatar' from docs d where d.coll = 'gchars' and d.id = ch)),
        'profs', coalesce(profs, (select d.data->'profs' from docs d where d.coll = 'gchars' and d.id = ch)),
        'st', stt, 'pvp', pvp, 'reps', reps, 'q', qs, 'ast', ast, 'ach', ach, 'dg', dgs,
        'items', items)))
      on conflict (coll, id) do update set data = excluded.data, updated_at = now();
      sheets := sheets + 1;
    exception when others then
      raise warning 'guild_sync: % skipped: %', ch, sqlerrm;
    end;
  end loop;
  -- Every dungeon the game tracks, for the "Подземелья" tab. The full list needs all Spelunker definitions, also the ones
  -- nobody has started, so they are read from the "Dungeons" achievement category once. Never allowed to break the sync.
  begin
    if not exists (select 1 from bnet_ach where name like 'Master%') then
      select h.status, h.content into st, body from http(('GET',
        format('https://%s.api.blizzard.com/data/wow/achievement-category/index?namespace=static-forever-%s&locale=en_US', region, region), hdr, null, null)::http_request) h;
      if st = 200 then
        select (c->>'id')::bigint into aid from jsonb_array_elements(coalesce(body::jsonb->'categories', '[]'::jsonb)) c where c->>'name' = 'Dungeons' and c->>'id' ~ '^[0-9]+$' limit 1;
        if aid is not null then
          select h.status, h.content into st, body from http(('GET',
            format('https://%s.api.blizzard.com/data/wow/achievement-category/%s?namespace=static-forever-%s&locale=en_US', region, aid, region), hdr, null, null)::http_request) h;
          if st = 200 then
            j := coalesce(body::jsonb->'achievements', '[]'::jsonb);
            for aid in select (x->>'id')::bigint from jsonb_array_elements(j) x
                       where x->>'name' like '%Spelunker' and x->>'id' ~ '^[0-9]+$' and not exists (select 1 from bnet_ach b where b.id = (x->>'id')::bigint) loop
              select h.status, h.content into st, body from http(('GET',
                format('https://%s.api.blizzard.com/data/wow/achievement/%s?namespace=static-forever-%s&locale=en_US', region, aid, region), hdr, null, null)::http_request) h;
              continue when st <> 200;
              insert into bnet_ach (id, name, crit, ord)
              select aid, body::jsonb->>'name', coalesce(jsonb_object_agg(c.v->>'id', c.v->'description'), '{}'::jsonb), coalesce(jsonb_agg(c.v->'description' order by c.n), '[]'::jsonb)
              from jsonb_array_elements(case when jsonb_typeof(body::jsonb->'criteria'->'child_criteria') = 'array' then body::jsonb->'criteria'->'child_criteria' else '[]'::jsonb end)
                   with ordinality c(v, n)
              where c.v->>'id' is not null and coalesce(c.v->>'description', '') <> ''
              having body::jsonb->>'name' is not null
              on conflict (id) do nothing;
            end loop;
          end if;
        end if;
      end if;
    end if;
    -- the same achievement exists in several copies with the same dungeons: keep the first copy of each name
    insert into docs (coll, id, data)
    select 'guild', 'dungeons', jsonb_build_object('at', now_ms, 'list', coalesce(jsonb_agg(jsonb_build_array(d.v, f.name) order by f.id, d.n), '[]'::jsonb))
    from (select distinct on (name) id, name, ord from bnet_ach order by name, id) f, jsonb_array_elements(f.ord) with ordinality d(v, n)
    having count(*) > 0
    on conflict (coll, id) do update set data = excluded.data, updated_at = now()
    where docs.data->'list' is distinct from excluded.data->'list';
  exception when others then
    raise warning 'guild_sync: dungeon list skipped: %', sqlerrm;
  end;
  -- Levels corrected from the profiles above
  update docs set data = jsonb_set(data, '{members}', members), updated_at = now()
  where coll = 'guild' and id = 'roster' and data->'members' is distinct from members;
  update docs set data = jsonb_set(data, '{lv}', lv), updated_at = now()
  where coll = 'glevels' and id = to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD') and data->'lv' is distinct from lv;
  -- Quest progress per zone (the zone lists themselves are loaded by guild_zones_fill every 5 minutes until complete).
  begin
    perform guild_zones_publish();
  exception when others then
    raise warning 'guild_sync: zones skipped: %', sqlerrm;
  end;
  -- Recipes. Never allowed to break the rest of the sync.
  begin
    -- 1. Categories: one catalogue request per profession, once.
    for pk in select e.key from jsonb_each(ptiers) e where not exists (select 1 from bnet_prof_cat c where c.prof = e.key) loop
      select h.status, h.content into st, body from http(('GET',
        format('https://%s.api.blizzard.com/data/wow/profession/%s/skill-tier/%s?namespace=static-forever-%s&locale=en_US', region, ptiers->pk->>0, ptiers->pk->>1, region),
        hdr, null, null)::http_request) h;
      continue when st <> 200;
      insert into bnet_recipes (id, prof, name, cat)
      select distinct on ((x->>'id')::bigint) (x->>'id')::bigint, pk, x->>'name', c->>'name'
      from jsonb_array_elements(coalesce(body::jsonb->'categories', '[]'::jsonb)) c, jsonb_array_elements(coalesce(c->'recipes', '[]'::jsonb)) x
      where x->>'id' ~ '^[0-9]+$' and coalesce(x->>'name', '') <> ''
      on conflict (id) do update set cat = excluded.cat;
      insert into bnet_prof_cat (prof) values (pk) on conflict (prof) do update set at = now();
    end loop;
    -- 2. Details, icons and item tooltips are loaded by guild_recipes_fill every 5 minutes. Here it gets only a few
    --    seconds, mostly to publish the lists: a longer sync times out when run by hand from the SQL Editor.
    perform guild_recipes_fill(5);
  exception when others then
    raise warning 'guild_sync: recipes skipped: %', sqlerrm;
  end;
  -- Profession skills of the day, for the "Профессии по дням" charts: glevels/{day}.pr = {slug: {Profession: skill}}
  update docs set updated_at = now(), data = data || jsonb_build_object('pr', coalesce((
    select jsonb_object_agg(d.id, (select jsonb_object_agg(e.key, e.value->'s') from jsonb_each(d.data->'profs') e))
    from docs d where d.coll = 'gchars' and members ? d.id and jsonb_typeof(d.data->'profs') = 'object' and d.data->'profs' <> '{}'::jsonb), '{}'::jsonb))
  where coll = 'glevels' and id = to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD');
  -- PvP of the day, for the "PvP" tab: glevels/{day}.hk = {slug: honorable kills so far}, .pd = {slug: deaths from other players so far}
  update docs set updated_at = now(), data = data || jsonb_build_object(
    'hk', coalesce((select jsonb_object_agg(d.id, d.data->'pvp'->'hk') from docs d
                    where d.coll = 'gchars' and members ? d.id and jsonb_typeof(d.data->'pvp'->'hk') = 'number'), '{}'::jsonb),
    'pd', coalesce((select jsonb_object_agg(d.id, e->2) from docs d, jsonb_array_elements(d.data->'ast') e
                    where d.coll = 'gchars' and members ? d.id and jsonb_typeof(d.data->'ast') = 'array'
                      and e->>1 = 'Total deaths from other players' and jsonb_typeof(e->2) = 'number'), '{}'::jsonb))
  where coll = 'glevels' and id = to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD');
  return jsonb_build_object('members', (select count(*) from jsonb_object_keys(members)), 'sheets', sheets, 'at', now_ms,
    'recipes_to_load', (select count(*) from bnet_recipes b where (b.detail is null or b.icon is null or b.item is null) and b.id in (
      select (e.value #>> '{}')::bigint from docs d, jsonb_each(d.data->'r') p, jsonb_array_elements(p.value) e
      where d.coll = 'grecipes' and members ? d.id)));
end $$;
revoke execute on function public.guild_sync() from public, anon, authenticated;

-- Loads what is still missing for the recipes guild members know, for at most p_seconds, then publishes gcat/{Profession}.
-- Three kinds of request, in this order: recipe details (reagents, description), recipe icons, crafted item tooltips.
-- Does nothing (and makes no request) when everything is loaded. Returns how many recipes still miss something.
create or replace function public.guild_recipes_fill(p_seconds int default 40)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare cid text; sec text; region text; st int; body text; hdr http_header[]; members jsonb; known bigint[]; rid bigint; iid bigint;
        rd jsonb; t0 timestamptz := clock_timestamp(); lim interval := make_interval(secs => greatest(1, least(coalesce(p_seconds, 40), 50)));
        now_ms numeric := floor(extract(epoch from clock_timestamp()) * 1000); todo int;
begin
  if not pg_try_advisory_xact_lock(4273001) then return jsonb_build_object('busy', true); end if;  -- one loader at a time
  select data->'members' into members from docs where coll = 'guild' and id = 'roster';
  select array_agg(distinct (e.value #>> '{}')::bigint) into known
  from docs d, jsonb_each(d.data->'r') p, jsonb_array_elements(p.value) e
  where d.coll = 'grecipes' and members ? d.id;
  select count(*) into todo from bnet_recipes b where b.id = any(known) and (b.detail is null or b.icon is null or b.item is null);
  if coalesce(todo, 0) > 0 then
    select v into cid from bnet_config where k = 'client_id';
    select v into sec from bnet_config where k = 'client_secret';
    if coalesce(cid, '') = '' or coalesce(sec, '') = '' then raise exception 'bnet_config: client_id / client_secret are not set'; end if;
    region := coalesce((select v from bnet_config where k = 'region'), 'eu');
    if region !~ '^[a-z]{2}$' then raise exception 'bnet_config: bad region'; end if;
    perform http_set_curlopt('CURLOPT_TIMEOUT', '20');
    select h.status, h.content into st, body from http(('POST', 'https://oauth.battle.net/token',
      array[http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || sec, 'utf8'), 'base64'), E'\n', ''))],
      'application/x-www-form-urlencoded', 'grant_type=client_credentials')::http_request) h;
    if st <> 200 then raise exception 'battle.net token: HTTP %', st; end if;
    hdr := array[http_header('Authorization', 'Bearer ' || (body::jsonb->>'access_token'))];
    -- 1. recipe details
    for rid in select b.id from bnet_recipes b where b.id = any(known) and b.detail is null order by b.id loop
      exit when clock_timestamp() - t0 > lim;
      select h.status, h.content into st, body from http(('GET',
        format('https://%s.api.blizzard.com/data/wow/recipe/%s?namespace=static-forever-%s&locale=en_US', region, rid, region), hdr, null, null)::http_request) h;
      continue when st not in (200, 404);
      rd := case when st = 200 then body::jsonb else '{}'::jsonb end;
      update bnet_recipes set
        detail = jsonb_strip_nulls(jsonb_build_object('v', 2, 'i', rd->'crafted_item'->'name', 'iid', rd->'crafted_item'->'id',
          'q', rd->'crafted_quantity'->'value', 'ds', nullif(rd->>'description', ''),
          're', (select jsonb_agg(jsonb_build_array(g->'reagent'->'name', g->'quantity')) from jsonb_array_elements(coalesce(rd->'reagents', '[]'::jsonb)) g))),
        item = case when rd->'crafted_item'->>'id' ~ '^[0-9]+$' then item else '{}'::jsonb end  -- nothing crafted (an enchant): no item tooltip to fetch
      where id = rid;
    end loop;
    -- 2. recipe icons
    for rid in select b.id from bnet_recipes b where b.id = any(known) and b.icon is null order by b.id loop
      exit when clock_timestamp() - t0 > lim;
      select h.status, h.content into st, body from http(('GET',
        format('https://%s.api.blizzard.com/data/wow/media/recipe/%s?namespace=static-forever-%s', region, rid, region), hdr, null, null)::http_request) h;
      continue when st not in (200, 404);
      update bnet_recipes set icon = case when st = 200 then coalesce((
        select a->>'value' from jsonb_array_elements(coalesce(body::jsonb->'assets', '[]'::jsonb)) a where a->>'key' = 'icon' limit 1), '') else '' end
      where id = rid;
    end loop;
    -- 3. tooltip of the crafted item (the same lines as on the character sheet)
    for rid, iid in select b.id, (b.detail->>'iid')::bigint from bnet_recipes b
                    where b.id = any(known) and b.item is null and b.detail->>'iid' ~ '^[0-9]+$' order by b.id loop
      exit when clock_timestamp() - t0 > lim;
      select h.status, h.content into st, body from http(('GET',
        format('https://%s.api.blizzard.com/data/wow/item/%s?namespace=static-forever-%s&locale=en_US', region, iid, region), hdr, null, null)::http_request) h;
      continue when st not in (200, 404);
      rd := case when st = 200 then body::jsonb->'preview_item' else null end;
      update bnet_recipes set item = case when jsonb_typeof(rd) = 'object' then jsonb_strip_nulls(jsonb_build_object(
        'iq', rd->'quality'->'type', 'il', coalesce(rd->'level'->'value', body::jsonb->'level'), 'tip', bnet_item_tip(rd))) else '{}'::jsonb end
      where id = rid;
    end loop;
  end if;
  -- publish one row per profession with everything the guild can craft
  insert into docs (coll, id, data)
  select 'gcat', b.prof, jsonb_build_object('at', now_ms, 'r', jsonb_object_agg(b.id::text,
    jsonb_strip_nulls(jsonb_build_object('n', b.name, 'c', b.cat, 'icon', nullif(b.icon, ''), 'ok', case when b.detail is not null then true end))
      || (coalesce(b.detail, '{}'::jsonb) - 'v' - 'iid') || coalesce(b.item, '{}'::jsonb)))
  from bnet_recipes b where b.id = any(known)
  group by b.prof
  on conflict (coll, id) do update set data = excluded.data, updated_at = now()
  where docs.data->'r' is distinct from excluded.data->'r';  -- an idle run rewrites nothing
  return jsonb_build_object('recipes_to_load', (select count(*) from bnet_recipes b
    where b.id = any(known) and (b.detail is null or b.icon is null or b.item is null)));
end $$;
revoke execute on function public.guild_recipes_fill(int) from public, anon, authenticated;
select cron.schedule('guild-recipes', '*/5 * * * *', 'select public.guild_recipes_fill(40)');

select cron.schedule('guild-zones', '*/5 * * * *', 'select public.guild_zones_fill(30)');

-- Every hour at :07. Scheduling under the same name again replaces the job, so a re-run is safe.
select cron.schedule('guild-sync', '7 * * * *', 'select public.guild_sync()');

-- 2026-11-13: players get an optional "char" (guild character slug). The page reads the player's level, class and
-- avatar from that character; the manual level/xp fields stay as a fallback and are no longer edited.
-- Known links, set once and only if the player has none yet (players can change theirs on the character sheet).
update public.docs set data = data || '{"char": "swift-erasborn"}'::jsonb
  where coll = 'players' and id = 'p_kirill' and not (data ? 'char');
update public.docs set data = data || '{"char": "hele-pirozochek"}'::jsonb
  where coll = 'players' and id = 'p_denis' and not (data ? 'char');
update public.docs set data = data || '{"char": "hoof-poof"}'::jsonb
  where coll = 'players' and id = 'p_olesya' and not (data ? 'char');
update public.docs set data = data || '{"char": "searing-steak"}'::jsonb
  where coll = 'players' and id = 'p_yan' and not (data ? 'char');
-- Fifth core player, with a login like the others (password "Forever", must be changed on first login).
insert into public.docs (coll, id, data) values
  ('players', 'p_alexey', $j${"name": "Alexey", "createdAt": 5, "main": {"cls": "", "race": "", "role": ""}, "picks": {}, "profs": {}, "char": "druido-eltorro"}$j$::jsonb)
on conflict (coll, id) do nothing;
insert into public.accounts (player_id, pass_hash, must_change)
values ('p_alexey', extensions.crypt('Forever', extensions.gen_salt('bf')), true)
on conflict (player_id) do nothing;
-- Twinks: players also get an optional "alts" {slug: true} (false = unlinked), set on the character sheet.
