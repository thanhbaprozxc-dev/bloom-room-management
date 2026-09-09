-- SAFE RELINK PREVIEW: đối chiếu lại snapshot kỳ 2026-09 với hợp đồng hiện hành.
-- Mặc định chỉ SELECT. Không tự chạy UPDATE và không được ứng dụng tự chạy file này.
-- Đổi NULL trong params.property_id thành UUID tòa nhà nếu muốn giới hạn phạm vi.
-- Quy tắc: không đụng record đã có thanh toán hoặc đã khóa theo từng hóa đơn.
-- Trạng thái khóa toàn kỳ cũ không còn dùng để khóa các phòng chưa thu tiền.

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
    i.status as invoice_status,
    i.paid_amount as invoice_paid_amount,
    i.locked_at as invoice_locked_at,
    coalesce(pt.payment_total, 0) as payment_total
  from public.monthly_room_records m
  join public.billing_periods bp on bp.id = m.billing_period_id
  join public.properties p on p.id = bp.property_id
  join public.rooms r on r.id = m.room_id and r.property_id = p.id
  left join active_leases al on al.property_id = p.id and al.room_id = r.id
  left join lateral (
    select i.id, i.status, i.paid_amount, i.locked_at
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
    when greatest(c.payment_total, coalesce(c.invoice_paid_amount, 0)) > 0
      or c.invoice_status in ('partial', 'paid') then 'HAS_PAYMENT_DO_NOT_TOUCH'
    when c.invoice_locked_at is not null then 'ROOM_LOCKED_DO_NOT_TOUCH'
    when c.invoice_id is not null
      and c.invoice_status not in ('partial', 'paid')
      and coalesce(c.invoice_paid_amount, 0) = 0
      and c.payment_total = 0 then 'SAFE_TO_RELINK_AND_SYNC_INVOICE'
    when c.invoice_id is not null then 'HAS_INVOICE_NO_PAYMENT_REVIEW'
    when c.snapshot_lease_id is not distinct from c.active_lease_id
      and c.snapshot_rent is not distinct from c.active_rent
      and c.snapshot_service_water_fee is not distinct from c.active_service_water_fee then 'ALREADY_MATCHED'
    else 'SAFE_TO_RELINK'
  end as relink_result
from candidate_rows c
order by c.property_name, c.room_number;

-- SAU KHI ĐÃ XEM PREVIEW, có thể bỏ comment toàn bộ khối dưới để relink an toàn.
-- Khối này xử lý cả record chưa có hóa đơn và hóa đơn chưa thu.
-- Với hóa đơn chưa thu, invoice.total_amount được đồng bộ trong cùng giao dịch.
-- Tuyệt đối không cập nhật record đã thanh toán hoặc hóa đơn đã khóa theo phòng.
-- begin;
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
-- eligible_rows as (
--   select
--     m.id as monthly_record_id,
--     al.active_lease_id,
--     al.active_rent,
--     al.active_service_water_fee,
--     i.id as invoice_id,
--     i.status as invoice_status,
--     i.paid_amount as invoice_paid_amount,
--     i.locked_at as invoice_locked_at,
--     coalesce(pt.payment_total, 0) as payment_total
--   from public.monthly_room_records m
--   join public.billing_periods bp on bp.id = m.billing_period_id
--   join active_leases al on al.property_id = bp.property_id and al.room_id = m.room_id
--   left join lateral (
--     select i.id, i.status, i.paid_amount, i.locked_at
--     from public.invoices i
--     where i.record_id = m.id and i.status <> 'cancelled'
--     order by i.issued_at desc
--     limit 1
--   ) i on true
--   left join lateral (
--     select coalesce(sum(pay.amount), 0)::numeric as payment_total
--     from public.payments pay
--     where pay.invoice_id = i.id
--   ) pt on true
--   cross join params prm
--   where bp.period = prm.period
--     and (prm.property_id is null or bp.property_id = prm.property_id)
--     and (
--       i.id is null
--       or (
--         i.status not in ('partial', 'paid')
--         and i.locked_at is null
--         and coalesce(i.paid_amount, 0) = 0
--         and coalesce(pt.payment_total, 0) = 0
--       )
--     )
-- ),
-- updated_records as (
--   update public.monthly_room_records m
--   set lease_id = e.active_lease_id,
--       rent = e.active_rent,
--       service_fee = e.active_service_water_fee,
--       updated_at = now()
--   from eligible_rows e
--   where m.id = e.monthly_record_id
--   returning m.id, m.rent, m.electric_start, m.electric_end, m.electric_rate,
--             m.water_start, m.water_end, m.water_rate, m.service_fee,
--             m.other_fee, m.previous_debt, m.discount
-- )
-- update public.invoices i
-- set total_amount = greatest(
--       0,
--       u.rent
--       + (u.electric_end - u.electric_start) * u.electric_rate
--       + (u.water_end - u.water_start) * u.water_rate
--       + u.service_fee
--       + u.other_fee
--       + u.previous_debt
--       - u.discount
--     ),
--     updated_at = now()
-- from updated_records u
-- where i.record_id = u.id
--   and i.status not in ('cancelled', 'partial', 'paid')
--   and i.locked_at is null
--   and coalesce(i.paid_amount, 0) = 0
--   and not exists (
--     select 1 from public.payments p where p.invoice_id = i.id
--   );
-- commit;

