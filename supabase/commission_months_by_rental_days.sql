-- Bloom Apartment — cho phép hoa hồng 0 tháng khi thời hạn thuê dưới 30 ngày.
-- Migration này chỉ thay đổi constraint, không cập nhật hoặc xóa dữ liệu hiện có.

alter table public.lease_commissions
  drop constraint if exists lease_commissions_commission_months_check;

alter table public.lease_commissions
  add constraint lease_commissions_commission_months_check
  check(commission_months>=0);
