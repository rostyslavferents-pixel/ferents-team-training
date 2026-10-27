-- =====================================================================
-- Ferents Team Training — схема бази даних
-- Як запустити: Supabase → SQL Editor → New query → вставити весь файл → Run.
-- Скрипт можна безпечно запускати повторно: він нічого не видаляє з даних.
--
-- ПЕРЕД ЗАПУСКОМ: заміни ВАШ_EMAIL@gmail.com нижче на свій email,
-- з яким будеш входити в додаток.
-- =====================================================================


-- 1. Тренери, яким дозволено бачити й змінювати дані
create table if not exists public.coaches (
  email text primary key
);

insert into public.coaches (email)
values (lower('ВАШ_EMAIL@gmail.com'))
on conflict do nothing;

-- Перевірка "чи поточний користувач — тренер"
create or replace function public.is_coach()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.coaches
    where email = lower(auth.jwt() ->> 'email')
  );
$$;


-- 2. Доповнюємо існуючу таблицю спортсменів новими полями
alter table public.athletes add column if not exists belt        text;
alter table public.athletes add column if not exists parent_name text;
alter table public.athletes add column if not exists phone       text;
alter table public.athletes add column if not exists notes       text;
alter table public.athletes add column if not exists active      boolean not null default true;
alter table public.athletes add column if not exists created_at  timestamptz not null default now();


-- 3. Відвідування та оплати (тип athlete_id підлаштовується під тип athletes.id)
do $$
declare
  id_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into id_type
  from pg_attribute a
  where a.attrelid = 'public.athletes'::regclass and a.attname = 'id';

  execute format($f$
    create table if not exists public.attendance (
      id          bigint generated always as identity primary key,
      athlete_id  %s not null references public.athletes(id) on delete cascade,
      date        date not null,
      present     boolean not null default true,
      unique (athlete_id, date)
    )$f$, id_type);

  execute format($f$
    create table if not exists public.payments (
      id          bigint generated always as identity primary key,
      athlete_id  %s not null references public.athletes(id) on delete cascade,
      month       date not null,               -- перше число місяця, напр. 2026-10-01
      amount      numeric(10,2) not null default 0,
      paid_at     date not null default current_date,
      note        text,
      unique (athlete_id, month)
    )$f$, id_type);
end $$;


-- 4. Розклад, події, матеріали
create table if not exists public.schedule (
  id          bigint generated always as identity primary key,
  group_name  text not null,
  weekday     smallint not null check (weekday between 1 and 7),  -- 1 = понеділок
  start_time  time not null,
  end_time    time,
  place       text
);

create table if not exists public.events (
  id          bigint generated always as identity primary key,
  title       text not null,
  date        date not null,
  place       text,
  description text
);

create table if not exists public.materials (
  id          bigint generated always as identity primary key,
  title       text not null,
  url         text,
  description text,
  created_at  timestamptz not null default now()
);


-- 5. Безпека: доступ ТІЛЬКИ для залогіненого тренера.
--    Старі політики (зокрема відкритий доступ для anon) видаляються.
do $$
declare
  t text;
  p record;
begin
  foreach t in array array['athletes','attendance','payments','schedule','events','materials','coaches'] loop
    execute format('alter table public.%I enable row level security', t);

    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;

    execute format(
      'create policy coach_all on public.%I for all to authenticated
         using (public.is_coach()) with check (public.is_coach())', t);

    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;


-- 6. Атестації (історія поясів)
do $$
declare id_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into id_type
  from pg_attribute a where a.attrelid = 'public.athletes'::regclass and a.attname = 'id';

  execute format($f$
    create table if not exists public.gradings (
      id          bigint generated always as identity primary key,
      athlete_id  %s not null references public.athletes(id) on delete cascade,
      date        date not null,
      belt        text not null,
      passed      boolean not null default true,
      note        text
    )$f$, id_type);
end $$;

alter table public.gradings enable row level security;
drop policy if exists coach_all on public.gradings;
create policy coach_all on public.gradings for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
revoke all on public.gradings from anon;
notify pgrst, 'reload schema';


-- 7. Повна дата народження та історія ваги
alter table public.athletes add column if not exists birth_date date;

do $$
declare id_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into id_type
  from pg_attribute a where a.attrelid = 'public.athletes'::regclass and a.attname = 'id';

  execute format($f$
    create table if not exists public.weights (
      id          bigint generated always as identity primary key,
      athlete_id  %s not null references public.athletes(id) on delete cascade,
      date        date not null,
      weight      numeric(5,1) not null check (weight > 0),
      unique (athlete_id, date)
    )$f$, id_type);
end $$;

alter table public.weights enable row level security;
drop policy if exists coach_all on public.weights;
create policy coach_all on public.weights for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
revoke all on public.weights from anon;
notify pgrst, 'reload schema';
