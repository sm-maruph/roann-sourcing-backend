begin;
create table public.product_sku_counters (
  prefix text primary key,
  last_number bigint not null check (last_number > 0)
);
alter table public.product_sku_counters enable row level security;
revoke all on public.product_sku_counters from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname='anon') then revoke all on public.product_sku_counters from anon; end if;
  if exists(select 1 from pg_roles where rolname='authenticated') then revoke all on public.product_sku_counters from authenticated; end if;
end; $$;

-- Continue existing series rather than starting again at 001.
insert into public.product_sku_counters(prefix,last_number)
select regexp_replace(sku,'-[0-9]+$',''), max(substring(sku from '-([0-9]+)$')::bigint)
from public.products where sku ~ '^RS-[A-Z0-9]+-[0-9]+$'
group by regexp_replace(sku,'-[0-9]+$','');

create function public.product_sku_prefix(category_uuid uuid) returns text
language plpgsql stable set search_path = '' as $$
declare assigned public.categories; product_group public.categories; root public.categories; group_code text; root_code text;
begin
  select * into assigned from public.categories where id=category_uuid;
  if assigned.level=3 then select * into product_group from public.categories where id=assigned.parent_id;
  elsif assigned.level=2 then product_group := assigned;
  else raise exception 'Select a product group or subcategory before generating a SKU.';
  end if;
  select * into root from public.categories where id=product_group.parent_id;
  root_code := case root.slug when 'mens' then 'M' when 'womens' then 'W' when 'girls' then 'G'
    else upper(left(regexp_replace(root.slug,'[^a-z0-9]','','g'),1)) end;
  group_code := case product_group.slug when 't-shirts' then 'TS' when 'denim' then 'DN'
    when 'trousers' then 'TR' when 'sweaters' then 'SW' when 'boxers' then 'BX'
    when 'leggings' then 'LG' when 'lingerie' then 'LN'
    else upper(left(regexp_replace(product_group.slug,'[^a-z0-9]','','g'),4)) end;
  return 'RS-' || root_code || group_code;
end; $$;

create function public.assign_product_sku() returns trigger
language plpgsql set search_path = '' as $$
declare sku_prefix text; allocated bigint;
begin
  -- Preserve established product identity during edits.
  if TG_OP='UPDATE' then new.sku := old.sku; return new; end if;
  if new.sku is not null and btrim(new.sku) <> '' then return new; end if;
  sku_prefix := public.product_sku_prefix(new.category_id);
  insert into public.product_sku_counters(prefix,last_number) values(sku_prefix,1)
    on conflict(prefix) do update set last_number=public.product_sku_counters.last_number+1
    returning last_number into allocated;
  new.sku := sku_prefix || '-' || lpad(allocated::text,greatest(3,length(allocated::text)),'0');
  return new;
end; $$;
create trigger products_auto_sku before insert or update on public.products
for each row execute function public.assign_product_sku();
revoke all on function public.product_sku_prefix(uuid), public.assign_product_sku() from public;
commit;
