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
