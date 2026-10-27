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
alter table public.athletes add column if not exists section     text;  -- секція: Наварія / Сихів
alter table public.athletes add column if not exists achievements text;     -- заслуги (вписує тренер)
alter table public.athletes add column if not exists rating_place integer; -- місце в рейтингу (null — не в рейтингу)


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
alter table public.schedule add column if not exists section text;  -- секція: Наварія / Сихів

create table if not exists public.events (
  id          bigint generated always as identity primary key,
  title       text not null,
  date        date not null,
  place       text,
  description text
);
alter table public.events add column if not exists participants jsonb not null default '[]'::jsonb;  -- id спортсменів-учасників

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


-- 8. Завдання на тренування
create table if not exists public.training_plans (
  id          bigint generated always as identity primary key,
  date        date not null,
  group_name  text,             -- null = для всіх груп
  title       text not null,
  tasks       text,
  created_at  timestamptz not null default now()
);
alter table public.training_plans enable row level security;
drop policy if exists coach_all on public.training_plans;
create policy coach_all on public.training_plans for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
revoke all on public.training_plans from anon;
notify pgrst, 'reload schema';


-- 9. Учасники команди (батьки, спортсмени, тренери) і чат
create table if not exists public.members (
  email       text primary key,
  full_name   text not null,
  role        text not null default 'parent' check (role in ('coach','parent','athlete')),
  created_at  timestamptz not null default now()
);

-- тренер = є в coaches або доданий у members з роллю coach
create or replace function public.is_coach()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coaches where email = lower(auth.jwt() ->> 'email'))
      or exists (select 1 from public.members where email = lower(auth.jwt() ->> 'email') and role = 'coach');
$$;

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_coach()
      or exists (select 1 from public.members where email = lower(auth.jwt() ->> 'email'));
$$;

create or replace function public.my_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select full_name from public.members where email = lower(auth.jwt() ->> 'email')),
    case when public.is_coach() then 'Тренер' end);
$$;

create table if not exists public.chat_messages (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  author_email  text not null default lower(auth.jwt() ->> 'email'),
  author_name   text,
  body          text not null check (char_length(body) between 1 and 2000)
);

-- автор і час повідомлення ставляться автоматично (підробити не можна)
create or replace function public.chat_set_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.author_email := lower(auth.jwt() ->> 'email');
  new.author_name  := public.my_name();
  new.created_at   := now();
  return new;
end $$;
drop trigger if exists chat_set_author on public.chat_messages;
create trigger chat_set_author before insert on public.chat_messages
  for each row execute function public.chat_set_author();

-- доступ
alter table public.members enable row level security;
alter table public.chat_messages enable row level security;
do $$
declare p record;
begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('members','chat_messages') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

create policy coach_all on public.members for all to authenticated
  using (public.is_coach()) with check (public.is_coach());

create policy chat_read   on public.chat_messages for select to authenticated using (public.is_member());
create policy chat_write  on public.chat_messages for insert to authenticated with check (public.is_member());
create policy chat_delete on public.chat_messages for delete to authenticated
  using (public.is_coach() or author_email = lower(auth.jwt() ->> 'email'));

-- батьки й спортсмени можуть переглядати розклад, події та матеріали
drop policy if exists member_read on public.schedule;
drop policy if exists member_read on public.events;
drop policy if exists member_read on public.materials;
create policy member_read on public.schedule  for select to authenticated using (public.is_member());
create policy member_read on public.events    for select to authenticated using (public.is_member());
create policy member_read on public.materials for select to authenticated using (public.is_member());

revoke all on public.members, public.chat_messages from anon;

-- повідомлення в чаті приходять миттєво
do $$
begin
  alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- Фото спортсменів (приватне сховище, бачить лише тренер)
-- =====================================================================
alter table public.athletes add column if not exists photo text;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('athlete-photos', 'athlete-photos', false, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "coach athlete photos" on storage.objects;
create policy "coach athlete photos" on storage.objects for all to authenticated
  using (bucket_id = 'athlete-photos' and public.is_coach())
  with check (bucket_id = 'athlete-photos' and public.is_coach());
