-- Home inventory: single-household Supabase schema
--
-- Run this whole file in a new Supabase project's SQL Editor. The configured
-- owner becomes a manager only when that exact Auth user signs up. Every
-- other newly-created Auth user is inserted as pending by the auth trigger.

create schema if not exists app_private;

create type public.member_role as enum ('manager', 'clerk', 'viewer', 'pending');

create table public.members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- Empty when the Auth identity has no email (for example phone sign-in).
  email text not null default '',
  role public.member_role not null default 'pending',
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint members_approval_matches_role check (
    (role = 'pending' and approved_at is null)
    or (role in ('manager', 'clerk', 'viewer') and approved_at is not null)
  )
);

create table public.records (
  id uuid primary key default gen_random_uuid(),
  item_name text not null check (char_length(trim(item_name)) > 0),
  record_type text not null check (record_type in ('purchase', 'usage', 'adjustment')),
  quantity numeric(12, 3) not null check (quantity <> 0),
  amount numeric(12, 2) check (amount is null or amount >= 0),
  recorded_on date not null default current_date,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index records_recorded_on_idx on public.records (recorded_on desc);
create index records_created_by_idx on public.records (created_by);

-- These functions read membership with their owner privileges, so RLS policies
-- can safely ask about a caller's role without exposing the members table.
create or replace function app_private.current_member_role()
returns public.member_role
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select m.role
  from public.members as m
  where m.user_id = (select auth.uid())
$$;

create or replace function app_private.is_manager()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select (select app_private.current_member_role()) = 'manager'::public.member_role
$$;

create or replace function app_private.can_read_records()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select (select app_private.current_member_role()) in ('manager'::public.member_role, 'clerk'::public.member_role, 'viewer'::public.member_role)
$$;

create or replace function app_private.can_write_records()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select (select app_private.current_member_role()) in ('manager'::public.member_role, 'clerk'::public.member_role)
$$;

revoke all on schema app_private from public;
revoke all on all functions in schema app_private from public;
grant usage on schema app_private to authenticated;
grant execute on all functions in schema app_private to authenticated;

-- The only client-initiated path into members is Auth's protected insert
-- trigger. The configured Gmail is the sole automatic manager assignment.
create or replace function app_private.create_pending_member()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.members (user_id, email, role, approved_at)
  values (
    new.id,
    coalesce(new.email, ''),
    case
      when lower(coalesce(new.email, '')) = '212161f@gmail.com' then 'manager'::public.member_role
      else 'pending'::public.member_role
    end,
    case
      when lower(coalesce(new.email, '')) = '212161f@gmail.com' then now()
      else null
    end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app_private.create_pending_member();

-- Ignore client-supplied attribution on INSERT, and reject any later rewrite.
create or replace function app_private.protect_record_attribution()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    if (select auth.uid()) is null then
      raise exception 'An authenticated user is required to create a record';
    end if;
    new.created_by := (select auth.uid());
  elsif new.created_by is distinct from old.created_by then
    raise exception 'created_by is immutable';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger protect_record_attribution
  before insert or update on public.records
  for each row execute function app_private.protect_record_attribution();

alter table public.members enable row level security;
alter table public.records enable row level security;

-- members: pending users cannot even read their own membership row. Managers
-- alone can see, approve, change roles, or remove membership rows.
create policy "managers manage members"
  on public.members for all to authenticated
  using ((select app_private.is_manager()))
  with check ((select app_private.is_manager()));

-- records: approved managers, clerks, and viewers can read. Only managers and
-- clerks can write; viewer and pending have no write policy at all.
create policy "approved members read inventory"
  on public.records for select to authenticated
  using ((select app_private.can_read_records()));

create policy "managers and clerks insert inventory"
  on public.records for insert to authenticated
  with check ((select app_private.can_write_records()));

create policy "managers and clerks update inventory"
  on public.records for update to authenticated
  using ((select app_private.can_write_records()))
  with check ((select app_private.can_write_records()));

create policy "managers and clerks delete inventory"
  on public.records for delete to authenticated
  using ((select app_private.can_write_records()));

-- Data API access is explicit because new Supabase projects no longer expose
-- public-schema tables automatically. RLS above still governs every row.
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.members, public.records to authenticated;
