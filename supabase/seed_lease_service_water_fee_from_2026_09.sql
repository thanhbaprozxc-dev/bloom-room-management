-- OPTIONAL SEED: chỉ dùng sau khi đã xác nhận service_fee của kỳ 2026-09
-- chính là phí dịch vụ + nước cố định theo hợp đồng.
-- Mặc định file này chỉ xem trước dữ liệu; không tự ghi vào database.
-- Không dùng để seed lại các hợp đồng đã có service_water_fee khác 0.

with params as (
  select null::uuid as property_id, '2026-09'::text as period
),
active_leases as (
  select distinct on (l.property_id, l.room_id)
    l.id as lease_id,
    l.property_id,
    l.room_id,
    l.service_water_fee as current_service_water_fee,
    m.service_fee as legacy_service_fee
  from public.leases l
  join public.rooms r on r.id = l.room_id and r.property_id = l.property_id
  join public.billing_periods bp on bp.property_id = l.property_id
  join public.monthly_room_records m
    on m.billing_period_id = bp.id
   and m.room_id = l.room_id
  cross join params p
  where bp.period = p.period
    and l.status = 'active'
    and l.start_date <= current_date
    and l.end_date >= current_date
    and l.service_water_fee = 0
    and m.service_fee >= 0
    and (p.property_id is null or l.property_id = p.property_id)
  order by l.property_id, l.room_id, l.start_date desc, l.created_at desc
)
select *
from active_leases
where legacy_service_fee > 0
order by property_id, room_id;

-- SAU KHI ĐÃ KIỂM TRA KẾT QUẢ SELECT Ở TRÊN, có thể bỏ comment khối dưới
-- để seed một lần. Khối này chỉ cập nhật hợp đồng hiện hành đang có phí = 0.
-- with params as (
--   select null::uuid as property_id, '2026-09'::text as period
-- ),
-- source_rows as (
--   select distinct on (l.property_id, l.room_id)
--     l.id as lease_id,
--     m.service_fee as service_water_fee
--   from public.leases l
--   join public.billing_periods bp on bp.property_id = l.property_id
--   join public.monthly_room_records m
--     on m.billing_period_id = bp.id and m.room_id = l.room_id
--   cross join params p
--   where bp.period = p.period
--     and l.status = 'active'
--     and l.start_date <= current_date
--     and l.end_date >= current_date
--     and l.service_water_fee = 0
--     and m.service_fee >= 0
--     and (p.property_id is null or l.property_id = p.property_id)
--   order by l.property_id, l.room_id, l.start_date desc, l.created_at desc
-- )
-- update public.leases l
-- set service_water_fee = s.service_water_fee,
--     updated_at = now()
-- from source_rows s
-- where l.id = s.lease_id
--   and s.service_water_fee > 0;

