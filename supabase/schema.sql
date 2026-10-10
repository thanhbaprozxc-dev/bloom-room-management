-- BLOOM APARTMENT v3 — chạy toàn bộ tệp trong Supabase SQL Editor.
create extension if not exists pgcrypto;
create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;

create table if not exists public.properties(id uuid primary key default gen_random_uuid(),name text not null unique,address text,phone text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
alter table public.properties add column if not exists short_name text;
alter table public.properties add column if not exists property_code text;
alter table public.properties add column if not exists owner_name text;
alter table public.properties add column if not exists owner_phone text;
alter table public.properties add column if not exists email text;
alter table public.properties add column if not exists tax_code text;
alter table public.properties add column if not exists total_floors int not null default 4;
alter table public.properties add column if not exists notes text;
update public.properties set property_code='BLM-'||upper(substr(replace(id::text,'-',''),1,6)) where property_code is null or btrim(property_code)='';
alter table public.properties alter column property_code set not null;
create unique index if not exists properties_code_uidx on public.properties(property_code);
create table if not exists public.property_settings(id uuid primary key default gen_random_uuid(),property_id uuid not null unique references public.properties(id) on delete cascade,electric_rate numeric(12,2) not null default 4000,water_rate numeric(12,2) not null default 0,default_service_fee numeric(14,2) not null default 0,billing_close_day int not null default 28 check(billing_close_day between 1 and 28),payment_due_day int not null default 5 check(payment_due_day between 1 and 28),bank_name text,bank_account text,bank_account_name text,qr_template text default 'compact2',invoice_note text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
alter table public.property_settings add column if not exists bank_bin text default '970407';
create table if not exists public.rooms(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),room_number text not null,floor int,area numeric(8,2),base_rent numeric(14,2) not null default 0,status text not null default 'vacant' check(status in('vacant','occupied','maintenance','reserved')),notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(property_id,room_number));
create table if not exists public.tenants(id uuid primary key default gen_random_uuid(),full_name text not null,phone text,email text,nationality text not null default 'Việt Nam',identity_type text default 'CCCD',identity_number text,date_of_birth date,permanent_address text,emergency_contact text,notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
alter table public.tenants add column if not exists identity_document_path text;
create table if not exists public.leases(id uuid primary key default gen_random_uuid(),room_id uuid not null references public.rooms(id),representative_tenant_id uuid references public.tenants(id),start_date date not null,end_date date not null,monthly_rent numeric(14,2) not null default 0,service_water_fee numeric(14,2) not null default 0 check(service_water_fee>=0),deposit_amount numeric(14,2) not null default 0,payment_due_day int not null default 5 check(payment_due_day between 1 and 28),status text not null default 'active' check(status in('draft','active','expired','terminated')),ended_at date,end_reason text,deposit_refunded numeric(14,2) not null default 0,deposit_status text not null default 'held',deposit_refunded_at date,notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),check(end_date>=start_date));
alter table public.leases add column if not exists service_water_fee numeric(14,2) not null default 0;
alter table public.leases add column if not exists contract_document_path text;
alter table public.leases add column if not exists deposit_status text;
alter table public.leases add column if not exists deposit_refunded_at date;
update public.leases set deposit_status=case when coalesce(deposit_refunded,0)>0 then 'refunded' when status='terminated' then 'forfeited' when status='expired' then 'refundable' else 'held' end where deposit_status is null or btrim(deposit_status)='';
alter table public.leases alter column deposit_status set default 'held';
alter table public.leases alter column deposit_status set not null;
do $$ begin if not exists(select 1 from pg_constraint where conname='leases_deposit_status_check' and conrelid='public.leases'::regclass) then alter table public.leases add constraint leases_deposit_status_check check(deposit_status in('held','refundable','refunded','forfeited')) not valid; end if; end $$;
do $$ begin if not exists(select 1 from pg_constraint where conname='leases_deposit_refunded_lte_amount' and conrelid='public.leases'::regclass) then alter table public.leases add constraint leases_deposit_refunded_lte_amount check(deposit_refunded>=0 and deposit_refunded<=deposit_amount) not valid; end if; end $$;
create table if not exists public.lease_tenants(lease_id uuid not null references public.leases(id) on delete cascade,tenant_id uuid not null references public.tenants(id),is_representative boolean not null default false,move_in_date date,move_out_date date,primary key(lease_id,tenant_id));
create table if not exists public.tenant_visas(id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id) on delete cascade,visa_number text,visa_type text,issued_date date,expiry_date date not null,issuing_country text,document_url text,status text not null default 'active' check(status in('active','renewed','expired','cancelled')),notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table if not exists public.billing_periods(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id),period text not null check(period ~ '^\d{4}-(0[1-9]|1[0-2])$'),status text not null default 'open' check(status in('open','locked')),due_date date,closed_at timestamptz,closed_by text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(property_id,period));
alter table public.billing_periods add column if not exists closed_at timestamptz;
alter table public.billing_periods add column if not exists closed_by text;
create table if not exists public.monthly_room_records(id uuid primary key default gen_random_uuid(),billing_period_id uuid not null references public.billing_periods(id) on delete cascade,room_id uuid not null references public.rooms(id),lease_id uuid references public.leases(id),rent numeric(14,2) not null default 0,electric_start numeric(12,2) not null default 0,electric_end numeric(12,2) not null default 0,electric_end_entered boolean not null default false,electric_rate numeric(12,2) not null default 4000,water_start numeric(12,2) not null default 0,water_end numeric(12,2) not null default 0,water_end_entered boolean not null default false,water_rate numeric(12,2) not null default 0,service_fee numeric(14,2) not null default 0,other_fee numeric(14,2) not null default 0,discount numeric(14,2) not null default 0,previous_debt numeric(14,2) not null default 0,notes text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(billing_period_id,room_id),check(electric_end>=electric_start),check(water_end>=water_start));
create table if not exists public.invoices(id uuid primary key default gen_random_uuid(),record_id uuid not null references public.monthly_room_records(id),property_id uuid references public.properties(id),invoice_number text,invoice_type text not null default 'combined' check(invoice_type in('rent_advance','utility','final_settlement','adjustment','combined')),parent_invoice_id uuid references public.invoices(id) on delete restrict,coverage_start date,coverage_end date,issued_at timestamptz not null default now(),due_date date,total_amount numeric(14,2) not null default 0,paid_amount numeric(14,2) not null default 0,status text not null default 'unpaid' check(status in('draft','unpaid','partial','paid','overdue','cancelled')),locked_at timestamptz,cancelled_at timestamptz,cancel_reason text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table if not exists public.payments(id uuid primary key default gen_random_uuid(),invoice_id uuid not null references public.invoices(id),batch_id uuid,amount numeric(14,2) not null check(amount>0),paid_at timestamptz not null default now(),method text not null default 'transfer' check(method in('cash','transfer','other')),reference text,notes text,idempotency_key text,created_at timestamptz not null default now());
alter table public.payments add column if not exists idempotency_key text;
create table if not exists public.audit_logs(id bigint generated always as identity primary key,action text not null,entity_type text not null,entity_id text,details jsonb,created_at timestamptz not null default now());
create table if not exists public.invoice_items(id uuid primary key default gen_random_uuid(),invoice_id uuid not null references public.invoices(id) on delete cascade,item_type text not null check(item_type in('rent','electricity','water','service_fee','other_fee','previous_debt','discount','adjustment')),description text not null,amount numeric(14,2) not null default 0,quantity numeric(14,3) not null default 1,unit_price numeric(14,2),metadata jsonb,created_at timestamptz not null default now(),unique(invoice_id,item_type));
create table if not exists public.payment_batches(id uuid primary key default gen_random_uuid(),invoice_id uuid not null references public.invoices(id) on delete restrict,cash_amount numeric(14,2) not null default 0 check(cash_amount>=0),transfer_amount numeric(14,2) not null default 0 check(transfer_amount>=0),total_amount numeric(14,2) not null check(total_amount>0),paid_at timestamptz not null default now(),reference text,notes text,idempotency_key text unique,created_at timestamptz not null default now());
alter table public.payments add column if not exists batch_id uuid references public.payment_batches(id) on delete set null;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('private-documents','private-documents',false,3145728,array['image/jpeg','image/png','image/webp']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create index if not exists rooms_status_idx on public.rooms(status); create index if not exists leases_end_date_idx on public.leases(end_date); create index if not exists visas_expiry_idx on public.tenant_visas(expiry_date); create index if not exists records_period_idx on public.monthly_room_records(billing_period_id); create index if not exists payments_invoice_idx on public.payments(invoice_id); create index if not exists invoice_items_invoice_idx on public.invoice_items(invoice_id); create index if not exists payment_batches_invoice_idx on public.payment_batches(invoice_id); create index if not exists payments_batch_idx on public.payments(batch_id);
do $$ declare t text; begin foreach t in array array['properties','property_settings','rooms','tenants','leases','tenant_visas','billing_periods','monthly_room_records','invoices'] loop execute format('drop trigger if exists set_%I_updated_at on public.%I',t,t); execute format('create trigger set_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()',t,t); end loop; end $$;
do $$ declare t text; begin foreach t in array array['properties','property_settings','rooms','tenants','leases','lease_tenants','tenant_visas','billing_periods','monthly_room_records','invoices','payments','invoice_items','payment_batches','audit_logs'] loop execute format('alter table public.%I enable row level security',t); end loop; end $$;

insert into public.properties(name,property_code,address) values('Bloom Apartment','BLOOM','Đà Nẵng') on conflict(name) do update set property_code=coalesce(public.properties.property_code,excluded.property_code);
insert into public.property_settings(property_id) select id from public.properties where name='Bloom Apartment' on conflict(property_id) do nothing;
insert into public.rooms(property_id,room_number,floor,status) select p.id,v.room,left(v.room,1)::int,'vacant' from public.properties p cross join(values('101'),('102'),('103'),('104'),('105'),('201'),('202'),('203'),('204'),('205'),('301'),('302'),('303'),('304'),('305'),('401'),('402'),('403'),('404'),('405'))v(room) where p.name='Bloom Apartment' on conflict(property_id,room_number) do nothing;

-- Ràng buộc đa tòa nhà: mọi dữ liệu nghiệp vụ mang property_id và không thể liên kết chéo tòa nhà.
alter table public.tenants add column if not exists property_id uuid references public.properties(id) on delete restrict;
alter table public.leases add column if not exists property_id uuid references public.properties(id) on delete restrict;
alter table public.lease_tenants add column if not exists property_id uuid references public.properties(id) on delete restrict;
alter table public.tenant_visas add column if not exists property_id uuid references public.properties(id) on delete restrict;
alter table public.monthly_room_records add column if not exists property_id uuid references public.properties(id) on delete restrict;

update public.tenants t set property_id=coalesce(t.property_id,(select r.property_id from public.lease_tenants lt join public.leases l on l.id=lt.lease_id join public.rooms r on r.id=l.room_id where lt.tenant_id=t.id limit 1),(select id from public.properties order by created_at limit 1));
update public.leases l set property_id=r.property_id from public.rooms r where r.id=l.room_id and l.property_id is null;
update public.lease_tenants lt set property_id=l.property_id from public.leases l where l.id=lt.lease_id and lt.property_id is null;
update public.tenant_visas v set property_id=t.property_id from public.tenants t where t.id=v.tenant_id and v.property_id is null;
update public.monthly_room_records m set property_id=b.property_id from public.billing_periods b where b.id=m.billing_period_id and m.property_id is null;

alter table public.tenants alter column property_id set not null;
alter table public.leases alter column property_id set not null;
alter table public.lease_tenants alter column property_id set not null;
create index if not exists leases_deposit_status_idx on public.leases(property_id,deposit_status);
create index if not exists leases_deposit_refunded_at_idx on public.leases(property_id,deposit_refunded_at);
alter table public.tenant_visas alter column property_id set not null;
alter table public.monthly_room_records alter column property_id set not null;

-- Hóa đơn phải thuộc một tòa nhà để mã hóa đơn không bị trùng giữa các tòa nhà.
alter table public.invoices add column if not exists property_id uuid references public.properties(id) on delete restrict;
alter table public.invoices add column if not exists locked_at timestamptz;
alter table public.invoices add column if not exists cancelled_at timestamptz;
alter table public.invoices add column if not exists cancel_reason text;
alter table public.invoices add column if not exists invoice_type text not null default 'combined';
alter table public.invoices add column if not exists parent_invoice_id uuid references public.invoices(id) on delete restrict;
alter table public.invoices add column if not exists coverage_start date;
alter table public.invoices add column if not exists coverage_end date;
update public.invoices i set property_id=m.property_id from public.monthly_room_records m where m.id=i.record_id and i.property_id is null;
alter table public.invoices alter column property_id set not null;
do $$ begin
  alter table public.invoices add constraint invoices_property_fk foreign key(property_id) references public.properties(id) on delete restrict;
exception when duplicate_object then null; end $$;
alter table public.invoices drop constraint if exists invoices_invoice_number_key;
create unique index if not exists invoices_property_number_uidx on public.invoices(property_id,invoice_number) where invoice_number is not null;
create unique index if not exists payments_idempotency_uidx on public.payments(idempotency_key) where idempotency_key is not null;

create unique index if not exists rooms_id_property_uidx on public.rooms(id,property_id);
create unique index if not exists tenants_id_property_uidx on public.tenants(id,property_id);
create unique index if not exists leases_id_property_uidx on public.leases(id,property_id);
create unique index if not exists periods_id_property_uidx on public.billing_periods(id,property_id);
create unique index if not exists leases_one_active_room_uidx on public.leases(room_id) where status='active';
create unique index if not exists tenants_identity_property_uidx on public.tenants(property_id,identity_type,identity_number) where identity_number is not null and btrim(identity_number)<>'';
create unique index if not exists visas_number_property_uidx on public.tenant_visas(property_id,visa_number) where visa_number is not null and btrim(visa_number)<>'';
create index if not exists tenants_property_idx on public.tenants(property_id);
create index if not exists leases_property_idx on public.leases(property_id);
create index if not exists leases_room_idx on public.leases(room_id);
create index if not exists leases_representative_tenant_idx on public.leases(representative_tenant_id);
create index if not exists lease_tenants_tenant_idx on public.lease_tenants(tenant_id);
create index if not exists tenant_visas_property_status_expiry_idx on public.tenant_visas(property_id,status,expiry_date);
create index if not exists monthly_records_property_period_idx on public.monthly_room_records(property_id,billing_period_id);

do $$ begin
  alter table public.leases add constraint leases_room_property_fk foreign key(room_id,property_id) references public.rooms(id,property_id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.leases add constraint leases_tenant_property_fk foreign key(representative_tenant_id,property_id) references public.tenants(id,property_id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.lease_tenants add constraint lease_tenants_lease_property_fk foreign key(lease_id,property_id) references public.leases(id,property_id) on delete cascade;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.lease_tenants add constraint lease_tenants_tenant_property_fk foreign key(tenant_id,property_id) references public.tenants(id,property_id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.tenant_visas add constraint visas_tenant_property_fk foreign key(tenant_id,property_id) references public.tenants(id,property_id) on delete cascade;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.monthly_room_records add constraint records_period_property_fk foreign key(billing_period_id,property_id) references public.billing_periods(id,property_id) on delete cascade;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.monthly_room_records add constraint records_room_property_fk foreign key(room_id,property_id) references public.rooms(id,property_id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.monthly_room_records add constraint records_lease_property_fk foreign key(lease_id,property_id) references public.leases(id,property_id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin alter table public.rooms add constraint rooms_base_rent_nonnegative check(base_rent>=0); exception when duplicate_object then null; end $$;
do $$ begin alter table public.leases add constraint leases_money_nonnegative check(monthly_rent>=0 and deposit_amount>=0 and deposit_refunded>=0); exception when duplicate_object then null; end $$;

-- Ghi nhận thanh toán trong một transaction, tránh mất dữ liệu khi có hai lần thu đồng thời.
create or replace function public.record_payment(
  p_invoice_id uuid,
  p_amount numeric,
  p_paid_at timestamptz default now(),
  p_method text default 'transfer',
  p_reference text default null,
  p_notes text default null,
  p_idempotency_key text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_invoice public.invoices%rowtype;
  v_payment public.payments%rowtype;
  v_existing public.payments%rowtype;
  v_remaining numeric;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Số tiền thanh toán không hợp lệ';
  end if;
  if p_method not in ('cash','transfer','other') then
    raise exception 'Phương thức thanh toán không hợp lệ';
  end if;
  if p_idempotency_key is not null then
    select * into v_existing from public.payments where idempotency_key=p_idempotency_key limit 1;
    if found then return to_jsonb(v_existing); end if;
  end if;
  select * into v_invoice from public.invoices where id=p_invoice_id for update;
  if not found then raise exception 'Không tìm thấy hóa đơn'; end if;
  if v_invoice.status='cancelled' then raise exception 'Hóa đơn đã bị hủy'; end if;
  v_remaining:=v_invoice.total_amount-v_invoice.paid_amount;
  if p_amount>v_remaining then raise exception 'Số tiền vượt quá công nợ còn lại'; end if;
  insert into public.payments(invoice_id,amount,paid_at,method,reference,notes,idempotency_key)
  values(p_invoice_id,p_amount,coalesce(p_paid_at,now()),p_method,p_reference,p_notes,p_idempotency_key)
  returning * into v_payment;
  update public.invoices
  set paid_amount=paid_amount+p_amount,
      status=case when paid_amount+p_amount>=total_amount then 'paid' else 'partial' end,
      locked_at=coalesce(locked_at,now())
  where id=p_invoice_id;
  return to_jsonb(v_payment);
end $$;
revoke all on function public.record_payment(uuid,numeric,timestamptz,text,text,text,text) from public;
grant execute on function public.record_payment(uuid,numeric,timestamptz,text,text,text,text) to service_role;

-- Tài liệu nhiều ảnh cho khách thuê và hợp đồng. Hai cột legacy *_document_path
-- vẫn được giữ lại để tương thích ngược với dữ liệu và code cũ.
create table if not exists public.document_attachments(
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  entity_type text not null check(entity_type in('tenant','lease')),
  entity_id uuid not null,
  document_type text,
  file_path text not null,
  file_name text,
  mime_type text,
  file_size bigint,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists document_attachments_entity_path_uidx
  on public.document_attachments(entity_type,entity_id,file_path);
create index if not exists document_attachments_property_idx
  on public.document_attachments(property_id);
create index if not exists document_attachments_entity_idx
  on public.document_attachments(entity_type,entity_id);
create index if not exists document_attachments_sort_idx
  on public.document_attachments(sort_order);

create or replace function public.validate_document_attachment_property()
returns trigger language plpgsql as $$
begin
  if new.entity_type='tenant' then
    if not exists(select 1 from public.tenants where id=new.entity_id and property_id=new.property_id) then
      raise exception 'Tài liệu khách thuê không thuộc tòa nhà đã chọn';
    end if;
  elsif new.entity_type='lease' then
    if not exists(select 1 from public.leases where id=new.entity_id and property_id=new.property_id) then
      raise exception 'Tài liệu hợp đồng không thuộc tòa nhà đã chọn';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists validate_document_attachment_property on public.document_attachments;
create trigger validate_document_attachment_property
before insert or update on public.document_attachments
for each row execute function public.validate_document_attachment_property();
drop trigger if exists set_document_attachments_updated_at on public.document_attachments;
create trigger set_document_attachments_updated_at
before update on public.document_attachments
for each row execute function public.set_updated_at();
alter table public.document_attachments enable row level security;

-- Migration idempotent từ hai cột path cũ sang bảng attachment mới.
insert into public.document_attachments(entity_type,entity_id,property_id,document_type,file_path,sort_order)
select 'tenant',t.id,t.property_id,'identity',t.identity_document_path,0
from public.tenants t
where t.identity_document_path is not null and btrim(t.identity_document_path)<>''
  and not exists(
    select 1 from public.document_attachments d
    where d.entity_type='tenant' and d.entity_id=t.id and d.file_path=t.identity_document_path
  );

insert into public.document_attachments(entity_type,entity_id,property_id,document_type,file_path,sort_order)
select 'lease',l.id,l.property_id,'contract',l.contract_document_path,0
from public.leases l
where l.contract_document_path is not null and btrim(l.contract_document_path)<>''
  and not exists(
    select 1 from public.document_attachments d
    where d.entity_type='lease' and d.entity_id=l.id and d.file_path=l.contract_document_path
  );

