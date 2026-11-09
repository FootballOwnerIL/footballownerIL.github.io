-- אתגרים, גרסה 2. להריץ ב-Supabase SQL Editor (בטוח להריץ שוב).
-- 0) המועדון היומי לא חוזר פעמיים ברצף  1) אתגר יומי לפי חצות בשעון ישראל  2) המועדון של היום נקבע כבר כשפותחים את המסך (לא רק כשמישהו מתחיל)  3) קודי אתגר חבר באורך 6

-- בחירת מועדון היום: אקראי, אבל לא אותו מועדון כמו בפעם הקודמת.
-- 62 = מספר המועדונים במשחק. אם מוסיפים מועדונים, צריך לעדכן כאן את המספר.
create or replace function public.daily_pick_seed(p_day date)
 returns integer
 language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_prev integer; v_seed integer; v_i integer := 0;
  c_n constant integer := 62;
begin
  select (((c.seed::bigint * 2654435761) % 4294967296) % c_n)::integer into v_prev
    from public.challenges c where c.day < p_day order by c.day desc limit 1;
  loop
    v_seed := (('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28))::int + 1;
    exit when v_prev is null or (((v_seed::bigint * 2654435761) % 4294967296) % c_n)::integer <> v_prev or v_i > 50;
    v_i := v_i + 1;
  end loop;
  return v_seed;
end
$function$;

create or replace function public.daily_info()
 returns table(day date, seed integer, my_status text, my_score integer, played boolean)
 language plpgsql security definer set search_path to 'public'
as $function$
#variable_conflict use_column
declare
  v_day date := (now() at time zone 'Asia/Jerusalem')::date;
begin
  insert into public.challenges (day, seed)
    values (v_day, public.daily_pick_seed(v_day))
    on conflict (day) do nothing;
  return query
    select v_day, (select c.seed from public.challenges c where c.day = v_day),
           r.status, r.score, coalesce(r.started_at is not null, false)
    from (select 1) x
    left join public.runs r on r.user_id = auth.uid() and r.kind = 'daily' and r.ch_day = v_day;
end
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
    values (v_day, public.daily_pick_seed(v_day))
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

create or replace function public.create_duel(p_ver text)
 returns table(code text, run_id uuid, seed integer)
 language plpgsql security definer set search_path to 'public'
as $function$
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
    for k in 1..6 loop
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
$function$;
