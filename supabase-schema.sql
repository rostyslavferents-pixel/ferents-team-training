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


-- =====================================================================
-- 11. Батьки бачать лише свого спортсмена
do $$
declare id_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into id_type
  from pg_attribute a where a.attrelid = 'public.athletes'::regclass and a.attname = 'id';
  execute format($f$
    create table if not exists public.member_athletes (
      email      text not null references public.members(email) on delete cascade on update cascade,
      athlete_id %s not null references public.athletes(id) on delete cascade,
      primary key (email, athlete_id)
    )$f$, id_type);
end $$;
alter table public.member_athletes enable row level security;
drop policy if exists coach_all on public.member_athletes;
drop policy if exists own_read on public.member_athletes;
create policy coach_all on public.member_athletes for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
create policy own_read on public.member_athletes for select to authenticated
  using (email = lower(auth.jwt() ->> 'email'));
revoke all on public.member_athletes from anon;

create or replace function public.is_my_athlete(aid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.member_athletes
    where email = lower(auth.jwt() ->> 'email') and athlete_id::text = aid);
$$;

drop policy if exists member_read on public.athletes;
drop policy if exists member_read on public.attendance;
drop policy if exists member_read on public.gradings;
drop policy if exists member_read on public.weights;
create policy member_read on public.athletes   for select to authenticated using (public.is_my_athlete(id::text));
create policy member_read on public.attendance for select to authenticated using (public.is_my_athlete(athlete_id::text));
create policy member_read on public.gradings   for select to authenticated using (public.is_my_athlete(athlete_id::text));
create policy member_read on public.weights    for select to authenticated using (public.is_my_athlete(athlete_id::text));

-- Рейтинг команди: бачать усі учасники (лише імʼя, група, пояс, місце, заслуги)
create or replace function public.team_rating()
returns table (id text, full_name text, section text, group_name text, belt text, rating_place integer, achievements text)
language sql stable security definer set search_path = public as $$
  select a.id::text, a.full_name, a.section, a.group_name, a.belt, a.rating_place, a.achievements
  from public.athletes a
  where public.is_member() and a.rating_place is not null
  order by a.rating_place;
$$;
revoke execute on function public.team_rating() from anon;
notify pgrst, 'reload schema';


-- =====================================================================
-- 12. Запрошення за посиланням і два рівні доступу (батьки / спортсмен)
do $$
declare id_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into id_type
  from pg_attribute a where a.attrelid = 'public.athletes'::regclass and a.attname = 'id';
  execute format($f$
    create table if not exists public.invites (
      code       text primary key,
      athlete_id %s not null references public.athletes(id) on delete cascade,
      role       text not null check (role in ('parent','athlete')),
      uses_left  integer not null default 2,
      expires_at timestamptz not null default now() + interval '30 days',
      created_at timestamptz not null default now()
    )$f$, id_type);
end $$;
alter table public.invites enable row level security;
drop policy if exists coach_all on public.invites;
create policy coach_all on public.invites for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
revoke all on public.invites from anon;

-- Роль поточного користувача: coach / parent / athlete
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select case when public.is_coach() then 'coach'
    else (select role from public.members where email = lower(auth.jwt() ->> 'email')) end;
$$;

-- Спортсмен (або тренер)
create or replace function public.is_athlete_member()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_coach() or exists (select 1 from public.members
    where email = lower(auth.jwt() ->> 'email') and role = 'athlete');
$$;

-- Чи це група одного з «моїх» спортсменів
create or replace function public.is_my_group(g text, s text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.member_athletes ma
    join public.athletes a on a.id = ma.athlete_id
    where ma.email = lower(auth.jwt() ->> 'email')
      and (g is null or a.group_name = g)
      and (s is null or a.section is null or a.section = s));
$$;

-- Вступ за посиланням: створює учасника і привʼязує до спортсмена
create or replace function public.claim_invite(p_code text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare
  inv public.invites;
  em text := lower(auth.jwt() ->> 'email');
  aname text;
begin
  if em is null then raise exception 'not_signed_in'; end if;
  select * into inv from public.invites where code = upper(trim(p_code)) for update;
  if not found then raise exception 'invite_not_found'; end if;
  select full_name into aname from public.athletes where id = inv.athlete_id;
  if exists (select 1 from public.member_athletes where email = em and athlete_id = inv.athlete_id) then
    return aname;
  end if;
  if inv.expires_at < now() or inv.uses_left <= 0 then raise exception 'invite_expired'; end if;
  insert into public.members (email, full_name, role)
    values (em, coalesce(nullif(trim(p_name), ''), em), inv.role)
    on conflict (email) do nothing;
  insert into public.member_athletes (email, athlete_id) values (em, inv.athlete_id)
    on conflict do nothing;
  update public.invites set uses_left = uses_left - 1 where code = inv.code;
  return aname;
end $$;
revoke execute on function public.claim_invite(text, text) from anon;

-- Розклад: лише своєї групи (тренер бачить усе через coach_all)
drop policy if exists member_read on public.schedule;
create policy member_read on public.schedule for select to authenticated
  using (public.is_my_group(group_name, section));

-- Завдання на тренування: лише спортсмени своєї групи
drop policy if exists member_read on public.training_plans;
create policy member_read on public.training_plans for select to authenticated
  using (public.is_athlete_member() and public.is_my_group(group_name, null));

-- Відео й матеріали: лише спортсмени
drop policy if exists member_read on public.materials;
create policy member_read on public.materials for select to authenticated
  using (public.is_athlete_member());

-- Чат: лише спортсмени й тренер
drop policy if exists chat_read on public.chat_messages;
drop policy if exists chat_write on public.chat_messages;
create policy chat_read  on public.chat_messages for select to authenticated using (public.is_athlete_member());
create policy chat_write on public.chat_messages for insert to authenticated with check (public.is_athlete_member());

notify pgrst, 'reload schema';


-- =====================================================================
-- 13. Оголошення від тренера + сповіщення на телефон
create table if not exists public.announcements (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  title       text not null check (char_length(title) between 1 and 120),
  body        text check (char_length(body) <= 3000),
  audience    text not null default 'all' check (audience in ('all','parents','athletes')),
  section     text,     -- null = обидві секції
  group_name  text,     -- null = усі групи
  important   boolean not null default false
);
alter table public.announcements enable row level security;
drop policy if exists coach_all on public.announcements;
drop policy if exists member_read on public.announcements;
create policy coach_all on public.announcements for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
create policy member_read on public.announcements for select to authenticated
  using (public.is_member()
    and (audience = 'all' or audience = public.my_role() || 's')
    and public.is_my_group(group_name, section));
revoke all on public.announcements from anon;

-- Підписки на сповіщення (кожен пристрій — окремий рядок)
create table if not exists public.push_subscriptions (
  endpoint    text primary key,
  email       text not null default lower(auth.jwt() ->> 'email'),
  sub         jsonb not null,
  created_at  timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists own_all on public.push_subscriptions;
create policy own_all on public.push_subscriptions for all to authenticated
  using (email = lower(auth.jwt() ->> 'email'))
  with check (email = lower(auth.jwt() ->> 'email'));
revoke all on public.push_subscriptions from anon;

-- Кому надсилати (викликає лише серверна функція notify)
create or replace function public.push_targets(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (endpoint text, sub jsonb)
language sql stable security definer set search_path = public as $$
  with coaches_all as (
    select email from public.coaches
    union select email from public.members where role = 'coach'
  ),
  linked as (
    select m.email, m.role, a.section, a.group_name
    from public.members m
    join public.member_athletes ma on ma.email = m.email
    join public.athletes a on a.id = ma.athlete_id
    where m.role in ('parent','athlete')
  ),
  who as (
    select email from linked where p_kind = 'announcement'
      and (p_audience = 'all' or role || 's' = p_audience)
      and (p_group is null or group_name = p_group)
      and (p_section is null or section is null or section = p_section)
    union select email from linked where p_kind = 'event'
    union select email from linked where p_kind = 'plan' and role = 'athlete'
      and (p_group is null or group_name = p_group)
    union select email from linked where p_kind = 'chat' and role = 'athlete'
    union select email from coaches_all where p_kind in ('chat','joined')
  )
  select s.endpoint, s.sub from public.push_subscriptions s
  join who on who.email = s.email
  where s.email is distinct from lower(p_exclude);
$$;
revoke execute on function public.push_targets(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.push_targets(text,text,text,text,text) to service_role;

notify pgrst, 'reload schema';


-- =====================================================================
-- Запити на доступ за одним спільним посиланням
create table if not exists public.join_requests (
  id          bigint generated always as identity primary key,
  email       text not null,
  full_name   text not null,
  role        text not null check (role in ('parent','athlete')),
  child_name  text not null,
  child_birth text,
  athlete_id  text,
  created_at  timestamptz not null default now()
);
alter table public.join_requests enable row level security;
drop policy if exists coach_all on public.join_requests;
create policy coach_all on public.join_requests for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
drop policy if exists own_read on public.join_requests;
create policy own_read on public.join_requests for select to authenticated
  using (email = lower(auth.jwt() ->> 'email'));
revoke all on public.join_requests from anon;

-- Імʼя без зайвих пробілів, апострофів і великих літер
create or replace function public.ft_norm(t text) returns text language sql immutable as $$
  select lower(regexp_replace(translate(trim(coalesce(t, '')), '’ʼ''', ''), '[[:space:]]+', ' ', 'g'));
$$;

-- Надіслати запит: шукає дитину за прізвищем, імʼям і датою народження
create or replace function public.request_join(p_name text, p_role text, p_child text, p_birth text)
returns text language plpgsql security definer set search_path = public as $$
declare
  em  text := lower(auth.jwt() ->> 'email');
  n   text := public.ft_norm(p_child);
  rev text;
  ids text[];
begin
  if em is null then raise exception 'not_signed_in'; end if;
  if p_role not in ('parent','athlete') then raise exception 'bad_role'; end if;
  if length(n) < 3 or length(n) > 80 or length(coalesce(p_name, '')) > 60 then raise exception 'bad_input'; end if;
  if (select count(*) from public.join_requests where email = em) >= 5 then raise exception 'too_many'; end if;
  rev := split_part(n, ' ', 2) || ' ' || split_part(n, ' ', 1);
  select array_agg(a.id::text) into ids from public.athletes a
   where public.ft_norm(a.full_name) in (n, rev)
     and (nullif(p_birth, '') is null or a.birth_date is null or a.birth_date::text = p_birth);
  delete from public.join_requests where email = em and public.ft_norm(child_name) = n;
  insert into public.join_requests (email, full_name, role, child_name, child_birth, athlete_id)
  values (em, coalesce(nullif(trim(p_name), ''), em), p_role, trim(p_child), nullif(p_birth, ''),
          case when cardinality(ids) = 1 then ids[1] end);
  return 'ok';
end $$;
revoke execute on function public.request_join(text, text, text, text) from public, anon;
grant execute on function public.request_join(text, text, text, text) to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- Фото від батьків і спортсменів (лише для своєї дитини)
alter table public.athletes add column if not exists photo text;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('athlete-photos', 'athlete-photos', false, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "coach athlete photos" on storage.objects;
create policy "coach athlete photos" on storage.objects for all to authenticated
  using (bucket_id = 'athlete-photos' and public.is_coach())
  with check (bucket_id = 'athlete-photos' and public.is_coach());
drop policy if exists "member athlete photos read" on storage.objects;
create policy "member athlete photos read" on storage.objects for select to authenticated
  using (bucket_id = 'athlete-photos' and public.is_my_athlete((storage.foldername(name))[1]));
drop policy if exists "member athlete photos add" on storage.objects;
create policy "member athlete photos add" on storage.objects for insert to authenticated
  with check (bucket_id = 'athlete-photos' and public.is_my_athlete((storage.foldername(name))[1]));
drop policy if exists "member athlete photos delete" on storage.objects;
create policy "member athlete photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'athlete-photos' and public.is_my_athlete((storage.foldername(name))[1]));

-- Записати шлях до фото у картку (повертає старий шлях, щоб прибрати старий файл)
create or replace function public.set_my_athlete_photo(p_athlete text, p_path text)
returns text language plpgsql security definer set search_path = public as $$
declare old text;
begin
  if not (public.is_coach() or public.is_my_athlete(p_athlete)) then raise exception 'not_mine'; end if;
  if p_path is not null and p_path not like p_athlete || '/%' then raise exception 'bad_path'; end if;
  select photo into old from public.athletes where id::text = p_athlete;
  update public.athletes set photo = p_path where id::text = p_athlete;
  return old;
end $$;
revoke execute on function public.set_my_athlete_photo(text, text) from public, anon;
grant execute on function public.set_my_athlete_photo(text, text) to authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- Сповіщення тренеру про новий запит на доступ
create or replace function public.has_join_request()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.join_requests
    where email = lower(auth.jwt() ->> 'email') and created_at > now() - interval '10 minutes');
$$;
revoke execute on function public.has_join_request() from public, anon;
grant execute on function public.has_join_request() to authenticated;

-- Кому надсилати (викликає лише серверна функція notify)
create or replace function public.push_targets(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (endpoint text, sub jsonb)
language sql stable security definer set search_path = public as $$
  with coaches_all as (
    select email from public.coaches
    union select email from public.members where role = 'coach'
  ),
  linked as (
    select m.email, m.role, a.section, a.group_name
    from public.members m
    join public.member_athletes ma on ma.email = m.email
    join public.athletes a on a.id = ma.athlete_id
    where m.role in ('parent','athlete')
  ),
  who as (
    select email from linked where p_kind = 'announcement'
      and (p_audience = 'all' or role || 's' = p_audience)
      and (p_group is null or group_name = p_group)
      and (p_section is null or section is null or section = p_section)
    union select email from linked where p_kind = 'event'
    union select email from linked where p_kind = 'plan' and role = 'athlete'
      and (p_group is null or group_name = p_group)
    union select email from linked where p_kind = 'chat' and role = 'athlete'
    union select email from coaches_all where p_kind in ('chat','joined','request')
  )
  select s.endpoint, s.sub from public.push_subscriptions s
  join who on who.email = s.email
  where s.email is distinct from lower(p_exclude);
$$;
revoke execute on function public.push_targets(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.push_targets(text,text,text,text,text) to service_role;

notify pgrst, 'reload schema';


-- ===================================================================== (повна версія сповіщень)
-- Оголошення від тренера + сповіщення на телефон
create table if not exists public.announcements (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  title       text not null check (char_length(title) between 1 and 120),
  body        text check (char_length(body) <= 3000),
  audience    text not null default 'all' check (audience in ('all','parents','athletes')),
  section     text,     -- null = обидві секції
  group_name  text,     -- null = усі групи
  important   boolean not null default false
);
alter table public.announcements enable row level security;
drop policy if exists coach_all on public.announcements;
drop policy if exists member_read on public.announcements;
create policy coach_all on public.announcements for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
create policy member_read on public.announcements for select to authenticated
  using (public.is_member()
    and (audience = 'all' or audience = public.my_role() || 's')
    and public.is_my_group(group_name, section));
revoke all on public.announcements from anon;

-- Підписки на сповіщення (кожен пристрій — окремий рядок)
create table if not exists public.push_subscriptions (
  endpoint    text primary key,
  email       text not null default lower(auth.jwt() ->> 'email'),
  sub         jsonb not null,
  created_at  timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists own_all on public.push_subscriptions;
create policy own_all on public.push_subscriptions for all to authenticated
  using (email = lower(auth.jwt() ->> 'email'))
  with check (email = lower(auth.jwt() ->> 'email'));
revoke all on public.push_subscriptions from anon;

-- Кому надсилати (викликає лише серверна функція notify)
create or replace function public.push_targets(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (endpoint text, sub jsonb)
language sql stable security definer set search_path = public as $$
  with coaches_all as (
    select email from public.coaches
    union select email from public.members where role = 'coach'
  ),
  linked as (
    select m.email, m.role, a.section, a.group_name
    from public.members m
    join public.member_athletes ma on ma.email = m.email
    join public.athletes a on a.id = ma.athlete_id
    where m.role in ('parent','athlete')
  ),
  who as (
    select email from linked where p_kind = 'announcement'
      and (p_audience = 'all' or role || 's' = p_audience)
      and (p_group is null or group_name = p_group)
      and (p_section is null or section is null or section = p_section)
    union select email from linked where p_kind = 'event'
    union select email from linked where p_kind = 'plan' and role = 'athlete'
      and (p_group is null or group_name = p_group)
    union select email from linked where p_kind = 'chat' and role = 'athlete'
    union select email from coaches_all where p_kind in ('chat','joined','request')
  )
  select s.endpoint, s.sub from public.push_subscriptions s
  join who on who.email = s.email
  where s.email is distinct from lower(p_exclude);
$$;
revoke execute on function public.push_targets(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.push_targets(text,text,text,text,text) to service_role;

-- Сповіщення тренеру про новий запит на доступ
create or replace function public.has_join_request()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.join_requests
    where email = lower(auth.jwt() ->> 'email') and created_at > now() - interval '10 minutes');
$$;
revoke execute on function public.has_join_request() from public, anon;
grant execute on function public.has_join_request() to authenticated;

notify pgrst, 'reload schema';
