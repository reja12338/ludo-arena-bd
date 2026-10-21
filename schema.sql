create extension if not exists pgcrypto;

create type public.app_role as enum ('player', 'admin');
create type public.payment_status as enum ('pending', 'approved', 'rejected');
create type public.withdrawal_status as enum ('pending', 'paid', 'rejected');
create type public.tournament_status as enum ('draft', 'upcoming', 'open', 'full', 'in_progress', 'completed', 'cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Player' check (char_length(display_name) <= 60),
  created_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null default 'player'
);

create table public.payment_methods (
  code text primary key check (code in ('bkash','nagad','rocket')),
  label text not null,
  merchant_number text not null,
  instructions text not null default '',
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  entry_fee bigint not null default 0 check (entry_fee >= 0),
  prize_description text,
  capacity integer not null default 4 check (capacity between 2 and 1000),
  status public.tournament_status not null default 'draft',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.tournament_entries (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id),
  user_id uuid not null references auth.users(id),
  payment_status public.payment_status not null default 'pending',
  created_at timestamptz not null default now(),
  unique (tournament_id, user_id)
);

create table public.payment_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  provider text not null references public.payment_methods(code),
  amount_paisa bigint not null check (amount_paisa between 1000 and 5000000),
  sender_phone text not null check (sender_phone ~ '^01[3-9][0-9]{8}$'),
  transaction_id text not null check (char_length(transaction_id) between 4 and 100),
  status public.payment_status not null default 'pending',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  admin_note text,
  created_at timestamptz not null default now()
);
create unique index payment_claims_provider_txn_unique
  on public.payment_claims(provider, lower(transaction_id))
  where status = 'approved';

create table public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  amount_paisa bigint not null check (amount_paisa <> 0),
  entry_type text not null check (entry_type in ('deposit','withdrawal_reserve','withdrawal_refund','prize','entry_fee','admin_adjustment')),
  reference_id uuid,
  description text not null default '',
  created_at timestamptz not null default now()
);

create table public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  provider text not null check (provider in ('bkash','nagad','rocket')),
  amount_paisa bigint not null check (amount_paisa between 5000 and 5000000),
  destination text not null check (destination ~ '^01[3-9][0-9]{8}$'),
  status public.withdrawal_status not null default 'pending',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.tournament_results (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id),
  user_id uuid not null references auth.users(id),
  placement integer not null check (placement > 0),
  prize_paisa bigint not null default 0 check (prize_paisa >= 0),
  approved_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (tournament_id, user_id),
  unique (tournament_id, placement)
);

create or replace function public.is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.user_roles
    where user_id = (select auth.uid()) and role = 'admin'
  );
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'display_name',''), 'Player'));
  insert into public.user_roles(user_id, role) values (new.id, 'player');
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Wallet balance is calculated from the ledger. Clients cannot write ledger rows directly.
create or replace function public.wallet_balance()
returns bigint language sql stable security invoker
set search_path = public, pg_temp
as $$
  select coalesce(sum(amount_paisa), 0)
  from public.wallet_ledger
  where user_id = (select auth.uid());
$$;

create or replace function public.review_payment_claim(p_claim_id uuid, p_approve boolean)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.payment_claims%rowtype;
begin
  if not public.is_admin() then raise exception 'admin_only'; end if;

  select * into c from public.payment_claims where id = p_claim_id for update;
  if not found then raise exception 'claim_not_found'; end if;
  if c.status <> 'pending' then raise exception 'claim_already_reviewed'; end if;

  if p_approve then
    -- Unique approved provider/TxnID index prevents duplicate credit for same transaction.
    if exists (
      select 1 from public.payment_claims
      where provider = c.provider
        and lower(transaction_id) = lower(c.transaction_id)
        and status = 'approved'
        and id <> c.id
    ) then raise exception 'transaction_already_used'; end if;

    update public.payment_claims
      set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
      where id = c.id;

    insert into public.wallet_ledger(user_id, amount_paisa, entry_type, reference_id, description)
      values (c.user_id, c.amount_paisa, 'deposit', c.id, 'Admin-approved manual deposit');
  else
    update public.payment_claims
      set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
      where id = c.id;
  end if;
end;
$$;

create or replace function public.request_withdrawal(
  p_amount_paisa bigint, p_provider text, p_destination text
) returns uuid language plpgsql security definer
set search_path = public, pg_temp
as $$
declare uid uuid := auth.uid(); new_id uuid;
declare current_balance bigint;
begin
  if uid is null then raise exception 'login_required'; end if;
  if p_amount_paisa < 5000 or p_amount_paisa > 5000000 then raise exception 'invalid_amount'; end if;
  if p_provider not in ('bkash','nagad','rocket') then raise exception 'invalid_provider'; end if;
  if p_destination !~ '^01[3-9][0-9]{8}$' then raise exception 'invalid_destination'; end if;

  -- Serialize withdrawals per user to reduce race conditions.
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select coalesce(sum(amount_paisa),0) into current_balance
    from public.wallet_ledger where user_id = uid;
  if current_balance < p_amount_paisa then raise exception 'insufficient_balance'; end if;

  insert into public.withdrawal_requests(user_id, provider, amount_paisa, destination)
    values (uid, p_provider, p_amount_paisa, p_destination) returning id into new_id;
  insert into public.wallet_ledger(user_id, amount_paisa, entry_type, reference_id, description)
    values (uid, -p_amount_paisa, 'withdrawal_reserve', new_id, 'Withdrawal request reserved');
  return new_id;
end;
$$;

create or replace function public.review_withdrawal(p_request_id uuid, p_action text)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare w public.withdrawal_requests%rowtype;
begin
  if not public.is_admin() then raise exception 'admin_only'; end if;
  select * into w from public.withdrawal_requests where id = p_request_id for update;
  if not found then raise exception 'withdrawal_not_found'; end if;
  if w.status <> 'pending' then raise exception 'withdrawal_already_reviewed'; end if;

  if p_action = 'paid' then
    update public.withdrawal_requests set status='paid', reviewed_by=auth.uid(), reviewed_at=now() where id=w.id;
  elsif p_action = 'reject' then
    update public.withdrawal_requests set status='rejected', reviewed_by=auth.uid(), reviewed_at=now() where id=w.id;
    insert into public.wallet_ledger(user_id, amount_paisa, entry_type, reference_id, description)
      values (w.user_id, w.amount_paisa, 'withdrawal_refund', w.id, 'Withdrawal rejected; funds returned');
  else
    raise exception 'invalid_action';
  end if;
end;
$$;

create or replace function public.award_prize(
  p_tournament_id uuid, p_user_id uuid, p_placement integer, p_prize_paisa bigint
) returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare result_id uuid;
begin
  if not public.is_admin() then raise exception 'admin_only'; end if;
  if p_prize_paisa < 0 or p_placement < 1 then raise exception 'invalid_prize'; end if;

  insert into public.tournament_results(tournament_id,user_id,placement,prize_paisa,approved_by)
  values (p_tournament_id,p_user_id,p_placement,p_prize_paisa,auth.uid())
  returning id into result_id;

  if p_prize_paisa > 0 then
    insert into public.wallet_ledger(user_id,amount_paisa,entry_type,reference_id,description)
    values (p_user_id,p_prize_paisa,'prize',result_id,'Admin-approved tournament prize');
  end if;
end;
$$;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.payment_methods enable row level security;
alter table public.tournaments enable row level security;
alter table public.tournament_entries enable row level security;
alter table public.payment_claims enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.withdrawal_requests enable row level security;
alter table public.tournament_results enable row level security;

create policy "profiles read own or admin" on public.profiles for select
using (id = (select auth.uid()) or public.is_admin());
create policy "profiles update own" on public.profiles for update
using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "users read own role; admins read all" on public.user_roles for select
using (user_id = (select auth.uid()) or public.is_admin());

create policy "enabled payment methods visible" on public.payment_methods for select
using (enabled = true or public.is_admin());
create policy "admins manage payment methods" on public.payment_methods for all
using (public.is_admin()) with check (public.is_admin());

create policy "public read open tournaments" on public.tournaments for select
using (status in ('open','upcoming','in_progress','completed') or public.is_admin());
create policy "admins manage tournaments" on public.tournaments for all
using (public.is_admin()) with check (public.is_admin());

create policy "users read own entries or admin" on public.tournament_entries for select
using (user_id = (select auth.uid()) or public.is_admin());
create policy "users read own payment claims or admin" on public.payment_claims for select
using (user_id = (select auth.uid()) or public.is_admin());
create policy "users create own pending payment claims" on public.payment_claims for insert
with check (user_id = (select auth.uid()) and status = 'pending');

create policy "users read own ledger or admin" on public.wallet_ledger for select
using (user_id = (select auth.uid()) or public.is_admin());

create policy "users read own withdrawals or admin" on public.withdrawal_requests for select
using (user_id = (select auth.uid()) or public.is_admin());

create policy "public read tournament results" on public.tournament_results for select
using (true);

-- Never allow client direct writes to ledger, roles, results, or withdrawal rows.
revoke insert, update, delete on public.wallet_ledger from anon, authenticated;
revoke insert, update, delete on public.user_roles from anon, authenticated;
revoke insert, update, delete on public.tournament_results from anon, authenticated;
revoke insert, update, delete on public.withdrawal_requests from anon, authenticated;
revoke update, delete on public.payment_claims from anon, authenticated;
revoke insert, update, delete on public.tournament_entries from anon, authenticated;

grant execute on function public.wallet_balance() to authenticated;
grant execute on function public.review_payment_claim(uuid, boolean) to authenticated;
grant execute on function public.request_withdrawal(bigint, text, text) to authenticated;
grant execute on function public.review_withdrawal(uuid, text) to authenticated;
grant execute on function public.award_prize(uuid, uuid, integer, bigint) to authenticated;

-- Sample payment methods: replace merchant numbers with verified merchant numbers.
insert into public.payment_methods(code,label,merchant_number,instructions,enabled) values
('bkash','bKash','YOUR_BKASH_MERCHANT_NUMBER','অ্যাপ থেকে মার্চেন্ট পেমেন্ট করুন, তারপর Transaction ID জমা দিন।',false),
('nagad','Nagad','YOUR_NAGAD_MERCHANT_NUMBER','নির্দেশনা অনুসারে পেমেন্ট করুন, তারপর Transaction ID জমা দিন।',false),
('rocket','Rocket','YOUR_ROCKET_MERCHANT_NUMBER','নির্দেশনা অনুসারে পেমেন্ট করুন, তারপর Transaction ID জমা দিন।',false)
on conflict (code) do nothing;
