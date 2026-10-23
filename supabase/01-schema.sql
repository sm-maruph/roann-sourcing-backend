-- LEGACY SUPABASE SETUP: not used by the current backend. Use db/ and npm run db:migrate.
-- Run first in the Supabase SQL Editor. Intended for a new Roann database.
begin;
create extension if not exists pgcrypto;

create table public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create function public.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.admin_users where user_id = (select auth.uid()));
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated, service_role;

create table public.site_settings (
  key text primary key check (key = 'ceo'),
  value jsonb not null check (jsonb_typeof(value) = 'object'),
  updated_at timestamptz not null default now()
);
create table public.hero_banners (
  id uuid primary key default gen_random_uuid(),
  page text not null unique check (page in ('home','about','compliance','mens','womens','girls')),
  image_url text not null default '', title text not null default '', accent text not null default '',
  eyebrow text not null default '', description text not null default '', is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.homepage_categories (
  id uuid primary key default gen_random_uuid(), audience text not null unique check (audience in ('mens','womens','girls')),
  label text not null, image_url text not null default '', sort_order integer not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.partners (
  id uuid primary key default gen_random_uuid(), name text not null check (length(name) between 1 and 100), image_url text not null default '', website_url text not null default '',
  sort_order integer not null default 0 check (sort_order >= 0), is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.certifications (
  id uuid primary key default gen_random_uuid(), name text not null check (length(name) between 1 and 100), caption text not null default '', image_url text not null default '',
  sort_order integer not null default 0 check (sort_order >= 0), is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.categories (
  id uuid primary key default gen_random_uuid(), parent_id uuid references public.categories(id) on delete restrict,
  name text not null check (length(name) between 1 and 100), slug text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  level integer not null check (level between 1 and 3), hero_image_url text not null default '',
  tagline text not null default '', description text not null default '', config jsonb not null default '{}' check (jsonb_typeof(config) = 'object'),
  sort_order integer not null default 0 check (sort_order >= 0), is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (parent_id is null and level = 1 and slug in ('mens','womens','girls') or parent_id is not null and level > 1)
);
create unique index categories_root_slug on public.categories(slug) where parent_id is null;
create unique index categories_sibling_slug on public.categories(parent_id, slug) where parent_id is not null;
create index categories_parent on public.categories(parent_id);
create function public.enforce_category_tree() returns trigger language plpgsql set search_path = '' as $$
declare parent_level integer;
begin
  if TG_OP = 'UPDATE' and (new.parent_id is distinct from old.parent_id or (old.level = 1 and new.slug <> old.slug)) then
    raise exception 'Category parent and collection root are fixed. Create a new category and move products instead.';
  end if;
  if new.parent_id is null then new.level := 1;
  else
    select level into parent_level from public.categories where id = new.parent_id;
    if parent_level is null or parent_level >= 3 then raise exception 'Choose a parent at level 1 or 2. Maximum category depth is 3.'; end if;
    new.level := parent_level + 1;
  end if;
  return new;
end; $$;
create trigger categories_tree before insert or update on public.categories for each row execute function public.enforce_category_tree();

create table public.products (
  id uuid primary key default gen_random_uuid(), sku text not null unique check (length(sku) between 1 and 80),
  name text not null check (length(name) between 1 and 150), category_id uuid not null references public.categories(id) on delete restrict,
  description text not null default '', subtitle text not null default '', image_url text not null default '',
  color_name text not null default '', color_hex text not null default '#bab4a7' check (color_hex ~ '^#[0-9a-fA-F]{6}$'),
  attributes jsonb not null default '{}' check (jsonb_typeof(attributes) = 'object'),
  pattern text not null default 'plain' check (pattern in ('plain','stripes','print','check')),
  sort_order integer not null default 0 check (sort_order >= 0), is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index products_category on public.products(category_id);
create index products_published on public.products(is_active, sort_order);
create function public.enforce_product_category() returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists(select 1 from public.categories where id = new.category_id and level in (2,3)) then
    raise exception 'Assign a product to a subcategory or sub-subcategory, not the collection root.';
  end if;
  if exists(select 1 from jsonb_each(new.attributes) where lower(key) = 'color' and jsonb_typeof(value) = 'array') then
    raise exception 'Each product has one color. Create a separate product for a different color.';
  end if;
  return new;
end; $$;
create trigger products_category before insert or update on public.products for each row execute function public.enforce_product_category();

create table public.quote_requests (
  id uuid primary key default gen_random_uuid(), product_id uuid references public.products(id) on delete set null,
  product_sku text not null default '', product_name text not null check (length(product_name) between 1 and 150), color text not null default '',
  name text not null check (length(name) between 1 and 100), email text not null check (length(email) <= 200 and position('@' in email) > 1),
  company text not null default '', quantity integer not null check (quantity between 1 and 10000000), message text not null default '' check (length(message) <= 2500),
  status text not null default 'new' check (status in ('new','reviewing','responded','closed')), admin_notes text not null default '',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index quote_requests_inbox on public.quote_requests(status, created_at desc);
create index quote_requests_product on public.quote_requests(product_id);
create table public.media_assets (
  id uuid primary key default gen_random_uuid(), path text not null unique, url text not null,
  kind text not null check (kind in ('hero','category','product','ceo','logo','certification')),
  width integer not null check (width > 0), height integer not null check (height > 0), bytes integer not null check (bytes > 0),
  uploaded_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now()
);
create function public.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
do $$ declare t text; begin
  foreach t in array array['site_settings','hero_banners','homepage_categories','partners','certifications','categories','products','quote_requests'] loop
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()', t);
  end loop;
end; $$;

-- Security-definer helper avoids recursive category RLS while checking every ancestor.
create function public.category_is_public(category_uuid uuid) returns boolean language sql stable security definer set search_path = '' as $$
  with recursive ancestors as (
    select id, parent_id, is_active from public.categories where id = category_uuid
    union all select c.id, c.parent_id, c.is_active from public.categories c join ancestors a on c.id = a.parent_id
  ) select coalesce(bool_and(is_active), false) from ancestors;
$$;
revoke all on function public.category_is_public(uuid) from public;
grant execute on function public.category_is_public(uuid) to anon, authenticated, service_role;

do $$ declare t text; begin
  foreach t in array array['admin_users','site_settings','hero_banners','homepage_categories','partners','certifications','categories','products','quote_requests','media_assets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
  foreach t in array array['site_settings','hero_banners','homepage_categories','partners','certifications','categories','products'] loop
    execute format('grant select on public.%I to anon, authenticated', t);
    execute format('grant insert, update, delete on public.%I to authenticated', t);
    execute format('create policy admin_manage on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end; $$;
create policy public_settings on public.site_settings for select to anon, authenticated using (true);
create policy public_homepage_categories on public.homepage_categories for select to anon, authenticated using (true);
create policy public_heroes on public.hero_banners for select to anon, authenticated using (is_active);
create policy public_partners on public.partners for select to anon, authenticated using (is_active);
create policy public_certifications on public.certifications for select to anon, authenticated using (is_active);
create policy public_categories on public.categories for select to anon, authenticated using (public.category_is_public(id));
create policy public_products on public.products for select to anon, authenticated using (is_active and public.category_is_public(category_id));
grant select on public.admin_users to authenticated;
create policy admin_self on public.admin_users for select to authenticated using (user_id = (select auth.uid()));
grant select, update on public.quote_requests to authenticated;
create policy admin_quotes_select on public.quote_requests for select to authenticated using (public.is_admin());
create policy admin_quotes_update on public.quote_requests for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.media_assets to authenticated;
create policy admin_media_select on public.media_assets for select to authenticated using (public.is_admin());
-- Quotes can only be inserted by the rate-limited API; no anonymous direct insert.
-- Admin membership and media records are managed only by trusted server / SQL Editor.
commit;
