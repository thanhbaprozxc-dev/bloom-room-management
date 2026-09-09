-- LEGACY IMPORT: chỉ dùng để nhập dữ liệu lịch sử/khởi tạo một lần.
-- Không dùng file này để tạo phí dịch vụ + nước cho hợp đồng mới.
-- Phí dịch vụ + nước chuẩn phải được nhập tại leases.service_water_fee.
-- Nhập dữ liệu điện, tiền phòng, phí dịch vụ và nợ trước
-- cho Bloom Apartment - kỳ 2026-09.
-- Nếu dữ liệu thuộc kỳ khác, chỉ cần đổi giá trị v_period bên dưới.

do $$
declare
  v_property_id uuid;
  v_period_id uuid;
  v_period text := '2026-09';
  v_period_status text;
begin
  select id into v_property_id
  from public.properties
  where name = 'Bloom Apartment'
  limit 1;

  if v_property_id is null then
    raise exception 'Không tìm thấy tòa nhà Bloom Apartment';
  end if;

  select id, status into v_period_id, v_period_status
  from public.billing_periods
  where property_id = v_property_id and period = v_period;

  if not found then
    insert into public.billing_periods(property_id, period, status)
    values (v_property_id, v_period, 'open')
    returning id, status into v_period_id, v_period_status;
  end if;

  if v_period_status = 'locked' then
    raise exception 'Kỳ % đã khóa, không thể nhập lại dữ liệu', v_period;
  end if;

  if exists (
    select 1
    from public.invoices i
    join public.monthly_room_records m on m.id = i.record_id
    where m.property_id = v_property_id
      and m.billing_period_id = v_period_id
  ) then
    raise exception 'Kỳ % đã có hóa đơn, không nên ghi đè dữ liệu', v_period;
  end if;

  with source_data(room_number, rent, service_fee, electric_start, electric_end, previous_debt) as (
    values
      ('101',      0,       0,  635,  867,      0),
      ('102',      0,       0, 1093, 1744,      0),
      ('103', 4500000,  200000,  348,  464,      0),
      ('104', 4200000,  200000,  418,  576,      0),
      ('105',      0,       0,  435,  472, 200000),
      ('201', 5000000,  200000,  410,  502,      0),
      ('202', 5000000,  200000,  393,  482,      0),
      ('203', 4300000,  400000,  328,  508,      0),
      ('204', 4800000,  200000,  355,  499, 800000),
      ('205', 5000000,  200000,  353,  475,      0),
      ('301', 4600000,  400000,  358,  494,      0),
      ('302', 5700000,  400000, 1296, 1894,      0),
      ('303', 4500000,  150000,  257,  393,      0),
      ('304', 5000000,  150000,  482,  748,      0),
      ('305', 5000000,  200000,  708, 1102,      0),
      ('401', 5500000,  400000, 1115, 1584,      0),
      ('402', 6000000,  400000,  464,  782,      0),
      ('403', 4700000,  400000,  328,  506,      0),
      ('404', 5500000,  300000,  186,  316,      0),
      ('405', 4500000,  200000,  456,  646,      0)
  )
  insert into public.monthly_room_records(
    property_id,
    billing_period_id,
    room_id,
    lease_id,
    rent,
    electric_start,
    electric_end,
    electric_rate,
    water_start,
    water_end,
    water_rate,
    service_fee,
    other_fee,
    discount,
    previous_debt,
    notes
  )
  select
    v_property_id,
    v_period_id,
    r.id,
    active_lease.id,
    s.rent,
    s.electric_start,
    s.electric_end,
    4000,
    0,
    0,
    0,
    s.service_fee,
    0,
    0,
    s.previous_debt,
    'Nhập từ bảng điện tháng 8 và phí dịch vụ tháng 9'
  from source_data s
  join public.rooms r
    on r.property_id = v_property_id
   and r.room_number = s.room_number
  left join lateral (
    select l.id
    from public.leases l
    where l.property_id = v_property_id
      and l.room_id = r.id
      and l.status = 'active'
    order by l.end_date desc
    limit 1
  ) active_lease on true
  on conflict (billing_period_id, room_id) do update set
    lease_id = excluded.lease_id,
    rent = excluded.rent,
    electric_start = excluded.electric_start,
    electric_end = excluded.electric_end,
    electric_rate = excluded.electric_rate,
    water_start = excluded.water_start,
    water_end = excluded.water_end,
    water_rate = excluded.water_rate,
    service_fee = excluded.service_fee,
    other_fee = excluded.other_fee,
    discount = excluded.discount,
    previous_debt = excluded.previous_debt,
    notes = excluded.notes;
end $$;

-- Kiểm tra nhanh tổng số phòng đã nhập và tổng tiền dự kiến.
select
  r.room_number as ma_phong,
  m.rent as tien_phong,
  m.service_fee as phi_dich_vu,
  (m.electric_end - m.electric_start) as so_dien_da_dung,
  (m.electric_end - m.electric_start) * m.electric_rate as tien_dien,
  m.previous_debt as no_truoc,
  m.rent
    + ((m.electric_end - m.electric_start) * m.electric_rate)
    + m.service_fee
    + m.other_fee
    + m.previous_debt
    - m.discount as tong_phai_dong
from public.monthly_room_records m
join public.rooms r on r.id = m.room_id
join public.properties p on p.id = m.property_id
join public.billing_periods b on b.id = m.billing_period_id
where p.name = 'Bloom Apartment'
  and b.period = '2026-09'
order by r.room_number::int;

