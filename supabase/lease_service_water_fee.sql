-- Thêm phí dịch vụ + nước cố định theo từng hợp đồng.
-- Chạy một lần trong Supabase SQL Editor.
alter table public.leases
  add column if not exists service_water_fee numeric(14,2) not null default 0;

do $$
begin
  alter table public.leases
    add constraint leases_service_water_fee_nonnegative
    check (service_water_fee >= 0);
exception
  when duplicate_object then null;
end $$;

