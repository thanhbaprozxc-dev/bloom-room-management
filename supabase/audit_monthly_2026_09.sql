-- READ-ONLY AUDIT: đối chiếu dữ liệu tháng 2026-09 với hợp đồng hiện hành.
-- File này chỉ SELECT, không INSERT/UPDATE/DELETE và không được ứng dụng tự chạy.
-- Để audit một tòa nhà, thay NULL trong params.property_id bằng UUID tương ứng.

with params as (
  select null::uuid as property_id, '2026-09'::text as period
),
active_leases as (
  select distinct on (l.property_id, l.room_id)
    l.id,
    l.property_id,
    l.room_id,
    l.monthly_rent,
    l.service_water_fee,
    l.start_date,
    l.end_date,
    l.status
  from public.leases l
  cross join params p
  where l.status = 'active'
    and l.start_date <= current_date
    and l.end_date >= current_date
    and (p.property_id is null or l.property_id = p.property_id)
  order by l.property_id, l.room_id, l.start_date desc, l.created_at desc
),
payment_totals as (
  select i.id as invoice_id, coalesce(sum(pay.amount), 0)::numeric as payment_total
  from public.invoices i
  left join public.payments pay on pay.invoice_id = i.id
  group by i.id
)
select
  p.id as property_id,
  p.name as property_name,
  bp.period,
  r.id as room_id,
  r.room_number,
  m.id as monthly_record_id,
  m.lease_id as snapshot_lease_id,
  m.rent as snapshot_rent,
  m.service_fee as snapshot_service_water_fee,
  al.id as active_lease_id,
  al.monthly_rent as active_lease_rent,
  al.service_water_fee as active_lease_service_water_fee,
  i.id as invoice_id,
  i.status as invoice_status,
  coalesce(pt.payment_total, 0) as payment_total,
  case
    when m.id is null then 'NO_MONTHLY_RECORD'
    when al.id is null then 'NO_ACTIVE_LEASE'
    when m.lease_id is distinct from al.id then 'LEASE_ID_MISMATCH'
    when m.rent is distinct from al.monthly_rent
      or m.service_fee is distinct from al.service_water_fee then 'SNAPSHOT_MISMATCH'
    else 'OK'
  end as audit_result
from public.billing_periods bp
join public.properties p on p.id = bp.property_id
join public.rooms r on r.property_id = p.id
left join public.monthly_room_records m
  on m.billing_period_id = bp.id
 and m.room_id = r.id
left join active_leases al
  on al.property_id = p.id
 and al.room_id = r.id
left join lateral (
  select i.id, i.status
  from public.invoices i
  where i.record_id = m.id
    and i.status <> 'cancelled'
  order by i.issued_at desc
  limit 1
) i on true
left join payment_totals pt on pt.invoice_id = i.id
cross join params prm
where bp.period = prm.period
  and (prm.property_id is null or bp.property_id = prm.property_id)
order by p.name, r.room_number;

