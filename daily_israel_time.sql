-- מעבר של האתגר היומי לחצות לפי שעון ישראל (במקום UTC).
-- להריץ ב-Supabase SQL Editor, אחרי 03:00 בלילה בישראל (כדי שלא ייווצר אתגר כפול).
create or replace function public.daily_info()
 returns table(day date, seed integer, my_status text, my_score integer, played boolean)
 language sql stable security definer set search_path to 'public'
as $function$
  select d.day, (select c.seed from public.challenges c where c.day = d.day),
         r.status, r.score, coalesce(r.started_at is not null, false)
  from (select (now() at time zone 'Asia/Jerusalem')::date as day) d
  left join public.runs r on r.user_id = auth.uid() and r.kind = 'daily' and r.ch_day = d.day
$function$;

create or replace function public.daily_top5(p_day date default null::date)
 returns table(rank integer, display_name text, score integer, mine boolean)
 language sql stable security definer set search_path to 'public'
as $function$
  select (row_number() over (order by r.score desc, r.verified_at asc))::int,
         coalesce(l.display_name, 'בעלים'), r.score, r.user_id = auth.uid()
  from public.runs r left join public.run_logs l on l.run_id = r.id
  where r.kind = 'daily' and r.status = 'verified' and r.score is not null
    and r.ch_day = coalesce(p_day, (now() at time zone 'Asia/Jerusalem')::date)
  order by 1 limit 5
$function$;

create or replace function public.start_daily(p_ver text)
 returns table(run_id uuid, seed integer, day date)
 language plpgsql security definer set search_path to 'public'
as $function$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Jerusalem')::date;
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
$function$;
