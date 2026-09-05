# Bloom Apartment — Vercel + Supabase

Ứng dụng dùng Vercel để chạy giao diện/API và Supabase PostgreSQL để lưu dữ liệu chung. Khóa `service_role` chỉ tồn tại trong biến môi trường của Vercel, không xuất hiện trong trình duyệt.

## 1. Tạo database Supabase

1. Đăng nhập Supabase và tạo project mới.
2. Mở **SQL Editor** → **New query**.
3. Sao chép toàn bộ nội dung `supabase/schema.sql`, chạy bằng nút **Run**.
4. Vào **Project Settings → API** và ghi lại:
   - Project URL.
   - `service_role` secret key. Không dùng `anon` key cho biến này và không chia sẻ khóa.

## 2. Đưa mã nguồn lên GitHub

Tạo repository mới, sau đó tải toàn bộ nội dung thư mục này lên repository. `index.html`, `api`, `supabase`, `package.json` và `vercel.json` phải nằm ở thư mục gốc.

## 3. Triển khai Vercel

1. Đăng nhập Vercel bằng GitHub.
2. Chọn **Add New → Project** và import repository vừa tạo.
3. Framework Preset: **Other**. Không cần Build Command và Output Directory.
4. Thêm ba biến môi trường cho Production, Preview và Development:

| Tên | Giá trị |
| --- | --- |
| `SUPABASE_URL` | Project URL của Supabase |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role secret key |
| `ADMIN_PASSWORD` | Mật khẩu riêng, dài và khó đoán |

5. Nhấn **Deploy**. Vercel sẽ cấp địa chỉ dạng `https://ten-du-an.vercel.app`.

## 4. Sử dụng

Mở địa chỉ Vercel trên bất kỳ máy nào, nhập cùng mật khẩu quản trị. Tất cả thiết bị sẽ dùng chung dữ liệu trong Supabase.

## Bảo mật

- Tuyệt đối không đưa `SUPABASE_SERVICE_ROLE_KEY` vào `index.html` hoặc GitHub.
- Bảng đã bật Row Level Security và không có quyền truy cập công khai.
- Mật khẩu quản trị được giữ trong `sessionStorage`, tự mất khi đóng tab trình duyệt.
- Khi đổi biến môi trường trên Vercel, hãy redeploy để áp dụng.
