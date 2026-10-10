-- Thêm hồ sơ khách thuê từ danh sách đăng ký tạm trú.
-- Bỏ qua thông tin phòng và không tạo hợp đồng thuê.
-- Chạy trong Supabase SQL Editor của đúng project.

begin;

do $$
begin
  if not exists (select 1 from public.properties where name = 'Bloom Apartment') then
    raise exception 'Không tìm thấy tòa nhà Bloom Apartment trong public.properties';
  end if;
end $$;

with property as (
  select id
  from public.properties
  where name = 'Bloom Apartment'
  limit 1
), data(full_name, nationality, identity_type, identity_number, permanent_address, notes) as (
  values
    ('Nguyễn Thị Thu Phương', 'Việt Nam', 'CCCD', '049182011960', 'Thôn Xuân Trung, Tam Quang, Núi Thành, Quảng Nam', 'Năm sinh: 1982; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Trần Lương Phương Thảo', 'Việt Nam', 'CCCD', '045301007049', 'Tổ 7 khu phố 9, Nam Đông Hà, Quảng Trị', 'Năm sinh: 2001; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Trần Lương Phương Nguyên', 'Việt Nam', 'CCCD', '045303001249', 'Khu phố 9, Phường 5, TP Đông Hà, Quảng Trị', 'Năm sinh: 2003; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Bùi Sơn Thắng', 'Việt Nam', 'CCCD', '034094002741', 'Thôn Vạn Đồn Hồng Dũng, Thái Thụy, Thái Bình', 'Năm sinh: 1994; Thời hạn đăng ký tạm trú: 2026-08-31'),
    ('Lê Anh Quốc', 'Việt Nam', 'CCCD', '045090009559', 'Khu phố 1, phường 2, Thị xã Quảng Trị, Quảng Trị', 'Năm sinh: 1990; Thời hạn đăng ký tạm trú: 2027-05-31'),
    ('Lê Tuấn Vũ', 'Việt Nam', 'CCCD', '052096019519', 'KP Gia Chiểu 1, Thị trấn Tăng Bạt Hổ, Hoài Ân, Bình Định', 'Năm sinh: 1996; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Hoàng Cẩm Vân', 'Việt Nam', 'CCCD', '044196009708', 'Tiểu khu 12, Thị trấn Hoàn Lão, Bố Trạch, Quảng Bình', 'Năm sinh: 1996; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Phạm Đức Anh', 'Việt Nam', 'CCCD', '024094003124', 'Thôn Tân Lập, Ngọc Thiện, Tân Yên, Bắc Giang', 'Năm sinh: 1994; Thời hạn đăng ký tạm trú: 2027-05-31'),
    ('Trần Thị Cẩm Tiên', 'Việt Nam', 'CCCD', '045193009650', 'Thôn Dương Lệ Đông, Triệu Thuận, Thiệu Phong, Quảng Trị', 'Năm sinh: 1993; Thời hạn đăng ký tạm trú: 2027-05-31'),
    ('Nguyễn Minh Phú', 'Việt Nam', 'CCCD', '001204027540', 'A8.01 C/c River Park Premier, P Tân Phong, Quận 7, TP Hồ Chí Minh', 'Năm sinh: 2004; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Parniuk Yevhenii', 'Ukraine', 'Hộ chiếu', 'FS855407', 'Ukraine', 'Năm sinh: 1981; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Lê Đình Cương', 'Việt Nam', 'CCCD', '045098008523', 'Khu phố 9, Thị trấn Gio Linh, Gio Linh, Quảng Trị', 'Năm sinh: 1998; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Võ Thị Ái Thanh', 'Việt Nam', 'CCCD', '044199003565', 'Khu phố 2, Phường 5, Đông Hà, Quảng Trị', 'Năm sinh: 1999; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('He Jun', 'Trung Quốc', 'Hộ chiếu', 'EH1338470', 'Trung Quốc', 'Năm sinh: 1979; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Wai Wai Lwin', 'Myanmar', 'Hộ chiếu', 'MK942909', 'Myanmar', 'Năm sinh: 2001; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Hà Phước Thanh', 'Việt Nam', 'CCCD', '049098009528', 'Tổ 4, Thôn Duy Hà, Bình Dương, Thăng Bình, Quảng Nam', 'Năm sinh: 1998; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Cao Thị Thanh Thảo', 'Việt Nam', 'CCCD', '049198005948', 'Thôn Trà Đóa 2, Bình Đào, Thăng Bình, Quảng Nam', 'Năm sinh: 1998; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('Phan Thị Thanh Hương', 'Việt Nam', 'CCCD', '045302000808', 'Thôn Thượng Xá, Hải Thượng, Hải Lăng, Quảng Trị', 'Năm sinh: 2002; Thời hạn đăng ký tạm trú: 2026-12-31'),
    ('KRAUS MANUEL DIETER', 'Đức', 'Hộ chiếu', 'CFHNKXKC3', 'Đức', 'Năm sinh: 1984; Thời hạn đăng ký tạm trú: 2027-05-31'),
    ('ME ME THEIN', 'Myanmar', 'Hộ chiếu', 'MJ301796', 'Myanmar', 'Năm sinh: 1980; Thời hạn đăng ký tạm trú: 2026-08-26'),
    ('MAY THIN KHINE', 'Myanmar', 'Hộ chiếu', 'MG090369', 'Myanmar', 'Năm sinh: 2000; Thời hạn đăng ký tạm trú: 2026-08-26'),
    ('CHERKESOV ANDREI', 'Russia', 'Hộ chiếu', '675797804', 'Russia', 'Năm sinh: 1986; Thời hạn đăng ký tạm trú: 2026-10-14'),
    ('CHERKESOVA EKATERINA', 'Russia', 'Hộ chiếu', '675152660', 'Russia', 'Năm sinh: 1991; Thời hạn đăng ký tạm trú: 2026-10-14'),
    ('SU YEDANA NE WIN', 'Singapore', 'Hộ chiếu', 'K5765819R', 'Singapore', 'Năm sinh: 1995; Thời hạn đăng ký tạm trú: 2026-09-01'),
    ('THAN THAN MYINT', 'Myanmar', 'Hộ chiếu', 'MK038637', 'Myanmar', 'Năm sinh: 1975; Thời hạn đăng ký tạm trú: 2026-09-29'),
    ('BIKBAEVA ASIIA', 'Russia', 'Hộ chiếu', '767233873', 'Russia', 'Năm sinh: 1994; Thời hạn đăng ký tạm trú: 2026-09-30'),
    ('BIKBAEVA ILMIRA', 'Russia', 'Hộ chiếu', '664043761', 'Russia', 'Năm sinh: 1961; Thời hạn đăng ký tạm trú: 2026-09-30'),
    ('Nguyễn An Hà', 'Việt Nam', 'CCCD', '040197000012', 'Tổ 34, Trung Hòa, Cầu Giấy, Hà Nội', 'Năm sinh: 1997; Thời hạn đăng ký tạm trú: 2027-05-31')
)
insert into public.tenants (
  property_id,
  full_name,
  nationality,
  identity_type,
  identity_number,
  date_of_birth,
  permanent_address,
  notes
)
select
  property.id,
  data.full_name,
  data.nationality,
  data.identity_type,
  data.identity_number,
  null::date,
  data.permanent_address,
  data.notes
from property
cross join data
on conflict do nothing;

commit;

-- Kiểm tra kết quả đã thêm.
select
  full_name,
  nationality,
  identity_type,
  identity_number,
  permanent_address,
  notes
from public.tenants
where property_id = (select id from public.properties where name = 'Bloom Apartment')
order by full_name;
