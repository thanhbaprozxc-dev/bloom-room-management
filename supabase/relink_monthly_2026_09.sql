-- SAFE RELINK PREVIEW: đối chiếu lại snapshot kỳ 2026-09 với hợp đồng hiện hành.
-- Mặc định chỉ SELECT. Không tự chạy UPDATE và không được ứng dụng tự chạy file này.
-- Đổi NULL trong params.property_id thành UUID tòa nhà nếu muốn giới hạn phạm vi.
-- Quy tắc: không đụng record đã có thanh toán, đã có hóa đơn để xem xét,
-- hoặc kỳ đã khóa; chỉ relink record chưa có hóa đơn và chưa có thanh toán.

with params as (
  select null::uuid as property_id, '2026-09'::text as period
),
active_leases as (
  select distinct on (l.property_id, l.room_id)
    l.id as active_lease_id,
    l.property_id,
    l.room_id,
    l.monthly_rent as active_rent,
    l.service_water_fee as active_service_water_fee
  from public.leases l
  cross join params p
  where l.status not in ('draft', 'terminated')
    and l.start_date <= current_date
    and l.end_date >= current_date
    and (p.property_id is null or l.property_id = p.property_id)
  order by l.property_id, l.room_id, l.start_date desc, l.created_at desc
),
candidate_rows as (
  select
    m.id as monthly_record_id,
    bp.status as period_status,
    p.id as property_id,
    p.name as property_name,
    bp.period,
    r.id as room_id,
    r.room_number,
    m.lease_id as snapshot_lease_id,
    m.rent as snapshot_rent,
    m.service_fee as snapshot_service_water_fee,
    al.active_lease_id,
    al.active_rent,
    al.active_service_water_fee,
    i.id as invoice_id,
    coalesce(pt.payment_total, 0) as payment_total
  from public.monthly_room_records m
  join public.billing_periods bp on bp.id = m.billing_period_id
  join public.properties p on p.id = bp.property_id
  join public.rooms r on r.id = m.room_id and r.property_id = p.id
  left join active_leases al on al.property_id = p.id and al.room_id = r.id
  left join lateral (
    select i.id
    from public.invoices i
    where i.record_id = m.id
      and i.status <> 'cancelled'
    order by i.issued_at desc
    limit 1
  ) i on true
  left join lateral (
    select coalesce(sum(pay.amount), 0)::numeric as payment_total
    from public.payments pay
    where pay.invoice_id = i.id
  ) pt on true
  cross join params prm
  where bp.period = prm.period
    and (prm.property_id is null or bp.property_id = prm.property_id)
)
select
  c.*,
  case
    when c.active_lease_id is null then 'NO_ACTIVE_LEASE'
    when c.payment_total > 0 then 'HAS_PAYMENT_DO_NOT_TOUCH'
    when c.invoice_id is not null then 'HAS_INVOICE_NO_PAYMENT_REVIEW'
    when c.period_status = 'locked' then 'PERIOD_LOCKED_DO_NOT_TOUCH'
    when c.snapshot_lease_id is not distinct from c.active_lease_id
      and c.snapshot_rent is not distinct from c.active_rent
      and c.snapshot_service_water_fee is not distinct from c.active_service_water_fee then 'ALREADY_MATCHED'
    else 'SAFE_TO_RELINK'
  end as relink_result
from candidate_rows c
order by c.property_name, c.room_number;

-- SAU KHI ĐÃ XEM PREVIEW, có thể bỏ comment toàn bộ khối dưới để relink an toàn.
-- Chỉ các dòng SAFE_TO_RELINK được cập nhật; các field điện/nước/phí khác giữ nguyên.
-- with params as (
--   select null::uuid as property_id, '2026-09'::text as period
-- ),
-- active_leases as (
--   select distinct on (l.property_id, l.room_id)
--     l.id as active_lease_id,
--     l.property_id,
--     l.room_id,
--     l.monthly_rent as active_rent,
--     l.service_water_fee as active_service_water_fee
--   from public.leases l
--   cross join params p
--   where l.status not in ('draft', 'terminated')
--     and l.start_date <= current_date
--     and l.end_date >= current_date
--     and (p.property_id is null or l.property_id = p.property_id)
--   order by l.property_id, l.room_id, l.start_date desc, l.created_at desc
-- ),
-- safe_rows as (
--   select m.id as monthly_record_id, al.active_lease_id, al.active_rent, al.active_service_water_fee
--   from public.monthly_room_records m
--   join public.billing_periods bp on bp.id = m.billing_period_id
--   join active_leases al on al.property_id = bp.property_id and al.room_id = m.room_id
--   cross join params prm
--   where bp.period = prm.period
--     and (prm.property_id is null or bp.property_id = prm.property_id)
--     and bp.status <> 'locked'
--     and not exists (
--       select 1 from public.invoices i
--       where i.record_id = m.id and i.status <> 'cancelled'
--     )
-- )
-- update public.monthly_room_records m
-- set lease_id = s.active_lease_id,
--     rent = s.active_rent,
--     service_fee = s.active_service_water_fee,
--     updated_at = now()
-- from safe_rows s
-- where m.id = s.monthly_record_id;

