-- Unified monthly billing and collection workflow.
-- This migration is additive and safe to run more than once. It keeps all
-- existing invoices/payments and preserves the legacy record_payment RPC.

alter table public.monthly_room_records
  add column if not exists electric_end_entered boolean not null default false;
alter table public.monthly_room_records
  add column if not exists water_end_entered boolean not null default false;

-- Existing rows with a real consumption value are considered already chốt.
update public.monthly_room_records
set electric_end_entered=true
where not electric_end_entered and electric_end>electric_start;
update public.monthly_room_records
set water_end_entered=true
where not water_end_entered and water_end>water_start;

alter table public.invoices
  add column if not exists invoice_type text not null default 'combined';
alter table public.invoices
  add column if not exists parent_invoice_id uuid references public.invoices(id) on delete restrict;
alter table public.invoices add column if not exists coverage_start date;
alter table public.invoices add column if not exists coverage_end date;

do $$ begin
  if not exists (
    select 1 from pg_constraint
    where conname='invoices_invoice_type_check'
      and conrelid='public.invoices'::regclass
  ) then
    alter table public.invoices add constraint invoices_invoice_type_check
      check(invoice_type in('rent_advance','utility','final_settlement','adjustment','combined')) not valid;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='invoices_coverage_range_check' and conrelid='public.invoices'::regclass) then
    alter table public.invoices add constraint invoices_coverage_range_check check(coverage_end is null or coverage_start is null or coverage_end>=coverage_start) not valid;
  end if;
end $$;

-- Older schema versions enforced one invoice per monthly record. Remove only
-- that unique constraint; the invoice rows themselves are never deleted.
do $$
declare
  c record;
  record_attnum smallint;
begin
  select attnum into record_attnum
  from pg_attribute
  where attrelid='public.invoices'::regclass and attname='record_id' and not attisdropped;
  for c in
    select conname
    from pg_constraint
    where conrelid='public.invoices'::regclass
      and contype='u'
      and conkey = array[record_attnum]::smallint[]
  loop
    execute format('alter table public.invoices drop constraint if exists %I',c.conname);
  end loop;
end $$;

create table if not exists public.invoice_items(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  item_type text not null check(item_type in('rent','electricity','water','service_fee','other_fee','previous_debt','discount','adjustment')),
  description text not null,
  amount numeric(14,2) not null default 0,
  quantity numeric(14,3) not null default 1,
  unit_price numeric(14,2),
  metadata jsonb,
  created_at timestamptz not null default now(),
  unique(invoice_id,item_type)
);

create table if not exists public.payment_batches(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  cash_amount numeric(14,2) not null default 0 check(cash_amount>=0),
  transfer_amount numeric(14,2) not null default 0 check(transfer_amount>=0),
  total_amount numeric(14,2) not null check(total_amount>0),
  paid_at timestamptz not null default now(),
  reference text,
  notes text,
  idempotency_key text unique,
  created_at timestamptz not null default now()
);

alter table public.payments add column if not exists batch_id uuid references public.payment_batches(id) on delete set null;
alter table public.payment_batches add column if not exists idempotency_key text;
create unique index if not exists payment_batches_idempotency_uidx on public.payment_batches(idempotency_key) where idempotency_key is not null;
create index if not exists invoice_items_invoice_idx on public.invoice_items(invoice_id);
create index if not exists payment_batches_invoice_idx on public.payment_batches(invoice_id);
create index if not exists payments_batch_idx on public.payments(batch_id);

-- Keep an auditable breakdown for invoices already in the database. This is
-- deliberately insert-only and does not change invoice totals or payments.
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'rent','Tiền phòng',m.rent,1,m.rent,null
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled'
on conflict(invoice_id,item_type) do nothing;
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'electricity','Tiền điện',greatest(0,m.electric_end-m.electric_start)*m.electric_rate,greatest(0,m.electric_end-m.electric_start),m.electric_rate,jsonb_build_object('start',m.electric_start,'end',m.electric_end)
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled' and m.electric_end>=m.electric_start
on conflict(invoice_id,item_type) do nothing;
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'water','Tiền nước',greatest(0,m.water_end-m.water_start)*m.water_rate,greatest(0,m.water_end-m.water_start),m.water_rate,jsonb_build_object('start',m.water_start,'end',m.water_end)
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled' and m.water_end>=m.water_start
on conflict(invoice_id,item_type) do nothing;
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'service_fee','Phí dịch vụ',m.service_fee,1,m.service_fee,null
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled'
on conflict(invoice_id,item_type) do nothing;
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'other_fee','Phí khác',m.other_fee,1,m.other_fee,null
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled'
on conflict(invoice_id,item_type) do nothing;
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'previous_debt','Nợ kỳ trước',m.previous_debt,1,m.previous_debt,null
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled'
on conflict(invoice_id,item_type) do nothing;
insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
select i.id,'discount','Giảm trừ',-m.discount,1,-m.discount,null
from public.invoices i join public.monthly_room_records m on m.id=i.record_id
where i.status<>'cancelled' and m.discount<>0
on conflict(invoice_id,item_type) do nothing;

do $$ declare t text; begin
  foreach t in array array['invoice_items','payment_batches'] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end $$;

drop function if exists public.issue_invoice(uuid,text,uuid,text,text[],date);
create or replace function public.issue_invoice(
  p_property_id uuid,
  p_period text,
  p_room_id uuid,
  p_invoice_type text default 'combined',
  p_item_types text[] default array['rent','electricity','water','service_fee','other_fee','previous_debt','discount'],
  p_due_date date default null,
  p_coverage_start date default null,
  p_coverage_end date default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_period public.billing_periods%rowtype;
  v_record public.monthly_room_records%rowtype;
  v_invoice public.invoices%rowtype;
  v_room_number text;
  v_property_code text;
  v_item text;
  v_amount numeric(14,2);
  v_total numeric(14,2):=0;
  v_id uuid;
  v_number text;
begin
  if p_invoice_type not in('rent_advance','utility','final_settlement','adjustment','combined') then
    raise exception 'Loại hóa đơn không hợp lệ';
  end if;
  if p_item_types is null or cardinality(p_item_types)=0 then
    raise exception 'Hóa đơn phải có ít nhất một khoản thu';
  end if;
  if p_coverage_start is null and 'rent'=any(p_item_types) then
    p_coverage_start:=(p_period||'-01')::date;
    p_coverage_end:=(date_trunc('month',p_coverage_start::timestamp)+interval '1 month - 1 day')::date;
  end if;
  if p_coverage_start is not null or p_coverage_end is not null then
    if p_coverage_start is null or p_coverage_end is null or p_coverage_end<p_coverage_start then raise exception 'Khoảng thời gian tiền phòng trả trước không hợp lệ'; end if;
  end if;
  select * into v_period from public.billing_periods where property_id=p_property_id and period=p_period for update;
  if not found then raise exception 'Chưa có kỳ thu tương ứng'; end if;
  select * into v_record from public.monthly_room_records where billing_period_id=v_period.id and property_id=p_property_id and room_id=p_room_id for update;
  if not found then raise exception 'Phòng chưa có dữ liệu tháng'; end if;
  if p_invoice_type='utility' and not ('rent'=any(p_item_types)) and exists(select 1 from public.leases where id=v_record.lease_id and to_char(end_date,'YYYY-MM')=p_period) then p_invoice_type:='final_settlement'; end if;
  select room_number into v_room_number from public.rooms where id=p_room_id and property_id=p_property_id;
  select property_code into v_property_code from public.properties where id=p_property_id;
  if v_room_number is null or v_property_code is null then raise exception 'Không tìm thấy phòng hoặc tòa nhà'; end if;
  if 'rent'=any(p_item_types) and p_coverage_start is not null and exists(select 1 from public.invoices where record_id=v_record.id and invoice_type in('rent_advance','combined') and status<>'cancelled' and paid_amount>0 and coverage_start is not null and coverage_end is not null and daterange(coverage_start,coverage_end,'[]') && daterange(p_coverage_start,p_coverage_end,'[]')) then
    raise exception 'Khoảng tiền phòng trả trước bị trùng với hóa đơn đã thanh toán';
  end if;

  foreach v_item in array p_item_types loop
    if v_item not in('rent','electricity','water','service_fee','other_fee','previous_debt','discount','adjustment') then
      raise exception 'Khoản thu không hợp lệ: %',v_item;
    end if;
    if v_item='electricity' then
      if not v_record.electric_end_entered then raise exception 'Chưa chốt chỉ số điện cuối kỳ'; end if;
      v_amount:=greatest(0,v_record.electric_end-v_record.electric_start)*v_record.electric_rate;
    elsif v_item='water' then
      if not v_record.water_end_entered then raise exception 'Chưa chốt chỉ số nước cuối kỳ'; end if;
      v_amount:=greatest(0,v_record.water_end-v_record.water_start)*v_record.water_rate;
    elsif v_item='rent' then v_amount:=v_record.rent;
    elsif v_item='service_fee' then v_amount:=v_record.service_fee;
    elsif v_item='other_fee' then v_amount:=v_record.other_fee;
    elsif v_item='previous_debt' then v_amount:=v_record.previous_debt;
    elsif v_item='discount' then v_amount:=-v_record.discount;
    else v_amount:=0;
    end if;
    v_total:=v_total+coalesce(v_amount,0);
  end loop;
  v_total:=greatest(0,v_total);
  if v_total<=0 then raise exception 'Tổng hóa đơn phải lớn hơn 0'; end if;

  select * into v_invoice from public.invoices
  where record_id=v_record.id and invoice_type=p_invoice_type and status<>'cancelled'
  order by issued_at desc limit 1 for update;
  if found and v_invoice.paid_amount>0 then v_invoice:=null; end if;
  if v_invoice.id is null then
    v_number:=coalesce(v_property_code,'BLM')||'-'||replace(p_period,'-','')||'-'||v_room_number||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    insert into public.invoices(record_id,property_id,invoice_number,invoice_type,due_date,coverage_start,coverage_end,total_amount,paid_amount,status,locked_at)
    values(v_record.id,p_property_id,v_number,p_invoice_type,p_due_date,p_coverage_start,p_coverage_end,v_total,0,'unpaid',null)
    returning * into v_invoice;
  else
    update public.invoices set invoice_type=p_invoice_type,due_date=coalesce(p_due_date,due_date),coverage_start=coalesce(p_coverage_start,coverage_start),coverage_end=coalesce(p_coverage_end,coverage_end),total_amount=v_total,status='unpaid',locked_at=null,updated_at=now()
    where id=v_invoice.id returning * into v_invoice;
    delete from public.invoice_items where invoice_id=v_invoice.id;
  end if;

  foreach v_item in array p_item_types loop
    if v_item='electricity' then v_amount:=greatest(0,v_record.electric_end-v_record.electric_start)*v_record.electric_rate;
    elsif v_item='water' then v_amount:=greatest(0,v_record.water_end-v_record.water_start)*v_record.water_rate;
    elsif v_item='rent' then v_amount:=v_record.rent;
    elsif v_item='service_fee' then v_amount:=v_record.service_fee;
    elsif v_item='other_fee' then v_amount:=v_record.other_fee;
    elsif v_item='previous_debt' then v_amount:=v_record.previous_debt;
    elsif v_item='discount' then v_amount:=-v_record.discount;
    else v_amount:=0;
    end if;
    insert into public.invoice_items(invoice_id,item_type,description,amount,quantity,unit_price,metadata)
    values(v_invoice.id,v_item,case v_item when 'rent' then 'Tiền phòng' when 'electricity' then 'Tiền điện' when 'water' then 'Tiền nước' when 'service_fee' then 'Phí dịch vụ' when 'other_fee' then 'Phí khác' when 'previous_debt' then 'Nợ kỳ trước' when 'discount' then 'Giảm trừ' else 'Điều chỉnh' end,v_amount,1,case when v_item='electricity' then v_record.electric_rate when v_item='water' then v_record.water_rate else v_amount end,case when v_item in('electricity','water') then jsonb_build_object('start',case when v_item='electricity' then v_record.electric_start else v_record.water_start end,'end',case when v_item='electricity' then v_record.electric_end else v_record.water_end end) else null end);
  end loop;
  return jsonb_build_object('invoice_id',v_invoice.id,'record_id',v_record.id,'invoice_type',v_invoice.invoice_type,'total_amount',v_invoice.total_amount,'status',v_invoice.status);
end $$;
revoke all on function public.issue_invoice(uuid,text,uuid,text,text[],date,date,date) from public;
grant execute on function public.issue_invoice(uuid,text,uuid,text,text[],date,date,date) to service_role;

create or replace function public.record_payment_batch(
  p_invoice_id uuid,
  p_cash_amount numeric default 0,
  p_transfer_amount numeric default 0,
  p_paid_at timestamptz default now(),
  p_reference text default null,
  p_notes text default null,
  p_idempotency_key text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_invoice public.invoices%rowtype;
  v_batch public.payment_batches%rowtype;
  v_total numeric(14,2):=round((coalesce(p_cash_amount,0)+coalesce(p_transfer_amount,0))::numeric,2);
  v_remaining numeric(14,2);
  v_paid numeric(14,2);
begin
  if coalesce(p_cash_amount,0)<0 or coalesce(p_transfer_amount,0)<0 then raise exception 'Số tiền thu không được âm'; end if;
  if v_total<=0 then raise exception 'Tổng số tiền thu phải lớn hơn 0'; end if;
  if p_idempotency_key is not null then
    select * into v_batch from public.payment_batches where idempotency_key=p_idempotency_key limit 1;
    if found then
      select * into v_invoice from public.invoices where id=v_batch.invoice_id;
      return jsonb_build_object('batch_id',v_batch.id,'invoice_id',v_batch.invoice_id,'cash_amount',v_batch.cash_amount,'transfer_amount',v_batch.transfer_amount,'total_amount',v_batch.total_amount,'paid_amount',v_invoice.paid_amount,'remaining',greatest(0,v_invoice.total_amount-v_invoice.paid_amount),'status',v_invoice.status,'idempotent',true);
    end if;
  end if;
  select * into v_invoice from public.invoices where id=p_invoice_id for update;
  if not found then raise exception 'Không tìm thấy hóa đơn'; end if;
  if v_invoice.status='cancelled' then raise exception 'Hóa đơn đã bị hủy'; end if;
  v_remaining:=greatest(0,v_invoice.total_amount-v_invoice.paid_amount);
  if v_total>v_remaining then raise exception 'Số tiền vượt quá công nợ còn lại'; end if;
  insert into public.payment_batches(invoice_id,cash_amount,transfer_amount,total_amount,paid_at,reference,notes,idempotency_key)
  values(p_invoice_id,coalesce(p_cash_amount,0),coalesce(p_transfer_amount,0),v_total,coalesce(p_paid_at,now()),p_reference,p_notes,p_idempotency_key)
  returning * into v_batch;
  if coalesce(p_cash_amount,0)>0 then insert into public.payments(invoice_id,batch_id,amount,paid_at,method,reference,notes) values(p_invoice_id,v_batch.id,p_cash_amount,coalesce(p_paid_at,now()),'cash',p_reference,p_notes); end if;
  if coalesce(p_transfer_amount,0)>0 then insert into public.payments(invoice_id,batch_id,amount,paid_at,method,reference,notes) values(p_invoice_id,v_batch.id,p_transfer_amount,coalesce(p_paid_at,now()),'transfer',p_reference,p_notes); end if;
  v_paid:=v_invoice.paid_amount+v_total;
  update public.invoices set paid_amount=v_paid,status=case when v_paid>=total_amount then 'paid' else 'partial' end,locked_at=coalesce(locked_at,now()),updated_at=now() where id=p_invoice_id;
  return jsonb_build_object('batch_id',v_batch.id,'invoice_id',p_invoice_id,'cash_amount',v_batch.cash_amount,'transfer_amount',v_batch.transfer_amount,'total_amount',v_total,'paid_amount',v_paid,'remaining',greatest(0,v_invoice.total_amount-v_paid),'status',case when v_paid>=v_invoice.total_amount then 'paid' else 'partial' end,'idempotent',false);
end $$;
revoke all on function public.record_payment_batch(uuid,numeric,numeric,timestamptz,text,text,text) from public;
grant execute on function public.record_payment_batch(uuid,numeric,numeric,timestamptz,text,text,text) to service_role;
