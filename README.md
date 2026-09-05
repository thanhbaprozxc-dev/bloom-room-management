# Bloom Apartment v3

Webapp quản lý phòng chạy trên Vercel, dùng Supabase PostgreSQL làm database chung.

## Chức năng

- Dashboard phòng, công nợ, cảnh báo hợp đồng và visa.
- Danh sách nhiều tòa nhà, có mã riêng và chức năng thêm, sửa, xóa an toàn.
- Quản lý phòng, khách thuê, hợp đồng và lịch sử.
- Nhập điện, nước, dịch vụ, nợ cũ theo từng tháng.
- Phát hành hóa đơn, thanh toán một phần hoặc toàn bộ.
- Cảnh báo hợp đồng/visa theo thời gian còn lại.
- Giao diện responsive cho máy tính và điện thoại.
- Mật khẩu quản trị, tài khoản chỉ xem và nhật ký thay đổi.

## Cài database

Mở Supabase → SQL Editor, chạy toàn bộ `supabase/schema.sql`. Tệp tạo cấu trúc mới và 20 phòng từ 101 đến 405. Bảng `room_bills` cũ không bị xóa nên dữ liệu trước đây vẫn an toàn để đối chiếu.

## Liên kết dữ liệu

- `properties.id` → `rooms.property_id`, `property_settings.property_id`, `billing_periods.property_id`.
- `rooms.id` → `leases.room_id`, `monthly_room_records.room_id`.
- `tenants.id` → `leases.representative_tenant_id`, `lease_tenants.tenant_id`, `tenant_visas.tenant_id`.
- `billing_periods.id` → `monthly_room_records.billing_period_id`.
- `monthly_room_records.id` → `invoices.record_id` → `payments.invoice_id`.

Các khóa chính dùng UUID. `property_code` là mã nghiệp vụ duy nhất để tìm và nhận biết tòa nhà. Tòa nhà còn phòng hoặc dữ liệu liên quan sẽ không thể bị xóa.

## Biến môi trường Vercel

```text
SUPABASE_URL=https://PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
ADMIN_PASSWORD=...
VIEWER_PASSWORD=...
```

`VIEWER_PASSWORD` không bắt buộc. Không đưa khóa vào `index.html` hoặc commit lên GitHub.

## Triển khai

Đẩy toàn bộ thư mục lên nhánh `main`; Vercel sẽ tự triển khai. Sau khi đổi biến môi trường, vào Deployments và Redeploy.

## Quy trình sử dụng

1. Thêm khách thuê.
2. Tạo hợp đồng, chọn phòng và người đại diện.
3. Cuối tháng nhập chỉ số và chi phí từng phòng.
4. Phát hành hóa đơn theo kỳ.
5. Ghi nhận từng lần thanh toán; trạng thái tự đổi thành chưa thu, thu một phần hoặc đã thu.
