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
  if p_coll not in ('players', 'votes', 'meta', 'tasks', 'goals', 'wants', 'deaths', 'bets', 'fame', 'rolls') then
    raise exception 'unknown collection %', p_coll;
  end if;
  -- Roll to Death duels are created and rolled only by deathroll_new / deathroll_roll; the page may only hide one.
  if p_coll = 'rolls' and exists (select 1 from jsonb_object_keys(p_patch) k where k <> 'deleted') then
    raise exception 'rolls are changed only by deathroll functions';
  end if;
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
--   fame/{id}  {who: playerId | "" (whole group), title, icon, at, auto}. Auto ids are deterministic (e.g. lvl20_p_kirill).
--   rolls/{id} {a, b, start, stakeS, rolls: [{by, max, r, at}], winner, loser, endedAt, at}. Written only by the functions
--   below, so the dice are rolled on the server and turns are enforced. stakeS is in silver (1 gold = 100 silver);
--   duels created before 2026-10-23 evening have "stake" in gold instead, and the page reads both.
drop function if exists public.deathroll_new(text, text, text, int, int);  -- parameter renamed p_stake -> p_stake_s
create or replace function public.deathroll_new(p_id text, p_a text, p_b text, p_start int, p_stake_s int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
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

create or replace function public.deathroll_roll(p_id text, p_by text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; rs jsonb; n int; mx int; r int; turn text; now_ms numeric;
begin
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

grant execute on function public.deathroll_new(text, text, text, int, int) to anon, authenticated;
grant execute on function public.deathroll_roll(text, text) to anon, authenticated;

-- 2026-10-23: example bets and the "story so far" Hall of Fame entries. Existing rows (with picks/results) are left alone.
insert into public.docs (coll, id, data) values
  ('bets', 'b_60',    $j${"q": "Кто первым дойдёт до 60?", "opts": ["Denis", "Kirill", "Olesya", "Yan"], "picks": {}, "result": -1, "at": 1792756800000}$j$::jsonb),
  ('bets', 'b_hc',    $j${"q": "Кто первым умрёт в Hardcore?", "opts": ["Denis", "Kirill", "Olesya", "Yan"], "picks": {}, "result": -1, "at": 1792756740000}$j$::jsonb),
  ('bets', 'b_pie',   $j${"q": "Pirozochek удержит агро на первом боссе?", "opts": ["Да", "Нет", "Агро? Какое агро?"], "picks": {}, "result": -1, "at": 1792756680000}$j$::jsonb),
  ('bets', 'b_afk',   $j${"q": "Кто первым скажет «я на минутку» и пропадёт на час?", "opts": ["Denis", "Kirill", "Olesya", "Yan"], "picks": {}, "result": -1, "at": 1792756620000}$j$::jsonb),
  ('bets', 'b_mount', $j${"q": "Кто первым купит маунта?", "opts": ["Denis", "Kirill", "Olesya", "Yan"], "picks": {}, "result": -1, "at": 1792756560000}$j$::jsonb),
  ('bets', 'b_epic',  $j${"q": "Когда у группы будет первый эпик?", "opts": ["Первая неделя", "Первый месяц", "К рейдам", "Не дождёмся"], "picks": {}, "result": -1, "at": 1792756500000}$j$::jsonb),
  ('bets', 'b_ony',   $j${"q": "Сколько вайпов на Onyxia в первый вечер?", "opts": ["0–2", "3–5", "6–10", "Больше 10"], "picks": {}, "result": -1, "at": 1792756440000}$j$::jsonb),
  ('fame', 'f_site',   $j${"who": "", "title": "Планировщик переехал с claude.ai на свой сайт", "icon": "inv_misc_book_09", "at": 1792701000000, "auto": true}$j$::jsonb),
  ('fame', 'f_bots',   $j${"who": "", "title": "Пережили набег ботов: Pipiska, Donald Trump и компания", "icon": "spell_shadow_deathcoil", "at": 1792702800000, "auto": true}$j$::jsonb),
  ('fame', 'f_dropdb', $j${"who": "", "title": "Отбили атаку «DROP DATABASE»", "icon": "spell_holy_divineprotection", "at": 1792703460000, "auto": true}$j$::jsonb),
  ('fame', 'f_pvp',    $j${"who": "", "title": "Группа выбрала PvP (3:0)", "icon": "inv_bannerpvp_02", "at": 1792746000000, "auto": true}$j$::jsonb),
  ('fame', 'f_pie',    $j${"who": "p_denis", "title": "Получил уникальную роль Pirozochek", "icon": "inv_misc_food_11", "at": 1792749600000, "auto": true}$j$::jsonb),
  ('fame', 'f_tavern', $j${"who": "", "title": "Открылась Таверна: первые дуэли Roll to Death", "icon": "inv_misc_dice_02", "at": 1792760400000, "auto": true}$j$::jsonb)
on conflict (coll, id) do nothing;
