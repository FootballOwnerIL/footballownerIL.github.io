-- ===== אתגר יומי + אתגר חבר =====
alter table public.runs add column if not exists kind text not null default 'free';
alter table public.runs add column if not exists ch_day date;
alter table public.runs add column if not exists duel_id uuid;
alter table public.runs add column if not exists score integer;
alter table public.runs drop constraint if exists runs_kind_chk;
alter table public.runs add constraint runs_kind_chk check (kind in ('free', 'daily', 'duel'));
create unique index if not exists runs_one_daily on public.runs (user_id, ch_day) where kind = 'daily';
create unique index if not exists runs_one_duel on public.runs (user_id, duel_id) where kind = 'duel';
create index if not exists runs_daily_rank on public.runs (ch_day, score desc) where kind = 'daily' and status = 'verified';

create table if not exists public.challenges (
  day date primary key,
  seed integer not null,
  created_at timestamptz not null default now()
);
alter table public.challenges enable row level security;
revoke all on public.challenges from anon, authenticated;

create table if not exists public.duels (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  creator uuid not null references auth.users (id) on delete cascade,
  seed integer not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
alter table public.duels enable row level security;
revoke all on public.duels from anon, authenticated;
alter table public.runs drop constraint if exists runs_duel_fk;
alter table public.runs add constraint runs_duel_fk foreign key (duel_id) references public.duels (id) on delete cascade;

-- ריצה חופשית רגילה: לא מערבבים עם ריצות אתגר
create or replace function public.start_run(p_ver text)
returns table(run_id uuid, seed integer)
language plpgsql security definer set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.runs;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '28000'; end if;
  if p_ver is null or length(p_ver) > 20 then raise exception 'bad version' using errcode = '22023'; end if;
  select * into v_row from public.runs r
    where r.user_id = v_uid and r.kind = 'free' and r.started_at is null and r.created_at > now() - interval '6 hours'
    order by r.created_at desc limit 1;
  if found then return query select v_row.id, v_row.seed; return; end if;
  if (select count(*) from public.runs r where r.user_id = v_uid and r.created_at > now() - interval '24 hours') >= 40 then
    raise exception 'run limit' using errcode = 'P0001';
  end if;
  insert into public.runs (user_id, seed, game_ver)
    values (v_uid, (('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28))::int + 1, p_ver)
    returning * into v_row;
  return query select v_row.id, v_row.seed;
end
$fn$;

-- אתגר יומי: אותו seed לכולם באותו יום (UTC), ניסיון אחד למשתמש
create or replace function public.start_daily(p_ver text)
returns table(run_id uuid, seed integer, day date)
language plpgsql security definer set search_path = public
as $fn$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'utc')::date;
  v_seed integer;
  v_row public.runs;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '28000'; end if;
  if p_ver is null or length(p_ver) > 20 then raise exception 'bad version' using errcode = '22023'; end if;
  insert into public.challenges (day, seed)
    values (v_day, (('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28))::int + 1)
    on conflict (day) do nothing;
  select c.seed into v_seed from public.challenges c where c.day = v_day;
  select * into v_row from public.runs r where r.user_id = v_uid and r.kind = 'daily' and r.ch_day = v_day;
  if found then
    if v_row.started_at is not null then raise exception 'already played' using errcode = 'P0001'; end if;
    return query select v_row.id, v_row.seed, v_day;
    return;
  end if;
  insert into public.runs (user_id, seed, game_ver, kind, ch_day)
    values (v_uid, v_seed, p_ver, 'daily', v_day) returning * into v_row;
  return query select v_row.id, v_row.seed, v_day;
end
$fn$;

create or replace function public.daily_info()
returns table(day date, seed integer, my_status text, my_score integer, played boolean)
language sql security definer set search_path = public stable
as $fn$
  select d.day, (select c.seed from public.challenges c where c.day = d.day),
         r.status, r.score, coalesce(r.started_at is not null, false)
  from (select (now() at time zone 'utc')::date as day) d
  left join public.runs r on r.user_id = auth.uid() and r.kind = 'daily' and r.ch_day = d.day
$fn$;

create or replace function public.daily_top5(p_day date default null)
returns table(rank integer, display_name text, score integer, mine boolean)
language sql security definer set search_path = public stable
as $fn$
  select (row_number() over (order by r.score desc, r.verified_at asc))::int,
         coalesce(l.display_name, 'בעלים'), r.score, r.user_id = auth.uid()
  from public.runs r left join public.run_logs l on l.run_id = r.id
  where r.kind = 'daily' and r.status = 'verified' and r.score is not null
    and r.ch_day = coalesce(p_day, (now() at time zone 'utc')::date)
  order by 1 limit 5
$fn$;

-- אתגר חבר
create or replace function public.create_duel(p_ver text)
returns table(code text, run_id uuid, seed integer)
language plpgsql security definer set search_path = public
as $fn$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_code text; v_i integer := 0;
  v_seed integer := (('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28))::int + 1;
  v_duel public.duels; v_run public.runs;
  v_alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if v_uid is null then raise exception 'auth required' using errcode = '28000'; end if;
  if p_ver is null or length(p_ver) > 20 then raise exception 'bad version' using errcode = '22023'; end if;
  if (select count(*) from public.duels d where d.creator = v_uid and d.created_at > now() - interval '24 hours') >= 10 then
    raise exception 'duel limit' using errcode = 'P0001';
  end if;
  loop
    v_code := '';
    for k in 1..5 loop
      v_code := v_code || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
    end loop;
    begin
      insert into public.duels (code, creator, seed) values (v_code, v_uid, v_seed) returning * into v_duel;
      exit;
    exception when unique_violation then
      v_i := v_i + 1;
      if v_i > 20 then raise exception 'code gen failed'; end if;
    end;
  end loop;
  insert into public.runs (user_id, seed, game_ver, kind, duel_id)
    values (v_uid, v_seed, p_ver, 'duel', v_duel.id) returning * into v_run;
  return query select v_duel.code, v_run.id, v_run.seed;
end
$fn$;

-- הצטרפות (או חזרה לאתגר שכבר יצרת/הצטרפת אליו אך עוד לא התחלת)
create or replace function public.join_duel(p_code text, p_ver text)
returns table(code text, run_id uuid, seed integer)
language plpgsql security definer set search_path = public
as $fn$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_duel public.duels; v_run public.runs;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '28000'; end if;
  if p_ver is null or length(p_ver) > 20 then raise exception 'bad version' using errcode = '22023'; end if;
  select * into v_duel from public.duels d where d.code = upper(btrim(coalesce(p_code, ''))) and d.expires_at > now();
  if not found then raise exception 'duel not found' using errcode = 'P0002'; end if;
  select * into v_run from public.runs r where r.user_id = v_uid and r.kind = 'duel' and r.duel_id = v_duel.id;
  if found then
    if v_run.started_at is not null then raise exception 'already played' using errcode = 'P0001'; end if;
    return query select v_duel.code, v_run.id, v_run.seed;
    return;
  end if;
  if (select count(*) from public.runs r where r.duel_id = v_duel.id) >= 2 then
    raise exception 'duel full' using errcode = 'P0001';
  end if;
  insert into public.runs (user_id, seed, game_ver, kind, duel_id)
    values (v_uid, v_duel.seed, p_ver, 'duel', v_duel.id) returning * into v_run;
  return query select v_duel.code, v_run.id, v_run.seed;
end
$fn$;

-- מצב אתגר: ניקוד היריב נחשף רק אחרי שהניקוד שלי אומת (אין "הצצה" לפני משחק)
create or replace function public.get_duel(p_code text)
returns table(code text, expires_at timestamptz, my_status text, my_score integer,
              opp_joined boolean, opp_name text, opp_status text, opp_score integer)
language plpgsql security definer set search_path = public stable
as $fn$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_duel public.duels; v_me public.runs; v_op public.runs; v_name text;
begin
  if v_uid is null then raise exception 'auth required' using errcode = '28000'; end if;
  select * into v_duel from public.duels d where d.code = upper(btrim(coalesce(p_code, '')));
  if not found then raise exception 'duel not found' using errcode = 'P0002'; end if;
  select * into v_me from public.runs r where r.duel_id = v_duel.id and r.user_id = v_uid;
  if not found then raise exception 'not a participant' using errcode = '42501'; end if;
  select * into v_op from public.runs r where r.duel_id = v_duel.id and r.user_id <> v_uid;
  if found then select l.display_name into v_name from public.run_logs l where l.run_id = v_op.id; end if;
  return query select v_duel.code, v_duel.expires_at, v_me.status, v_me.score,
    v_op.id is not null, coalesce(v_name, 'חבר'), v_op.status,
    case when v_me.status = 'verified' and v_op.status = 'verified' then v_op.score else null end;
end
$fn$;

revoke execute on function public.start_run(text), public.start_daily(text), public.daily_info(),
  public.daily_top5(date), public.create_duel(text), public.join_duel(text, text), public.get_duel(text) from public, anon;
grant execute on function public.start_run(text), public.start_daily(text), public.daily_info(),
  public.daily_top5(date), public.create_duel(text), public.join_duel(text, text), public.get_duel(text) to authenticated;
