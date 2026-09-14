-- Migration mở rộng upload tài liệu nhiều ảnh.
-- Chạy sau schema.sql hoặc chạy độc lập trong Supabase SQL Editor.
-- Script idempotent: không xóa cột/path cũ và không tạo attachment trùng.
create table if not exists public.document_attachments(
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  entity_type text not null check(entity_type in('tenant','lease')),
  entity_id uuid not null,
  document_type text,
  file_path text not null,
  file_name text,
  mime_type text,
  file_size bigint,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists document_attachments_entity_path_uidx
  on public.document_attachments(entity_type,entity_id,file_path);
create index if not exists document_attachments_property_idx
  on public.document_attachments(property_id);
create index if not exists document_attachments_entity_idx
  on public.document_attachments(entity_type,entity_id);
create index if not exists document_attachments_property_entity_idx
  on public.document_attachments(property_id,entity_type,entity_id);
create index if not exists document_attachments_sort_idx
  on public.document_attachments(sort_order);

create or replace function public.validate_document_attachment_property()
returns trigger language plpgsql as $$
begin
  if new.entity_type='tenant' then
    if not exists(select 1 from public.tenants where id=new.entity_id and property_id=new.property_id) then
      raise exception 'Tài liệu khách thuê không thuộc tòa nhà đã chọn';
    end if;
  elsif new.entity_type='lease' then
    if not exists(select 1 from public.leases where id=new.entity_id and property_id=new.property_id) then
      raise exception 'Tài liệu hợp đồng không thuộc tòa nhà đã chọn';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists validate_document_attachment_property on public.document_attachments;
create trigger validate_document_attachment_property
before insert or update on public.document_attachments
for each row execute function public.validate_document_attachment_property();
drop trigger if exists set_document_attachments_updated_at on public.document_attachments;
create trigger set_document_attachments_updated_at
before update on public.document_attachments
for each row execute function public.set_updated_at();
alter table public.document_attachments enable row level security;

insert into public.document_attachments(entity_type,entity_id,property_id,document_type,file_path,sort_order)
select 'tenant',t.id,t.property_id,'identity',t.identity_document_path,0
from public.tenants t
where t.identity_document_path is not null and btrim(t.identity_document_path)<>''
  and not exists(
    select 1 from public.document_attachments d
    where d.entity_type='tenant' and d.entity_id=t.id and d.file_path=t.identity_document_path
  );

insert into public.document_attachments(entity_type,entity_id,property_id,document_type,file_path,sort_order)
select 'lease',l.id,l.property_id,'contract',l.contract_document_path,0
from public.leases l
where l.contract_document_path is not null and btrim(l.contract_document_path)<>''
  and not exists(
    select 1 from public.document_attachments d
    where d.entity_type='lease' and d.entity_id=l.id and d.file_path=l.contract_document_path
  );

