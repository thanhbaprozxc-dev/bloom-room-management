-- Bloom Apartment — Saler và hoa hồng môi giới.
-- Migration này chỉ bổ sung cấu trúc, không xóa hoặc backfill dữ liệu hiện có.

create table if not exists public.sales_agents(
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text,
  email text,
  default_commission_rate numeric(5,2) not null default 0 check(default_commission_rate between 0 and 100),
  status text not null default 'active' check(status in('active','inactive')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.leases add column if not exists sales_agent_id uuid;
do $$ begin
  if not exists(
    select 1 from pg_constraint
    where conname='leases_sales_agent_id_fkey'
      and conrelid='public.leases'::regclass
  ) then
    alter table public.leases
      add constraint leases_sales_agent_id_fkey
      foreign key(sales_agent_id) references public.sales_agents(id) on delete set null;
  end if;
end $$;

create table if not exists public.lease_commissions(
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references public.leases(id) on delete restrict,
  sales_agent_id uuid not null references public.sales_agents(id) on delete restrict,
  sales_agent_name_snapshot text not null,
  monthly_rent_snapshot numeric(14,2) not null check(monthly_rent_snapshot>=0),
  commission_months integer not null check(commission_months>0),
  commission_rate_snapshot numeric(5,2) not null check(commission_rate_snapshot between 0 and 100),
  commission_base_amount numeric(14,2) not null check(commission_base_amount>=0),
  commission_amount numeric(14,2) not null check(commission_amount>=0),
  paid_amount numeric(14,2) not null default 0 check(paid_amount>=0 and paid_amount<=commission_amount),
  status text not null default 'pending' check(status in('pending','partially_paid','paid','cancelled')),
  calculated_at timestamptz not null default now(),
  paid_at timestamptz,
  cancelled_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sales_commission_payments(
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references public.lease_commissions(id) on delete restrict,
  amount numeric(14,2) not null check(amount>0),
  paid_at timestamptz not null default now(),
  method text not null default 'transfer' check(method in('cash','transfer','other')),
  reference text,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists sales_agents_status_idx on public.sales_agents(status,full_name);
create index if not exists leases_sales_agent_idx on public.leases(sales_agent_id);
create index if not exists lease_commissions_agent_idx on public.lease_commissions(sales_agent_id, status);
create index if not exists lease_commissions_lease_idx on public.lease_commissions(lease_id, created_at desc);
create index if not exists sales_commission_payments_commission_idx on public.sales_commission_payments(commission_id, paid_at desc);
create unique index if not exists lease_commissions_one_active_per_lease_uidx
  on public.lease_commissions(lease_id)
  where status <> 'cancelled';

do $$ declare t text; begin
  foreach t in array array['sales_agents','lease_commissions','sales_commission_payments'] loop
    execute format('drop trigger if exists set_%I_updated_at on public.%I',t,t);
    execute format('create trigger set_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()',t,t);
  end loop;
end $$;

do $$ declare t text; begin
  foreach t in array array['sales_agents','lease_commissions','sales_commission_payments'] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end $$;
