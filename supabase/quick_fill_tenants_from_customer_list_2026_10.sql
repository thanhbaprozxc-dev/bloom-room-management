-- Điền nhanh hồ sơ khách thuê từ danh sách ảnh.
-- Bảng đích: public.tenants
-- Chỉ điền các trường có trong danh sách: full_name, date_of_birth, identity_number.
-- Không chạy tự động; mở file này trong Supabase SQL Editor để kiểm tra rồi chạy.
-- Mặc định gắn dữ liệu vào tòa nhà "Bloom Apartment 2 FPT".

begin;

do $$
begin
  if not exists (
    select 1
    from public.properties
    where name = 'Bloom Apartment 2 FPT'
  ) then
    raise exception 'Không tìm thấy tòa nhà Bloom Apartment 2 FPT trong public.properties';
  end if;
end $$;

create temporary table tmp_quick_fill_tenants (
  source_row integer primary key,
  full_name text,
  date_of_birth date,
  identity_number text
) on commit drop;

insert into tmp_quick_fill_tenants (source_row, full_name, date_of_birth, identity_number)
values
  (1,  'YESSIMOV AMIR',          '2005-11-21', 'N19727850'),
  (2,  null,                     '2005-09-26', 'N19731662'),
  (3,  'TIMERBAEV VADIM',        '2005-11-14', '676412352'),
  (4,  'SOKOLOV DANIL',          '2004-12-27', '674247826'),
  (5,  'FILIPPOVA LIUTSIA',      '1995-09-29', '672694788'),
  (6,  'FILIPPOV ALEKSANDR',     '1991-12-31', '672694814'),
  (7,  'VALIAEV OLEG',           '2004-11-05', '676894608'),
  (8,  'KHAIRZAMANOV ARTUR',     '2005-04-08', '674246305'),
  (9,  'PESTOVA IRINA',          '1987-06-14', '765885267'),
  (10, 'PESTOV VADIM',           '1986-01-02', '765885266'),
  (11, 'SALIKOV LIA',            '2000-07-24', '778760321'),
  (12, 'PROSKURINA NATALIA',     '2002-10-23', '778760255'),
  (13, 'KORIKOVA SOFIIA',        '2002-12-26', '771873870'),
  (14, 'KORIKOV KIRILL',         '2003-11-29', '769398015'),
  (15, 'GARMASH KONSTANTIN',     '2001-09-20', '779935297'),
  (16, 'GOLOVANOVA EKATERINA',   '2001-04-12', '779414117'),
  (17, 'Trương Bá Phước',        '2008-03-13', '066208002266'),
  (18, 'Đậu Thị Thùy Trang',     '2008-07-07', '042308001409'),
  (19, 'Trần Thị Thảo Hà',       '2008-03-06', '049308010930'),
  (20, 'Trần Huyền',             null,         null),
  (21, 'Trương Gia Huy',         '2008-04-05', '042208010480'),
  (22, 'Lê Công Minh',           '2008-03-12', '042208001967'),
  (23, 'Lê Nguyễn Minh Hải',     '2008-06-16', '056208005855');

-- Cập nhật khách đã tồn tại theo số giấy tờ.
update public.tenants as t
set
  full_name = btrim(d.full_name),
  date_of_birth = coalesce(d.date_of_birth, t.date_of_birth),
  identity_type = case
    when btrim(d.identity_number) ~ '^[0-9]+$' then 'CCCD'
    else 'Hộ chiếu'
  end,
  updated_at = now()
from public.properties as p,
     tmp_quick_fill_tenants as d
where p.name = 'Bloom Apartment 2 FPT'
  and nullif(btrim(d.full_name), '') is not null
  and nullif(btrim(d.identity_number), '') is not null
  and t.property_id = p.id
  and t.identity_number = btrim(d.identity_number);

-- Thêm khách chưa có trong database.
-- Số chỉ gồm chữ số được phân loại là CCCD; số có chữ cái như N19727850 là Hộ chiếu.
insert into public.tenants (
  property_id,
  full_name,
  identity_type,
  identity_number,
  date_of_birth
)
select
  p.id,
  btrim(d.full_name),
  case
    when btrim(d.identity_number) ~ '^[0-9]+$' then 'CCCD'
    else 'Hộ chiếu'
  end,
  btrim(d.identity_number),
  d.date_of_birth
from public.properties as p
cross join tmp_quick_fill_tenants as d
where p.name = 'Bloom Apartment 2 FPT'
  and nullif(btrim(d.full_name), '') is not null
  and nullif(btrim(d.identity_number), '') is not null
  and not exists (
    select 1
    from public.tenants as t
    where t.property_id = p.id
      and t.identity_number = btrim(d.identity_number)
  );

-- Xử lý dòng không có số giấy tờ: cập nhật theo họ tên nếu đã có,
-- hoặc thêm mới với identity_number để trống.
update public.tenants as t
set
  date_of_birth = coalesce(d.date_of_birth, t.date_of_birth),
  updated_at = now()
from public.properties as p,
     tmp_quick_fill_tenants as d
where p.name = 'Bloom Apartment 2 FPT'
  and nullif(btrim(d.full_name), '') is not null
  and nullif(btrim(d.identity_number), '') is null
  and t.property_id = p.id
  and lower(btrim(t.full_name)) = lower(btrim(d.full_name));

insert into public.tenants (
  property_id,
  full_name,
  identity_type,
  identity_number,
  date_of_birth
)
select
  p.id,
  btrim(d.full_name),
  'CCCD',
  null,
  d.date_of_birth
from public.properties as p
cross join tmp_quick_fill_tenants as d
where p.name = 'Bloom Apartment 2 FPT'
  and nullif(btrim(d.full_name), '') is not null
  and nullif(btrim(d.identity_number), '') is null
  and not exists (
    select 1
    from public.tenants as t
    where t.property_id = p.id
      and lower(btrim(t.full_name)) = lower(btrim(d.full_name))
  );

-- Kiểm tra các dòng cần rà soát sau khi chạy.
select
  source_row,
  full_name,
  date_of_birth,
  identity_number,
  case
    when nullif(btrim(full_name), '') is null then 'BỎ QUA: thiếu họ tên'
    when nullif(btrim(identity_number), '') is null then 'Đã xử lý theo họ tên; thiếu số giấy tờ/ngày sinh có thể trống'
    else 'Đã xử lý'
  end as result_note
from tmp_quick_fill_tenants
where nullif(btrim(full_name), '') is null
   or nullif(btrim(identity_number), '') is null
order by source_row;

commit;

-- Kiểm tra nhanh các bản ghi thuộc Bloom Apartment 2 FPT.
select
  full_name,
  date_of_birth,
  identity_type,
  identity_number
from public.tenants
where property_id = (
  select id from public.properties where name = 'Bloom Apartment 2 FPT' limit 1
)
order by created_at desc, full_name;
