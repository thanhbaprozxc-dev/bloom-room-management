-- Chạy một lần trên Supabase SQL Editor để bật upload ảnh giấy tờ/hợp đồng.
alter table public.tenants add column if not exists identity_document_path text;
alter table public.leases add column if not exists contract_document_path text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('private-documents','private-documents',false,3145728,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;
