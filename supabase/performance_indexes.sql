-- Indexes derived from the current API filter and join paths.
-- All statements are idempotent and do not change the data model.

create index if not exists tenants_property_idx
  on public.tenants(property_id);

create index if not exists leases_property_idx
  on public.leases(property_id);

create index if not exists leases_room_idx
  on public.leases(room_id);

create index if not exists leases_representative_tenant_idx
  on public.leases(representative_tenant_id);

create index if not exists lease_tenants_tenant_idx
  on public.lease_tenants(tenant_id);

create index if not exists tenant_visas_property_status_expiry_idx
  on public.tenant_visas(property_id,status,expiry_date);

create index if not exists monthly_records_property_period_idx
  on public.monthly_room_records(property_id,billing_period_id);

