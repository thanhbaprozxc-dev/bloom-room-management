-- Theo dõi tiền cọc hợp đồng. Migration an toàn, có thể chạy lại nhiều lần.
alter table public.leases
  add column if not exists deposit_status text;

alter table public.leases
  add column if not exists deposit_refunded_at date;

update public.leases
set deposit_status = case
  when coalesce(deposit_refunded, 0) > 0 then 'refunded'
  when status = 'terminated' then 'forfeited'
  when status = 'expired' then 'refundable'
  else 'held'
end
where deposit_status is null or btrim(deposit_status) = '';

alter table public.leases
  alter column deposit_status set default 'held';

alter table public.leases
  alter column deposit_status set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'leases_deposit_status_check'
      and conrelid = 'public.leases'::regclass
  ) then
    alter table public.leases
      add constraint leases_deposit_status_check
      check (deposit_status in ('held', 'refundable', 'refunded', 'forfeited'))
      not valid;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'leases_deposit_refunded_lte_amount'
      and conrelid = 'public.leases'::regclass
  ) then
    alter table public.leases
      add constraint leases_deposit_refunded_lte_amount
      check (deposit_refunded >= 0 and deposit_refunded <= deposit_amount)
      not valid;
  end if;
end $$;

create index if not exists leases_deposit_status_idx
  on public.leases(property_id, deposit_status);

create index if not exists leases_deposit_refunded_at_idx
  on public.leases(property_id, deposit_refunded_at);
