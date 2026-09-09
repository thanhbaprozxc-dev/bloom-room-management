-- CẬP NHẬT NỢ TRƯỚC: kỳ 2026-08 -> 2026-09.
-- Mặc định chỉ SELECT để xem trước, không tự sửa dữ liệu.
-- Đổi NULL trong params.property_id thành UUID tòa nhà nếu cần giới hạn phạm vi.
-- Công nợ được tính từ phần còn lại của hóa đơn tháng 8:
-- total_amount - số tiền đã thu, không lấy trực tiếp snapshot cũ để tránh cộng sai.

with params as (
  select null::uuid as property_id,
         '2026-08'::text as source_period,
         '2026-09'::text as target_period
),
source_invoice_debt as (
  select
    m.property_id,
    m.room_id,
    greatest(
      0,
      i.total_amount
      - greatest(coalesce(i.paid_amount, 0), coalesce(pt.payment_total, 0))
    ) as remaining_debt
  from public.monthly_room_records m
  join public.billing_periods bp on bp.id = m.billing_period_id
  join public.invoices i on i.record_id = m.id and i.status <> 'cancelled'
  left join lateral (
    select coalesce(sum(p.amount), 0)::numeric as payment_total
    from public.payments p
    where p.invoice_id = i.id
  ) pt on true
  cross join params prm
  where bp.period = prm.source_period
    and (prm.property_id is null or m.property_id = prm.property_id)
),
source_debt_by_room as (
  select property_id, room_id, sum(remaining_debt)::numeric as source_debt
  from source_invoice_debt
  group by property_id, room_id
),
target_rows as (
  select
    m.id as monthly_record_id,
    m.property_id,
    m.room_id,
    m.previous_debt as current_previous_debt,
    coalesce(sd.source_debt, 0)::numeric as source_debt,
    i.id as invoice_id,
    i.status as invoice_status,
    i.paid_amount as invoice_paid_amount,
    i.locked_at as invoice_locked_at,
    greatest(coalesce(i.paid_amount, 0), coalesce(pt.payment_total, 0)) as payment_total
  from public.monthly_room_records m
  join public.billing_periods bp on bp.id = m.billing_period_id
  left join source_debt_by_room sd
    on sd.property_id = m.property_id
   and sd.room_id = m.room_id
  left join lateral (
    select i.id, i.status, i.paid_amount, i.locked_at
    from public.invoices i
    where i.record_id = m.id and i.status <> 'cancelled'
    order by i.issued_at desc
    limit 1
  ) i on true
  left join lateral (
    select coalesce(sum(p.amount), 0)::numeric as payment_total
    from public.payments p
    where p.invoice_id = i.id
  ) pt on true
  cross join params prm
  where bp.period = prm.target_period
    and (prm.property_id is null or m.property_id = prm.property_id)
)
select
  t.*,
  case
    when greatest(t.payment_total, coalesce(t.invoice_paid_amount, 0)) > 0
      or t.invoice_status in ('partial', 'paid') then 'HAS_PAYMENT_DO_NOT_TOUCH'
    when t.invoice_locked_at is not null then 'ROOM_LOCKED_DO_NOT_TOUCH'
    when t.current_previous_debt is not distinct from t.source_debt then 'ALREADY_MATCHED'
    when t.invoice_id is not null then 'SAFE_TO_UPDATE_AND_SYNC_INVOICE'
    else 'SAFE_TO_UPDATE'
  end as update_result
from target_rows t
order by t.property_id, t.room_id;

-- SAU KHI ĐÃ KIỂM TRA PREVIEW, bỏ comment toàn bộ khối dưới để cập nhật.
-- Khối này chỉ sửa previous_debt tháng 09 và đồng bộ invoice tháng 09 chưa thu.
-- Không sửa payment, hóa đơn đã thu hoặc hóa đơn đã khóa theo phòng.
-- begin;
-- with params as (
--   select null::uuid as property_id,
--          '2026-08'::text as source_period,
--          '2026-09'::text as target_period
-- ),
-- source_invoice_debt as (
--   select
--     m.property_id,
--     m.room_id,
--     greatest(
--       0,
--       i.total_amount
--       - greatest(coalesce(i.paid_amount, 0), coalesce(pt.payment_total, 0))
--     ) as remaining_debt
--   from public.monthly_room_records m
--   join public.billing_periods bp on bp.id = m.billing_period_id
--   join public.invoices i on i.record_id = m.id and i.status <> 'cancelled'
--   left join lateral (
--     select coalesce(sum(p.amount), 0)::numeric as payment_total
--     from public.payments p
--     where p.invoice_id = i.id
--   ) pt on true
--   cross join params prm
--   where bp.period = prm.source_period
--     and (prm.property_id is null or m.property_id = prm.property_id)
-- ),
-- source_debt_by_room as (
--   select property_id, room_id, sum(remaining_debt)::numeric as source_debt
--   from source_invoice_debt
--   group by property_id, room_id
-- ),
-- eligible_rows as (
--   select
--     m.id as monthly_record_id,
--     coalesce(sd.source_debt, 0)::numeric as source_debt,
--     i.id as invoice_id,
--     i.status as invoice_status,
--     i.paid_amount as invoice_paid_amount,
--     i.locked_at as invoice_locked_at,
--     greatest(coalesce(i.paid_amount, 0), coalesce(pt.payment_total, 0)) as payment_total
--   from public.monthly_room_records m
--   join public.billing_periods bp on bp.id = m.billing_period_id
--   left join source_debt_by_room sd
--     on sd.property_id = m.property_id and sd.room_id = m.room_id
--   left join lateral (
--     select i.id, i.status, i.paid_amount, i.locked_at
--     from public.invoices i
--     where i.record_id = m.id and i.status <> 'cancelled'
--     order by i.issued_at desc
--     limit 1
--   ) i on true
--   left join lateral (
--     select coalesce(sum(p.amount), 0)::numeric as payment_total
--     from public.payments p
--     where p.invoice_id = i.id
--   ) pt on true
--   cross join params prm
--   where bp.period = prm.target_period
--     and (prm.property_id is null or m.property_id = prm.property_id)
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
--   set previous_debt = e.source_debt,
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

