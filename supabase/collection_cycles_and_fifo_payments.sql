-- Contract-anchored collection cycles and FIFO payment allocation.
-- Additive migration: legacy monthly records, invoices and payments are kept.

alter table public.leases
  add column if not exists initial_electricity_reading numeric(12,2);

alter table public.monthly_room_records
  add column if not exists tenant_id uuid references public.tenants(id),
  add column if not exists period_start date,
  add column if not exists period_end date,
  add column if not exists due_date date,
  add column if not exists cycle_number integer,
  add column if not exists electric_start_confirmed boolean not null default false;

-- Existing records are intentionally not assigned a guessed meter baseline or
-- contract cycle. They continue to work through the legacy calendar-month path.
update public.monthly_room_records m
set tenant_id=l.representative_tenant_id
from public.leases l
where m.lease_id=l.id and m.tenant_id is null;

alter table public.payment_batches
  add column if not exists property_id uuid references public.properties(id) on delete restrict,
  add column if not exists lease_id uuid references public.leases(id) on delete restrict,
  add column if not exists excess_amount numeric(14,2) not null default 0,
  add column if not exists updated_at timestamptz not null default now();

update public.payment_batches b
set property_id=i.property_id,
    lease_id=m.lease_id
from public.invoices i
join public.monthly_room_records m on m.id=i.record_id
where b.invoice_id=i.id and (b.property_id is null or b.lease_id is null);

create table if not exists public.payment_allocations(
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  allocated_amount numeric(14,2) not null check(allocated_amount>0),
  created_at timestamptz not null default now(),
  unique(payment_id,invoice_id)
);

create table if not exists public.customer_credits(
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  lease_id uuid references public.leases(id) on delete restrict,
  payment_batch_id uuid not null unique references public.payment_batches(id) on delete restrict,
  amount numeric(14,2) not null check(amount>0),
  remaining_amount numeric(14,2) not null check(remaining_amount>=0 and remaining_amount<=amount),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists monthly_records_cycle_idx
  on public.monthly_room_records(property_id,lease_id,period_start,period_end);
create index if not exists payment_batches_lease_idx
  on public.payment_batches(lease_id,created_at);
create index if not exists payment_allocations_invoice_idx
  on public.payment_allocations(invoice_id);
create index if not exists payment_allocations_payment_idx
  on public.payment_allocations(payment_id);
create index if not exists customer_credits_lease_idx
  on public.customer_credits(lease_id,created_at);

do $$ begin
  if not exists(select 1 from pg_constraint where conname='leases_initial_electricity_nonnegative' and conrelid='public.leases'::regclass) then
    alter table public.leases add constraint leases_initial_electricity_nonnegative
      check(initial_electricity_reading is null or initial_electricity_reading>=0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='monthly_records_cycle_range_check' and conrelid='public.monthly_room_records'::regclass) then
    alter table public.monthly_room_records add constraint monthly_records_cycle_range_check
      check(period_end is null or period_start is null or period_end>=period_start) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='monthly_records_cycle_number_check' and conrelid='public.monthly_room_records'::regclass) then
    alter table public.monthly_room_records add constraint monthly_records_cycle_number_check
      check(cycle_number is null or cycle_number>=1) not valid;
  end if;
end $$;

do $$ declare t text; begin
  foreach t in array array['payment_batches','payment_allocations','customer_credits'] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end $$;

-- The invoice RPC remains the single server-side source of truth for the
-- current-cycle rules. Legacy rows (cycle_number is null) retain old behavior.
drop function if exists public.issue_invoice(uuid,text,uuid,text,text[],date,date,date);
create or replace function public.issue_invoice(
  p_property_id uuid,
  p_period text,
  p_room_id uuid,
  p_invoice_type text default 'combined',
  p_item_types text[] default array['rent','electricity','water','service_fee','previous_debt','discount'],
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
  v_number text;
begin
  if p_invoice_type not in('rent_advance','utility','final_settlement','adjustment','combined') then
    raise exception 'Loại hóa đơn không hợp lệ';
  end if;
  if p_item_types is null or cardinality(p_item_types)=0 then
    raise exception 'Hóa đơn phải có ít nhất một khoản thu';
  end if;
  select * into v_period from public.billing_periods
  where property_id=p_property_id and period=p_period for update;
  if not found then raise exception 'Chưa có kỳ thu tương ứng'; end if;
  select * into v_record from public.monthly_room_records
  where billing_period_id=v_period.id and property_id=p_property_id and room_id=p_room_id for update;
  if not found then raise exception 'Phòng chưa có dữ liệu tháng'; end if;
  if v_record.cycle_number is not null and 'previous_debt'=any(p_item_types) then
    raise exception 'Nợ kỳ trước đã được giữ ở hóa đơn cũ và sẽ được phân bổ FIFO';
  end if;
  if v_record.cycle_number=1 and 'electricity'=any(p_item_types) then
    raise exception 'Kỳ đầu tiên chưa được tính tiền điện';
  end if;
  if 'electricity'=any(p_item_types) then
    if not v_record.electric_start_confirmed then raise exception 'Chưa xác nhận số điện đầu kỳ'; end if;
    if not v_record.electric_end_entered then raise exception 'Chưa chốt chỉ số điện cuối kỳ'; end if;
  end if;
  if 'water'=any(p_item_types) and not v_record.water_end_entered then
    raise exception 'Chưa chốt chỉ số nước cuối kỳ';
  end if;
  if p_coverage_start is null and 'rent'=any(p_item_types) then
    p_coverage_start:=coalesce(v_record.period_start,(p_period||'-01')::date);
    p_coverage_end:=coalesce(v_record.period_end,(date_trunc('month',p_coverage_start::timestamp)+interval '1 month - 1 day')::date);
  end if;
  if p_coverage_start is not null or p_coverage_end is not null then
    if p_coverage_start is null or p_coverage_end is null or p_coverage_end<p_coverage_start then
      raise exception 'Khoảng thời gian tiền phòng trả trước không hợp lệ';
    end if;
  end if;
  select room_number into v_room_number from public.rooms where id=p_room_id and property_id=p_property_id;
  select property_code into v_property_code from public.properties where id=p_property_id;
  if v_room_number is null or v_property_code is null then raise exception 'Không tìm thấy phòng hoặc tòa nhà'; end if;
  if 'rent'=any(p_item_types) and p_coverage_start is not null and exists(
    select 1 from public.invoices where record_id=v_record.id and invoice_type in('rent_advance','combined')
      and status<>'cancelled' and paid_amount>0 and coverage_start is not null and coverage_end is not null
      and daterange(coverage_start,coverage_end,'[]') && daterange(p_coverage_start,p_coverage_end,'[]')
  ) then raise exception 'Khoảng tiền phòng trả trước bị trùng với hóa đơn đã thanh toán'; end if;
  foreach v_item in array p_item_types loop
    if v_item not in('rent','electricity','water','service_fee','other_fee','previous_debt','discount','adjustment') then
      raise exception 'Khoản thu không hợp lệ: %',v_item;
    end if;
    if v_item='electricity' then v_amount:=greatest(0,v_record.electric_end-v_record.electric_start)*v_record.electric_rate;
    elsif v_item='water' then v_amount:=greatest(0,v_record.water_end-v_record.water_start)*v_record.water_rate;
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
  select * into v_invoice from public.invoices where record_id=v_record.id and invoice_type=p_invoice_type
    and status<>'cancelled' order by issued_at desc limit 1 for update;
  if found and v_invoice.paid_amount>0 then v_invoice:=null; end if;
  if v_invoice.id is null then
    v_number:=coalesce(v_property_code,'BLM')||'-'||replace(p_period,'-','')||'-'||v_room_number||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    insert into public.invoices(record_id,property_id,invoice_number,invoice_type,due_date,coverage_start,coverage_end,total_amount,paid_amount,status,locked_at)
    values(v_record.id,p_property_id,v_number,p_invoice_type,coalesce(p_due_date,v_record.due_date),p_coverage_start,p_coverage_end,v_total,0,'unpaid',null)
    returning * into v_invoice;
  else
    update public.invoices set invoice_type=p_invoice_type,due_date=coalesce(p_due_date,due_date,v_record.due_date),coverage_start=coalesce(p_coverage_start,coverage_start),coverage_end=coalesce(p_coverage_end,coverage_end),total_amount=v_total,status='unpaid',locked_at=null,updated_at=now()
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

-- One request can contain cash and transfer. Allocations are made oldest due
-- invoice first; any remainder becomes a customer credit instead of negative debt.
drop function if exists public.record_payment_batch(uuid,numeric,numeric,timestamptz,text,text,text);
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
  v_anchor public.invoices%rowtype;
  v_target public.invoices%rowtype;
  v_credit public.customer_credits%rowtype;
  v_batch public.payment_batches%rowtype;
  v_payment_id uuid;
  v_lease_id uuid;
  v_property_id uuid;
  v_cash_left numeric(14,2):=round(coalesce(p_cash_amount,0)::numeric,2);
  v_transfer_left numeric(14,2):=round(coalesce(p_transfer_amount,0)::numeric,2);
  v_total numeric(14,2):=round((coalesce(p_cash_amount,0)+coalesce(p_transfer_amount,0))::numeric,2);
  v_remaining numeric(14,2);
  v_allocated numeric(14,2):=0;
  v_alloc numeric(14,2);
  v_cash_alloc numeric(14,2);
  v_transfer_alloc numeric(14,2);
  v_credit_used numeric(14,2);
  v_credit_applied numeric(14,2):=0;
  v_final_remaining numeric(14,2):=0;
begin
  if v_cash_left<0 or v_transfer_left<0 then raise exception 'Số tiền thu không được âm'; end if;
  if v_total<=0 then raise exception 'Tổng số tiền thu phải lớn hơn 0'; end if;
  if p_idempotency_key is not null then
    select * into v_batch from public.payment_batches where idempotency_key=p_idempotency_key limit 1;
    if found then
      select * into v_anchor from public.invoices where id=v_batch.invoice_id;
      return jsonb_build_object('batch_id',v_batch.id,'invoice_id',v_batch.invoice_id,'cash_amount',v_batch.cash_amount,'transfer_amount',v_batch.transfer_amount,'total_amount',v_batch.total_amount,'allocated_amount',v_batch.total_amount-v_batch.excess_amount,'excess_amount',v_batch.excess_amount,'paid_amount',v_anchor.paid_amount,'remaining',greatest(0,v_anchor.total_amount-v_anchor.paid_amount),'status',v_anchor.status,'idempotent',true);
    end if;
  end if;
  select * into v_anchor from public.invoices where id=p_invoice_id for update;
  if not found then raise exception 'Không tìm thấy hóa đơn'; end if;
  if v_anchor.status='cancelled' then raise exception 'Hóa đơn đã bị hủy'; end if;
  select m.lease_id,i.property_id into v_lease_id,v_property_id
  from public.invoices i join public.monthly_room_records m on m.id=i.record_id where i.id=p_invoice_id;
  insert into public.payment_batches(invoice_id,property_id,lease_id,cash_amount,transfer_amount,total_amount,excess_amount,paid_at,reference,notes,idempotency_key)
  values(p_invoice_id,v_property_id,v_lease_id,v_cash_left,v_transfer_left,v_total,0,coalesce(p_paid_at,now()),p_reference,p_notes,p_idempotency_key)
  returning * into v_batch;
  -- Consume an existing customer credit before taking new money. The credit is
  -- represented as a payment in this batch so the target invoice history stays
  -- auditable and the original overpayment remains linked to its source batch.
  for v_credit in
    select * from public.customer_credits
    where lease_id=v_lease_id and remaining_amount>0
    order by created_at,id
    for update
  loop
    v_credit_used:=0;
    for v_target in
      select i.*
      from public.invoices i
      join public.monthly_room_records m on m.id=i.record_id
      where i.status<>'cancelled'
        and i.paid_amount<i.total_amount
        and ((v_lease_id is not null and m.lease_id=v_lease_id) or (v_lease_id is null and i.id=p_invoice_id))
      order by coalesce(i.due_date,m.due_date,i.coverage_start,m.period_start,i.issued_at::date),i.issued_at,i.created_at,i.id
      for update
    loop
      v_remaining:=greatest(0,coalesce(v_target.total_amount,0)-coalesce(v_target.paid_amount,0));
      v_alloc:=least(v_remaining,v_credit.remaining_amount-v_credit_used);
      if v_alloc<=0 then exit; end if;
      insert into public.payments(invoice_id,batch_id,amount,paid_at,method,reference,notes)
      values(v_target.id,v_batch.id,v_alloc,coalesce(p_paid_at,now()),'other',p_reference,coalesce(p_notes,'Tự động phân bổ số dư khách hàng')) returning id into v_payment_id;
      insert into public.payment_allocations(payment_id,invoice_id,allocated_amount) values(v_payment_id,v_target.id,v_alloc);
      v_credit_used:=v_credit_used+v_alloc;
      v_credit_applied:=v_credit_applied+v_alloc;
      update public.invoices set paid_amount=paid_amount+v_alloc,status=case when paid_amount+v_alloc>=total_amount then 'paid' else 'partial' end,locked_at=coalesce(locked_at,now()),updated_at=now() where id=v_target.id;
    end loop;
    if v_credit_used>0 then
      update public.customer_credits set remaining_amount=remaining_amount-v_credit_used,updated_at=now() where id=v_credit.id;
    end if;
  end loop;
  for v_target in
    select i.*
    from public.invoices i
    join public.monthly_room_records m on m.id=i.record_id
    where i.status<>'cancelled'
      and i.paid_amount<i.total_amount
      and ((v_lease_id is not null and m.lease_id=v_lease_id) or (v_lease_id is null and i.id=p_invoice_id))
    order by coalesce(i.due_date,m.due_date,i.coverage_start,m.period_start,i.issued_at::date),i.issued_at,i.created_at,i.id
    for update
  loop
    v_remaining:=greatest(0,coalesce(v_target.total_amount,0)-coalesce(v_target.paid_amount,0));
    if v_remaining<=0 then continue; end if;
    v_alloc:=least(v_remaining,v_cash_left+v_transfer_left);
    if v_alloc<=0 then exit; end if;
    v_cash_alloc:=least(v_cash_left,v_alloc);
    v_transfer_alloc:=least(v_transfer_left,v_alloc-v_cash_alloc);
    if v_cash_alloc>0 then
      insert into public.payments(invoice_id,batch_id,amount,paid_at,method,reference,notes)
      values(v_target.id,v_batch.id,v_cash_alloc,coalesce(p_paid_at,now()),'cash',p_reference,p_notes) returning id into v_payment_id;
      insert into public.payment_allocations(payment_id,invoice_id,allocated_amount) values(v_payment_id,v_target.id,v_cash_alloc);
    end if;
    if v_transfer_alloc>0 then
      insert into public.payments(invoice_id,batch_id,amount,paid_at,method,reference,notes)
      values(v_target.id,v_batch.id,v_transfer_alloc,coalesce(p_paid_at,now()),'transfer',p_reference,p_notes) returning id into v_payment_id;
      insert into public.payment_allocations(payment_id,invoice_id,allocated_amount) values(v_payment_id,v_target.id,v_transfer_alloc);
    end if;
    v_cash_left:=v_cash_left-v_cash_alloc;
    v_transfer_left:=v_transfer_left-v_transfer_alloc;
    v_allocated:=v_allocated+v_alloc;
    update public.invoices set paid_amount=paid_amount+v_alloc,status=case when paid_amount+v_alloc>=total_amount then 'paid' else 'partial' end,locked_at=coalesce(locked_at,now()),updated_at=now() where id=v_target.id;
  end loop;
  v_final_remaining:=greatest(0,v_cash_left+v_transfer_left);
  update public.payment_batches set excess_amount=v_final_remaining,updated_at=now() where id=v_batch.id;
  if v_final_remaining>0 then
    insert into public.customer_credits(property_id,lease_id,payment_batch_id,amount,remaining_amount,notes)
    values(v_property_id,v_lease_id,v_batch.id,v_final_remaining,v_final_remaining,p_notes);
  end if;
  select coalesce(sum(greatest(0,i.total_amount-i.paid_amount)),0) into v_remaining
  from public.invoices i join public.monthly_room_records m on m.id=i.record_id
  where i.status<>'cancelled' and i.paid_amount<i.total_amount
    and ((v_lease_id is not null and m.lease_id=v_lease_id) or (v_lease_id is null and i.id=p_invoice_id));
  select * into v_anchor from public.invoices where id=p_invoice_id;
  return jsonb_build_object('batch_id',v_batch.id,'invoice_id',p_invoice_id,'cash_amount',v_batch.cash_amount,'transfer_amount',v_batch.transfer_amount,'total_amount',v_total,'allocated_amount',v_allocated,'credit_applied',v_credit_applied,'excess_amount',v_final_remaining,'paid_amount',v_anchor.paid_amount,'remaining',v_remaining,'status',v_anchor.status,'idempotent',false);
end $$;
revoke all on function public.record_payment_batch(uuid,numeric,numeric,timestamptz,text,text,text) from public;
grant execute on function public.record_payment_batch(uuid,numeric,numeric,timestamptz,text,text,text) to service_role;
