# Bloom Apartment v3

Webapp quản lý phòng chạy trên Vercel, dùng Supabase PostgreSQL làm database chung.

## Chức năng

- Dashboard phòng, công nợ, cảnh báo hợp đồng và visa.
- Danh sách nhiều tòa nhà, có mã riêng và chức năng thêm, sửa, xóa an toàn.
- Bộ chọn tòa nhà dùng chung; Phòng, Khách thuê, Hợp đồng, Dữ liệu tháng, Thu tiền, Visa và Báo cáo tự lọc theo tòa nhà.
- Quản lý phòng, khách thuê, hợp đồng và lịch sử.
- Nhập điện, nước, dịch vụ, nợ cũ theo từng tháng.
- Phát hành hóa đơn, thanh toán một phần hoặc toàn bộ.
- Phát hành hóa đơn không khóa kỳ; dữ liệu từng phòng vẫn sửa được khi hóa đơn chưa có thanh toán. Phòng sẽ tự khóa sau khi ghi nhận khoản thu đầu tiên.
- Thanh toán được ghi nhận trong transaction database, có chống ghi trùng request và không cho vượt công nợ.
- Xem và tải hóa đơn PNG theo thiết kế Bloom, có VietQR và tài khoản riêng của từng tòa nhà.
- Cảnh báo hợp đồng/visa theo thời gian còn lại.
- Báo cáo theo tòa nhà, tháng/năm và hai chế độ: theo kỳ hóa đơn hoặc theo dòng tiền thực nhận; có KPI, cơ cấu phải thu, chi tiết theo phòng, xu hướng 6 tháng và xuất CSV UTF-8.
- Giao diện responsive cho máy tính và điện thoại.
- Mật khẩu quản trị, tài khoản chỉ xem và nhật ký thay đổi.

## Cài database

Mở Supabase → SQL Editor, chạy toàn bộ `supabase/schema.sql`. Tệp tạo cấu trúc mới và 20 phòng từ 101 đến 405. Bảng `room_bills` cũ không bị xóa nên dữ liệu trước đây vẫn an toàn để đối chiếu.

Tệp schema có thể chạy lại trên database đã tồn tại. Phiên bản hiện tại bổ sung mã hóa đơn theo tòa nhà, trạng thái khóa kỳ, thông tin hủy hóa đơn, khóa chống ghi trùng thanh toán và hàm transaction `record_payment`.

## Liên kết dữ liệu

- `properties.id` → `rooms.property_id`, `property_settings.property_id`, `billing_periods.property_id`.
- `rooms.id` → `leases.room_id`, `monthly_room_records.room_id`.
- `tenants.id` → `leases.representative_tenant_id`, `lease_tenants.tenant_id`, `tenant_visas.tenant_id`.
- `billing_periods.id` → `monthly_room_records.billing_period_id`.
- `monthly_room_records.id` → `invoices.record_id` → `payments.invoice_id`.

Các khóa chính dùng UUID. `property_code` là mã nghiệp vụ duy nhất để tìm và nhận biết tòa nhà. Tòa nhà còn phòng hoặc dữ liệu liên quan sẽ không thể bị xóa.

Database còn dùng khóa ngoại ghép `(id, property_id)` để ngăn liên kết phòng, khách, hợp đồng, visa hoặc dữ liệu tháng của hai tòa nhà khác nhau. Mỗi phòng chỉ có tối đa một hợp đồng đang hiệu lực; số giấy tờ và số visa không được trùng trong cùng tòa nhà.

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
4. Kiểm tra dữ liệu tháng rồi phát hành hóa đơn theo kỳ và gửi khách kiểm tra. Khi chưa có thanh toán, dữ liệu vẫn có thể sửa và phát hành lại.
5. Ghi nhận từng lần thanh toán; phòng có khoản thu sẽ tự khóa, trạng thái hóa đơn tự đổi thành chưa thu, thu một phần hoặc đã thu.

Sau khi phòng đã có thanh toán, không sửa trực tiếp dữ liệu tháng của phòng đó. Nếu phát hiện sai sau thanh toán, cần dùng quy trình hóa đơn điều chỉnh/hủy để giữ nguyên lịch sử giao dịch.
