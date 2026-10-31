-- Telegram-бот: сповіщення батькам, спортсменам і тренеру в Telegram
-- Підключені чати (один акаунт може мати кілька телефонів — мама й тато)
create table if not exists public.telegram_links (
  chat_id     bigint primary key,
  email       text not null,
  tg_name     text,
  created_at  timestamptz not null default now()
);
alter table public.telegram_links enable row level security;
drop policy if exists own_read on public.telegram_links;
drop policy if exists own_delete on public.telegram_links;
create policy own_read on public.telegram_links for select to authenticated
  using (email = lower(auth.jwt() ->> 'email'));
create policy own_delete on public.telegram_links for delete to authenticated
  using (email = lower(auth.jwt() ->> 'email'));
revoke all on public.telegram_links from anon;
grant select, delete on public.telegram_links to authenticated;

-- Одноразові коди для кнопки «Підключити Telegram»
create table if not exists public.telegram_codes (
  code        text primary key,
  email       text not null,
  created_at  timestamptz not null default now()
);
alter table public.telegram_codes enable row level security;
revoke all on public.telegram_codes from anon, authenticated;

create or replace function public.telegram_link_code()
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  me text := lower(auth.jwt() ->> 'email');
  c  text := replace(gen_random_uuid()::text, '-', '');
begin
  if me is null or not (public.is_coach() or public.is_member()) then
    raise exception 'not_member';
  end if;
  delete from public.telegram_codes where email = me or created_at < now() - interval '1 day';
  insert into public.telegram_codes (code, email) values (c, me);
  return c;
end $$;
revoke execute on function public.telegram_link_code() from public, anon;
grant execute on function public.telegram_link_code() to authenticated;

-- Кому надсилати: спільний список email для push і Telegram
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
  select distinct lower(email) from who where lower(email) is distinct from lower(p_exclude);
$$;
revoke execute on function public.notify_emails(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.notify_emails(text,text,text,text,text) to service_role;

create or replace function public.push_targets(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (endpoint text, sub jsonb)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.sub from public.push_subscriptions s
  where lower(s.email) in (select email from public.notify_emails(p_kind, p_audience, p_section, p_group, p_exclude));
$$;
revoke execute on function public.push_targets(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.push_targets(text,text,text,text,text) to service_role;

create or replace function public.telegram_targets(p_kind text, p_audience text, p_section text, p_group text, p_exclude text)
returns table (chat_id bigint)
language sql stable security definer set search_path = public as $$
  select t.chat_id from public.telegram_links t
  where lower(t.email) in (select email from public.notify_emails(p_kind, p_audience, p_section, p_group, p_exclude));
$$;
revoke execute on function public.telegram_targets(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.telegram_targets(text,text,text,text,text) to service_role;

notify pgrst, 'reload schema';
