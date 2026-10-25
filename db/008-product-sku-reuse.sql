begin;

-- Allocate from SKUs that still exist. Deleted products no longer keep their
-- old number reserved, so an empty group starts again at 001.
create or replace function public.assign_product_sku() returns trigger
language plpgsql set search_path = '' as $$
declare
  sku_prefix text;
  allocated bigint;
begin
  if new.sku is not null and btrim(new.sku) <> '' then return new; end if;

  sku_prefix := public.product_sku_prefix(new.category_id);
  perform pg_advisory_xact_lock(hashtextextended(sku_prefix, 0));
  select coalesce(max(substring(sku from length(sku_prefix)+2)::bigint), 0) + 1
    into allocated
    from public.products
    where sku like sku_prefix || '-%'
      and substring(sku from length(sku_prefix)+2) ~ '^[0-9]+$';
  new.sku := sku_prefix || '-' || lpad(allocated::text, greatest(3, length(allocated::text)), '0');
  return new;
end;
$$;

revoke all on function public.assign_product_sku() from public;
commit;
