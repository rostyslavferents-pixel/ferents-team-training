-- Опитування: у застосунку і в Telegram (нативні опитування бота)
create table if not exists public.polls (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  question    text not null check (char_length(question) between 1 and 300),
  options     jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 10),
  multi       boolean not null default false,
  audience    text not null default 'all' check (audience in ('all','parents','athletes')),
  section     text,
  group_name  text,
  closed      boolean not null default false
);
alter table public.polls enable row level security;
drop policy if exists coach_all on public.polls;
drop policy if exists member_read on public.polls;
create policy coach_all on public.polls for all to authenticated
  using (public.is_coach()) with check (public.is_coach());
create policy member_read on public.polls for select to authenticated
  using (public.is_member()
    and (audience = 'all' or audience = public.my_role() || 's')
    and public.is_my_group(group_name, section));
revoke all on public.polls from anon;

-- Голоси: один рядок на акаунт (батьки чи спортсмен), choices — номери варіантів
create table if not exists public.poll_votes (
  poll_id     bigint not null references public.polls(id) on delete cascade,
  email       text not null default lower(auth.jwt() ->> 'email'),
  choices     int[] not null,
  via         text not null default 'app',
  updated_at  timestamptz not null default now(),
  primary key (poll_id, email)
);
alter table public.poll_votes enable row level security;
drop policy if exists coach_read on public.poll_votes;
drop policy if exists own_all on public.poll_votes;
create policy coach_read on public.poll_votes for select to authenticated using (public.is_coach());
create policy own_all on public.poll_votes for all to authenticated
  using (email = lower(auth.jwt() ->> 'email'))
  with check (email = lower(auth.jwt() ->> 'email')
    and exists (select 1 from public.polls p where p.id = poll_id and not p.closed));
revoke all on public.poll_votes from anon;

-- Які повідомлення-опитування бот надіслав (щоб записати відповідь із Telegram)
create table if not exists public.poll_messages (
  tg_poll_id  text primary key,
  poll_id     bigint not null references public.polls(id) on delete cascade,
  chat_id     bigint not null,
  message_id  bigint not null
);
alter table public.poll_messages enable row level security;
revoke all on public.poll_messages from anon, authenticated;

-- Підсумок голосів (для всіх, хто бачить опитування)
create or replace function public.poll_counts(p_poll bigint)
returns table (choice int, votes bigint)
language sql stable security definer set search_path = public as $$
  select c, count(*) from public.poll_votes v, unnest(v.choices) c
  where v.poll_id = p_poll
    and (public.is_coach() or exists (select 1 from public.polls p where p.id = p_poll
      and public.is_member() and (p.audience = 'all' or p.audience = public.my_role() || 's')
      and public.is_my_group(p.group_name, p.section)))
  group by c;
$$;
revoke execute on function public.poll_counts(bigint) from public, anon;
grant execute on function public.poll_counts(bigint) to authenticated;

-- Кому надсилати: опитування — як оголошення
create or replace function public.notify_emails(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (email text)
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
    select email from linked where p_kind in ('announcement','poll')
      and (p_audience = 'all' or role || 's' = p_audience)
      and (p_group is null or group_name = p_group)
      and (p_section is null or section is null or section = p_section)
    union select email from linked where p_kind = 'event'
    union select email from linked where p_kind = 'plan' and role = 'athlete'
      and (p_group is null or group_name = p_group)
    union select email from linked where p_kind = 'chat' and role = 'athlete'
    union select email from coaches_all where p_kind in ('chat','joined','request')
  )
  select distinct lower(email) from who where lower(email) is distinct from lower(p_exclude);
$$;
revoke execute on function public.notify_emails(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.notify_emails(text,text,text,text,text) to service_role;

-- Telegram-чати з email (для опитувань — щоб знати, кому вони надіслані)
create or replace function public.telegram_targets_email(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (chat_id bigint, email text)
language sql stable security definer set search_path = public as $$
  select t.chat_id, lower(t.email) from public.telegram_links t
  where lower(t.email) in (select e.email from public.notify_emails(p_kind, p_audience, p_section, p_group, p_exclude) e);
$$;
revoke execute on function public.telegram_targets_email(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.telegram_targets_email(text,text,text,text,text) to service_role;

notify pgrst, 'reload schema';
