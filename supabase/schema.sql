-- Calistenia Tracker — schema Supabase
-- Una riga per sessione e una per ogni serie registrata.
-- Le scritture passano dalle funzioni save_session / delete_session (atomiche);
-- le tabelle sono leggibili solo dal proprietario (Row Level Security).

create table if not exists public.sessions (
  id            bigint generated always as identity primary key,
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date          date not null,
  day_id        text not null,              -- lun, mar, mer, gio, ven
  deload        boolean not null default false,
  week_number   int,                         -- settimana dall'inizio del ciclo
  week_in_cycle int,                         -- 1..5
  updated_at    timestamptz not null default now(),
  unique (user_id, date, day_id)
);

create table if not exists public.set_logs (
  id            bigint generated always as identity primary key,
  session_id    bigint not null references public.sessions(id) on delete cascade,
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exercise_key  text not null,               -- es. "lun::bar-muscle-up"
  exercise_name text not null,
  set_number    int not null,                -- 1..n
  leg           text check (leg in ('sx', 'dx')),  -- solo pistol squat
  value         numeric not null,
  unit          text not null check (unit in ('rip', 'sec')),
  target        text                          -- es. "5×1" o "12\""
);

create index if not exists set_logs_exercise_idx on public.set_logs (user_id, exercise_key);
create index if not exists sessions_date_idx on public.sessions (user_id, date);

alter table public.sessions enable row level security;
alter table public.set_logs enable row level security;

drop policy if exists "own sessions" on public.sessions;
create policy "own sessions" on public.sessions for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own set_logs" on public.set_logs;
create policy "own set_logs" on public.set_logs for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Salva (o sostituisce) una sessione completa in una sola transazione.
-- payload: { date, dayId, deload, weekNumber, weekInCycle,
--            entries: [{ key, name, target, unit, sets: [{ set, leg, value }] }] }
create or replace function public.save_session(payload jsonb)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  sid bigint;
  en  jsonb;
  st  jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  insert into public.sessions (date, day_id, deload, week_number, week_in_cycle, updated_at)
  values ((payload->>'date')::date, payload->>'dayId', coalesce((payload->>'deload')::boolean, false),
          (payload->>'weekNumber')::int, (payload->>'weekInCycle')::int, now())
  on conflict (user_id, date, day_id) do update
    set deload = excluded.deload, week_number = excluded.week_number,
        week_in_cycle = excluded.week_in_cycle, updated_at = now()
  returning id into sid;

  delete from public.set_logs where session_id = sid;

  for en in select * from jsonb_array_elements(coalesce(payload->'entries', '[]'::jsonb)) loop
    for st in select * from jsonb_array_elements(coalesce(en->'sets', '[]'::jsonb)) loop
      insert into public.set_logs (session_id, exercise_key, exercise_name, set_number, leg, value, unit, target)
      values (sid, en->>'key', en->>'name', (st->>'set')::int, st->>'leg', (st->>'value')::numeric, en->>'unit', en->>'target');
    end loop;
  end loop;

  return sid;
end;
$$;

create or replace function public.delete_session(p_date date, p_day_id text)
returns void
language sql
security invoker
set search_path = ''
as $$
  delete from public.sessions where user_id = auth.uid() and date = p_date and day_id = p_day_id;
$$;

grant execute on function public.save_session(jsonb) to authenticated;
grant execute on function public.delete_session(date, text) to authenticated;

-- Vista comoda per le analisi: una riga per serie con data e contesto.
drop view if exists public.v_sets;
create view public.v_sets with (security_invoker = true) as
select s.date, s.day_id, s.deload, s.week_number, s.week_in_cycle,
       l.exercise_key, l.exercise_name, l.set_number, l.leg, l.value, l.unit, l.target
from public.set_logs l
join public.sessions s on s.id = l.session_id;

drop table if exists public.exercise_feedback;
