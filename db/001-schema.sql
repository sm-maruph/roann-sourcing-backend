-- Portable PostgreSQL 14+ schema. Fresh database only; run via npm run db:migrate.
begin;
create table public.admin_users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (email = lower(email) and length(email) <= 200),
  password_hash text not null,
  created_at timestamptz not null default now()
);
create table public.admin_sessions (
  token_hash text primary key,
  admin_id uuid not null references public.admin_users(id) on delete cascade,
  expires_at timestamptz not null
);
create index admin_sessions_expiry on public.admin_sessions(expires_at);
create table public.hero_banners (
  id uuid primary key default gen_random_uuid(),
  page text not null unique check (page in ('home','about','compliance','mens','womens','girls')),
  image_url text not null default '', title text not null default '', accent text not null default '',
  eyebrow text not null default '', description text not null default '', is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.partners (
  id uuid primary key default gen_random_uuid(), name text not null check (length(name) between 1 and 100), image_url text not null default '', website_url text not null default '',
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
  uploaded_by uuid references public.admin_users(id) on delete set null, created_at timestamptz not null default now()
);
create function public.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
do $$ declare t text; begin
  foreach t in array array['hero_banners','partners','categories','products','quote_requests'] loop
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()', t);
  end loop;
end; $$;

-- No browser role may read private data or bypass API validation.
-- The backend connects as the owning application role. Do not expose its credentials.
-- Explicit statements also make the SQL Editor's RLS review easier to inspect.
alter table public.admin_users enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.hero_banners enable row level security;
alter table public.partners enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.quote_requests enable row level security;
alter table public.media_assets enable row level security;

do $$ declare t text; begin
  foreach t in array array['admin_users','admin_sessions','hero_banners','partners','categories','products','quote_requests','media_assets'] loop
    execute format('revoke all on public.%I from public', t);
    if exists(select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on public.%I from anon', t); end if;
    if exists(select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on public.%I from authenticated', t); end if;
  end loop;
end; $$;
create index quote_requests_created on public.quote_requests(created_at desc);
commit;
