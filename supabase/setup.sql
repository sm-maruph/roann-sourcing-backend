-- COMPLETE ROANN SOURCING SETUP: run once in Supabase SQL Editor on a fresh project.
-- Existing installation? Use npm run db:migrate instead; never drop existing tables.
-- Custom users: public.admin_users. No Supabase Auth account is required.
-- After setup, provision your own credentials with npm run admin:create.
-- There are no default accounts or passwords. All application access goes through Express.
begin;
-- 001-schema.sql
-- Portable PostgreSQL 14+ schema. Fresh database only; run via npm run db:migrate.

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


-- 002-seed.sql
-- Generated starter content from the current frontend. Run after schema and storage.
-- Existing records are preserved when this seed is rerun. Local image paths use frontend assets.

insert into public.hero_banners(page,image_url) values('home','/images/hero.jpg') on conflict do nothing;
insert into public.hero_banners(page,image_url) values('about','/images/fabric.jpg') on conflict do nothing;
insert into public.hero_banners(page,image_url) values('compliance','/images/textile.jpg') on conflict do nothing;
insert into public.hero_banners(page,image_url) values('mens','/images/hero.jpg') on conflict do nothing;
insert into public.hero_banners(page,image_url) values('womens','/images/fabric.jpg') on conflict do nothing;
insert into public.hero_banners(page,image_url) values('girls','/images/mens/sweater.jpg') on conflict do nothing;
insert into public.categories(name,slug,parent_id) values('Men’s','mens',null) on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'T-Shirts','t-shirts',id,'/images/hero.jpg','Everyday essentials. Global quality.','Versatile styles. Premium fabrics. Reliable manufacturing for global brands.','{"filters":{"Product Type":["Crew Neck","V-Neck","Polo Shirt","Long Sleeve","Oversized"],"Fabric":["Cotton","Cotton Blend","Polyester","Organic"],"Style":["Solid","Printed","Striped","Embroidery"]}}'::jsonb,0 from public.categories where slug='mens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Crew Neck','crew-neck',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Polo Shirt','polo-shirt',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Oversized','oversized',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Long Sleeve','long-sleeve',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'V-Neck','v-neck',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Denim','denim',id,'/images/mens/denim.jpg','Timeless style. Built for more.','Durable construction. Contemporary fits. Trusted sourcing for leading global brands.','{"filters":{"Fit":["Slim Fit","Regular Fit","Relaxed Fit","Straight Fit","Tapered Fit"],"Wash":["Light Wash","Mid Wash","Dark Wash","Black","Vintage"],"Style":["Jeans","Denim Jacket","Denim Shirt","Denim Shorts"]}}'::jsonb,1 from public.categories where slug='mens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Jeans','jeans',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Denim Jacket','denim-jacket',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Denim Shirt','denim-shirt',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Denim Shorts','denim-shorts',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Trousers','trousers',id,'/images/mens/denim.jpg','Modern fits. Business to casual.','Tailored comfort. Versatile styles. Manufacturing excellence for global markets.','{"filters":{"Fit":["Slim Fit","Regular Fit","Relaxed Fit","Straight Fit","Tapered Fit"],"Fabric":["Cotton","Cotton Blend","Linen","Wool Blend","Polyester"],"Style":["Chino","Formal","Cargo","Jogger","Linen"]}}'::jsonb,2 from public.categories where slug='mens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Chino','chino',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='trousers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Formal','formal',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='trousers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Cargo','cargo',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='trousers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Linen','linen',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='trousers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Jogger','jogger',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='trousers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Sweaters','sweaters',id,'/images/mens/sweater.jpg','Warmer ideas. Greater possibilities.','Premium knits. Seasonal styles. Reliable production for global brands.','{"filters":{"Style":["Crew Neck","V-Neck","Turtleneck","Cardigan","Half Zip"],"Material":["Cotton Knit","Wool","Cashmere Blend","Acrylic","Organic"],"Pattern":["Solid","Striped","Cable Knit","Jacquard"]}}'::jsonb,3 from public.categories where slug='mens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Crew Neck','crew-neck',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'V-Neck','v-neck',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Turtleneck','turtleneck',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Cardigan','cardigan',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Half Zip','half-zip',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Boxers','boxers',id,'/images/hero.jpg','Comfort inside. Confidence outside.','Everyday comfort. Premium fabrics. Consistent quality for global markets.','{"filters":{"Type":["Trunks","Boxer Brief","Boxer Shorts","Seamless","Performance"],"Material":["Cotton","Modal","Bamboo","Microfiber","Stretch"],"Pattern":["Solid","Printed","Striped","Jacquard"]}}'::jsonb,4 from public.categories where slug='mens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Trunks','trunks',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='boxers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Boxer Brief','boxer-brief',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='boxers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Boxer Shorts','boxer-shorts',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='boxers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Seamless','seamless',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='boxers' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Performance','performance',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='mens' and root.parent_id is null and c.slug='boxers' on conflict do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-001','Classic Crew Neck',leaf.id,'','','','#dedbd2','{"Product Type":"Crew Neck","Fabric":"Cotton","Style":"Solid"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-002','Polo T-Shirt',leaf.id,'','','','#232628','{"Product Type":"Polo Shirt","Fabric":"Cotton Blend","Style":"Solid"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Polo Shirt' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-003','Oversized T-Shirt',leaf.id,'','','','#373936','{"Product Type":"Oversized","Fabric":"Cotton","Style":"Solid"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Oversized' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-004','Long Sleeve T-Shirt',leaf.id,'','','','#74776c','{"Product Type":"Long Sleeve","Fabric":"Cotton Blend","Style":"Solid"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Long Sleeve' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-005','Striped T-Shirt',leaf.id,'','','','#b4b0a3','{"Product Type":"Crew Neck","Fabric":"Cotton","Style":"Striped"}'::jsonb,'stripes',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-006','Graphic T-Shirt',leaf.id,'','','','#2e3030','{"Product Type":"Crew Neck","Fabric":"Polyester","Style":"Printed"}'::jsonb,'print',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-007','V-Neck T-Shirt',leaf.id,'','','','#8e978e','{"Product Type":"V-Neck","Fabric":"Cotton","Style":"Solid"}'::jsonb,'plain',6 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='V-Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTS-008','Organic Cotton T-Shirt',leaf.id,'','','','#e1ded3','{"Product Type":"Crew Neck","Fabric":"Organic","Style":"Embroidery"}'::jsonb,'plain',7 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-001','Slim Fit Jeans',leaf.id,'','','','#4f6879','{"Fit":"Slim Fit","Wash":"Mid Wash","Style":"Jeans"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Jeans' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-002','Regular Fit Jeans',leaf.id,'','','','#334f67','{"Fit":"Regular Fit","Wash":"Dark Wash","Style":"Jeans"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Jeans' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-003','Tapered Fit Jeans',leaf.id,'','','','#849fae','{"Fit":"Tapered Fit","Wash":"Light Wash","Style":"Jeans"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Jeans' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-004','Relaxed Fit Jeans',leaf.id,'','','','#363b40','{"Fit":"Relaxed Fit","Wash":"Black","Style":"Jeans"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Jeans' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-005','Denim Jacket',leaf.id,'','','','#58728b','{"Fit":"Regular Fit","Wash":"Vintage","Style":"Denim Jacket"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Denim Jacket' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-006','Denim Shirt',leaf.id,'','','','#6f8ca4','{"Fit":"Slim Fit","Wash":"Mid Wash","Style":"Denim Shirt"}'::jsonb,'plain',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Denim Shirt' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-007','Denim Shorts',leaf.id,'','','','#90a8b5','{"Fit":"Regular Fit","Wash":"Light Wash","Style":"Denim Shorts"}'::jsonb,'plain',6 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Denim Shorts' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MDN-008','Black Denim Jeans',leaf.id,'','','','#272d33','{"Fit":"Straight Fit","Wash":"Black","Style":"Jeans"}'::jsonb,'plain',7 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='denim' and leaf.name='Jeans' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-001','Chino Trouser',leaf.id,'','','','#b7a589','{"Fit":"Regular Fit","Fabric":"Cotton","Style":"Chino"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Chino' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-002','Formal Trouser',leaf.id,'','','','#383d40','{"Fit":"Slim Fit","Fabric":"Wool Blend","Style":"Formal"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Formal' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-003','Cargo Trouser',leaf.id,'','','','#5f6654','{"Fit":"Relaxed Fit","Fabric":"Cotton","Style":"Cargo"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Cargo' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-004','Linen Trouser',leaf.id,'','','','#d4c9b5','{"Fit":"Straight Fit","Fabric":"Linen","Style":"Linen"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Linen' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-005','Slim Fit Trouser',leaf.id,'','','','#727777','{"Fit":"Slim Fit","Fabric":"Polyester","Style":"Formal"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Formal' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-006','Relaxed Trouser',leaf.id,'','','','#77786e','{"Fit":"Relaxed Fit","Fabric":"Cotton Blend","Style":"Chino"}'::jsonb,'plain',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Chino' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-007','Jogger Trouser',leaf.id,'','','','#333a3a','{"Fit":"Tapered Fit","Fabric":"Cotton Blend","Style":"Jogger"}'::jsonb,'plain',6 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Jogger' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MTR-008','Checked Trouser',leaf.id,'','','','#aaa69a','{"Fit":"Regular Fit","Fabric":"Wool Blend","Style":"Formal"}'::jsonb,'check',7 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='trousers' and leaf.name='Formal' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-001','Crew Neck Sweater',leaf.id,'','','','#5a6054','{"Style":"Crew Neck","Material":"Cotton Knit","Pattern":"Solid"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-002','V-Neck Sweater',leaf.id,'','','','#95765d','{"Style":"V-Neck","Material":"Wool","Pattern":"Solid"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='V-Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-003','Turtleneck Sweater',leaf.id,'','','','#2b2e31','{"Style":"Turtleneck","Material":"Wool","Pattern":"Solid"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Turtleneck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-004','Cardigan Sweater',leaf.id,'','','','#646c65','{"Style":"Cardigan","Material":"Cotton Knit","Pattern":"Solid"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Cardigan' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-005','Half Zip Sweater',leaf.id,'','','','#304356','{"Style":"Half Zip","Material":"Acrylic","Pattern":"Solid"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Half Zip' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-006','Striped Sweater',leaf.id,'','','','#d4cebf','{"Style":"Crew Neck","Material":"Cotton Knit","Pattern":"Striped"}'::jsonb,'stripes',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-007','Cable Knit Sweater',leaf.id,'','','','#9b9484','{"Style":"Crew Neck","Material":"Wool","Pattern":"Cable Knit"}'::jsonb,'plain',6 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MSW-008','Cashmere Blend Sweater',leaf.id,'','','','#dad1be','{"Style":"V-Neck","Material":"Cashmere Blend","Pattern":"Solid"}'::jsonb,'plain',7 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='V-Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-001','Cotton Trunk',leaf.id,'','','','#303338','{"Type":"Trunks","Material":"Cotton","Pattern":"Solid"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Trunks' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-002','Boxer Brief',leaf.id,'','','','#5e3039','{"Type":"Boxer Brief","Material":"Modal","Pattern":"Solid"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Boxer Brief' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-003','Printed Boxer',leaf.id,'','','','#263b53','{"Type":"Boxer Shorts","Material":"Cotton","Pattern":"Printed"}'::jsonb,'print',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Boxer Shorts' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-004','Seamless Boxer Brief',leaf.id,'','','','#a5adb2','{"Type":"Seamless","Material":"Microfiber","Pattern":"Solid"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Seamless' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-005','Boxer Shorts',leaf.id,'','','','#a7adae','{"Type":"Boxer Shorts","Material":"Cotton","Pattern":"Solid"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Boxer Shorts' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-006','Modal Trunk',leaf.id,'','','','#d0d0c8','{"Type":"Trunks","Material":"Modal","Pattern":"Solid"}'::jsonb,'plain',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Trunks' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-007','Performance Boxer',leaf.id,'','','','#262c31','{"Type":"Performance","Material":"Stretch","Pattern":"Solid"}'::jsonb,'plain',6 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Performance' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-MBX-008','Striped Boxer',leaf.id,'','','','#859eab','{"Type":"Boxer Shorts","Material":"Bamboo","Pattern":"Striped"}'::jsonb,'stripes',7 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='mens' and root.parent_id is null and sub.slug='boxers' and leaf.name='Boxer Shorts' on conflict(sku) do nothing;
insert into public.categories(name,slug,parent_id) values('Women’s','womens',null) on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'T-Shirts','t-shirts',id,'/images/fabric.jpg','Everyday Comfort, Global Quality','Versatile t-shirt solutions in a wide range of fabrics, fits and styles, tailored for global brands and retailers.','{"filters":{"Style":["Crew Neck","V-Neck","Oversized","Cropped","Long Sleeve"],"Fabric":["Cotton","Cotton Blend","Organic Cotton"],"Fit":["Regular","Relaxed"]},"benefits":["Premium Fabrics","Custom Fits","Multiple Styles","Bulk Production"]}'::jsonb,0 from public.categories where slug='womens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Crew Neck','crew-neck',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'V-Neck','v-neck',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Oversized','oversized',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Long Sleeve','long-sleeve',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Cropped','cropped',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Leggings','leggings',id,'/images/mens/denim.jpg','Performance Meets Everyday Style','High-quality leggings in various fabrics, compression levels and designs, tailored for global markets.','{"filters":{"Style":["Full Length","7/8 Length","High Waist","Seamless","Printed"],"Fabric":["Nylon Blend","Polyester Blend"],"Fit":["Compression","Regular"]},"benefits":["Performance Fabrics","Custom Designs","Size Range","Bulk Supply"]}'::jsonb,1 from public.categories where slug='womens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Full Length','full-length',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='leggings' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'High Waist','high-waist',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='leggings' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Seamless','seamless',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='leggings' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Printed','printed',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='leggings' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select '7/8 Length','7-8-length',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='leggings' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Sweaters','sweaters',id,'/images/mens/sweater.jpg','Comfort, Style and Craftsmanship','Premium sweater collections in a variety of knits, yarns and silhouettes, designed for global fashion brands.','{"filters":{"Style":["Crew Neck","V-Neck","Turtle Neck","Cardigan","Oversized"],"Fabric":["Cotton Knit","Wool Blend","Acrylic"],"Fit":["Regular","Relaxed"]},"benefits":["Premium Yarns","Various Knits","Custom Designs","Bulk Production"]}'::jsonb,2 from public.categories where slug='womens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Crew Neck','crew-neck',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Turtle Neck','turtle-neck',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Cardigan','cardigan',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Oversized','oversized',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'V-Neck','v-neck',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Lingerie','lingerie',id,'/images/fabric.jpg','Elegant Designs, Superior Quality','Comprehensive lingerie solutions with premium fabrics, comfort-focused designs and reliable production.','{"filters":{"Style":["Bras","Briefs","Sets","Shapewear","Sleepwear"],"Fabric":["Cotton Blend","Stretch Lace","Microfiber"],"Fit":["Regular","Support"]},"benefits":["Premium Fabrics","Custom Designs","Size Range","Quality Assurance"]}'::jsonb,3 from public.categories where slug='womens' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Bras','bras',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='lingerie' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Briefs','briefs',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='lingerie' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Sets','sets',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='lingerie' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Shapewear','shapewear',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='lingerie' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Sleepwear','sleepwear',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='womens' and root.parent_id is null and c.slug='lingerie' on conflict do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WTS-001','Classic T-Shirt',leaf.id,'Custom Fabric & Fit','/images/catalog/womens-classic.jpg','','#e4e0d6','{"Style":"Crew Neck","Fabric":"Cotton","Fit":"Regular"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WTS-002','V-Neck T-Shirt',leaf.id,'Multiple Fabric Options','/images/catalog/womens-v-neck.jpg','','#252627','{"Style":"V-Neck","Fabric":"Cotton Blend","Fit":"Regular"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='V-Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WTS-003','Oversized T-Shirt',leaf.id,'Trendy & Comfortable','/images/catalog/womens-oversized.jpg','','#c5baaa','{"Style":"Oversized","Fabric":"Organic Cotton","Fit":"Relaxed"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Oversized' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WTS-004','Long Sleeve T-Shirt',leaf.id,'All Season Solution','/images/catalog/womens-long-sleeve.jpg','','#999b99','{"Style":"Long Sleeve","Fabric":"Cotton Blend","Fit":"Regular"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Long Sleeve' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WTS-005','Cropped T-Shirt',leaf.id,'A Modern Essential','/images/catalog/womens-cropped.jpg','','#d9c5b6','{"Style":"Cropped","Fabric":"Cotton","Fit":"Relaxed"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Cropped' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLG-001','Full Length Leggings',leaf.id,'Premium Stretch','','','#27292b','{"Style":"Full Length","Fabric":"Nylon Blend","Fit":"Compression"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='leggings' and leaf.name='Full Length' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLG-002','High Waist Leggings',leaf.id,'Support & Comfort','','','#343533','{"Style":"High Waist","Fabric":"Nylon Blend","Fit":"Compression"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='leggings' and leaf.name='High Waist' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLG-003','Seamless Leggings',leaf.id,'Modern & Sleek','','','#4a4c47','{"Style":"Seamless","Fabric":"Polyester Blend","Fit":"Regular"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='leggings' and leaf.name='Seamless' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLG-004','Printed Leggings',leaf.id,'Custom Prints','','','#393b39','{"Style":"Printed","Fabric":"Polyester Blend","Fit":"Regular"}'::jsonb,'print',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='leggings' and leaf.name='Printed' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLG-005','7/8 Leggings',leaf.id,'Flexible Everyday Fit','','','#817b74','{"Style":"7/8 Length","Fabric":"Nylon Blend","Fit":"Compression"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='leggings' and leaf.name='7/8 Length' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WSW-001','Crew Neck Sweater',leaf.id,'Classic & Versatile','','','#dcd3c2','{"Style":"Crew Neck","Fabric":"Cotton Knit","Fit":"Regular"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WSW-002','Turtle Neck Sweater',leaf.id,'Warm & Stylish','','','#939893','{"Style":"Turtle Neck","Fabric":"Wool Blend","Fit":"Regular"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Turtle Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WSW-003','Cardigan Sweater',leaf.id,'Modern Silhouette','','','#9a8170','{"Style":"Cardigan","Fabric":"Wool Blend","Fit":"Regular"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Cardigan' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WSW-004','Oversized Sweater',leaf.id,'Comfort Fit','','','#292d2c','{"Style":"Oversized","Fabric":"Acrylic","Fit":"Relaxed"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Oversized' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WSW-005','V-Neck Sweater',leaf.id,'Soft Seasonal Layers','','','#b1a191','{"Style":"V-Neck","Fabric":"Cotton Knit","Fit":"Regular"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='sweaters' and leaf.name='V-Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLN-001','Bra',leaf.id,'Support & Comfort','','','#c5a991','{"Style":"Bras","Fabric":"Microfiber","Fit":"Support"}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='lingerie' and leaf.name='Bras' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLN-002','Briefs',leaf.id,'Everyday Essentials','','','#d4bba6','{"Style":"Briefs","Fabric":"Cotton Blend","Fit":"Regular"}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='lingerie' and leaf.name='Briefs' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLN-003','Lingerie Set',leaf.id,'Elegant & Modern','','','#303030','{"Style":"Sets","Fabric":"Stretch Lace","Fit":"Regular"}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='lingerie' and leaf.name='Sets' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLN-004','Shapewear',leaf.id,'Confidence Fit','','','#bea18a','{"Style":"Shapewear","Fabric":"Microfiber","Fit":"Support"}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='lingerie' and leaf.name='Shapewear' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-WLN-005','Sleepwear',leaf.id,'Soft Everyday Comfort','','','#b6a19c','{"Style":"Sleepwear","Fabric":"Cotton Blend","Fit":"Relaxed"}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='womens' and root.parent_id is null and sub.slug='lingerie' and leaf.name='Sleepwear' on conflict(sku) do nothing;
insert into public.categories(name,slug,parent_id) values('Girls','girls',null) on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'T-Shirts','t-shirts',id,'/images/mens/sweater.jpg','Comfort for brighter tomorrows','High-quality girls’ t-shirts designed for comfort, durability and everyday style. From basics to trendy styles, we source across global markets.','{"filters":{"Style":["Graphic","Ruffle Sleeve","Striped","Printed","Basic","Long Sleeve"],"Fabric":["Cotton Jersey","Cotton Blend","Organic Cotton","Cotton Modal"],"Color":["White","Pink","Black","Lilac","Blue"],"Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]},"benefits":["Premium Sourcing","Quality Manufacturing","Ethical Production","Global Supply Chain"],"banner":"Custom Designs & Private Label","bannerCopy":"From fabric sourcing to final production, we bring your girls’ t-shirt collections to life.","bannerImage":"/images/fabric.jpg"}'::jsonb,0 from public.categories where slug='girls' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Graphic','graphic',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Ruffle Sleeve','ruffle-sleeve',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Striped','striped',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Printed','printed',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Basic','basic',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Long Sleeve','long-sleeve',c.id,5 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='t-shirts' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Denim','denim',id,'/images/mens/sweater.jpg','Built for big adventures','Stylish, durable and comfortable denim for every occasion. We source a wide range of girls’ denim styles with consistent quality and fit.','{"filters":{"Style":["Jeans","Wide Leg","Jacket","Skirt","Dungaree","Shorts"],"Fabric":["Stretch Denim","Comfort Stretch","Classic Denim","Denim Cotton","Soft Denim"],"Color":["Blue","Black","White","Grey"],"Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]},"benefits":["Premium Sourcing","Quality Manufacturing","Ethical Production","Global Supply Chain"],"banner":"Multiple Washes & Custom Finishes","bannerCopy":"From fabric development to final production, we deliver high-quality denim styles for global brands.","bannerImage":"/images/mens/denim.jpg"}'::jsonb,1 from public.categories where slug='girls' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Jeans','jeans',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Wide Leg','wide-leg',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Jacket','jacket',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Skirt','skirt',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Dungaree','dungaree',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Shorts','shorts',c.id,5 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='denim' on conflict do nothing;
insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select 'Sweaters','sweaters',id,'/images/mens/sweater.jpg','Warmth for brighter days','Soft, stylish and comfortable sweaters designed for every season. We source a wide range of knits with quality fabrics and reliable production.','{"filters":{"Style":["Crew Neck","Cardigan","Turtleneck","Cable Knit","Hooded","Printed"],"Fabric":["Cotton Knit","Knit Blend","Rib Knit","Wool Blend","Cotton Blend"],"Color":["Pink","White","Grey","Black","Lilac"],"Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]},"benefits":["Premium Sourcing","Quality Manufacturing","Ethical Production","Global Supply Chain"],"banner":"Seasonal Collections & Custom Knits","bannerCopy":"From yarn sourcing to finished production, we create high-quality sweater collections for global markets.","bannerImage":"/images/mens/sweater.jpg"}'::jsonb,2 from public.categories where slug='girls' and parent_id is null on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Crew Neck','crew-neck',c.id,0 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Cardigan','cardigan',c.id,1 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Turtleneck','turtleneck',c.id,2 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Cable Knit','cable-knit',c.id,3 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Hooded','hooded',c.id,4 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.categories(name,slug,parent_id,sort_order) select 'Printed','printed',c.id,5 from public.categories c join public.categories root on c.parent_id=root.id where root.slug='girls' and root.parent_id is null and c.slug='sweaters' on conflict do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GTS-001','Graphic T-Shirt',leaf.id,'Cotton Jersey','','White','#e6e3d9','{"Style":"Graphic","Fabric":"Cotton Jersey","Color":"White","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Graphic' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GTS-002','Ruffle Sleeve Tee',leaf.id,'Cotton Blend','','Pink','#d797b0','{"Style":"Ruffle Sleeve","Fabric":"Cotton Blend","Color":"Pink","Age Group":["5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Ruffle Sleeve' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GTS-003','Striped T-Shirt',leaf.id,'Organic Cotton','','Blue','#6992ad','{"Style":"Striped","Fabric":"Organic Cotton","Color":"Blue","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'stripes',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Striped' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GTS-004','Printed T-Shirt',leaf.id,'Cotton Jersey','','White','#e6e3d9','{"Style":"Printed","Fabric":"Cotton Jersey","Color":"White","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'print',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Printed' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GTS-005','Basic Tee',leaf.id,'Cotton Blend','','Lilac','#b8a5cc','{"Style":"Basic","Fabric":"Cotton Blend","Color":"Lilac","Age Group":["2–4 years","5–7 years","8–10 years"]}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Basic' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GTS-006','Long Sleeve Tee',leaf.id,'Cotton Modal','','Black','#33363a','{"Style":"Long Sleeve","Fabric":"Cotton Modal","Color":"Black","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='t-shirts' and leaf.name='Long Sleeve' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GDN-001','Denim Jeans',leaf.id,'Stretch Denim','','Blue','#6992ad','{"Style":"Jeans","Fabric":"Stretch Denim","Color":"Blue","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='denim' and leaf.name='Jeans' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GDN-002','Wide Leg Jeans',leaf.id,'Comfort Stretch','','Blue','#6992ad','{"Style":"Wide Leg","Fabric":"Comfort Stretch","Color":"Blue","Age Group":["5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='denim' and leaf.name='Wide Leg' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GDN-003','Denim Jacket',leaf.id,'Classic Denim','','Blue','#6992ad','{"Style":"Jacket","Fabric":"Classic Denim","Color":"Blue","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='denim' and leaf.name='Jacket' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GDN-004','Denim Skirt',leaf.id,'Denim Cotton','','Blue','#6992ad','{"Style":"Skirt","Fabric":"Denim Cotton","Color":"Blue","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='denim' and leaf.name='Skirt' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GDN-005','Overall / Dungaree',leaf.id,'Soft Denim','','Blue','#6992ad','{"Style":"Dungaree","Fabric":"Soft Denim","Color":"Blue","Age Group":["2–4 years","5–7 years","8–10 years"]}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='denim' and leaf.name='Dungaree' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GDN-006','Denim Shorts',leaf.id,'Stretch Denim','','Blue','#6992ad','{"Style":"Shorts","Fabric":"Stretch Denim","Color":"Blue","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='denim' and leaf.name='Shorts' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GSW-001','Crew Neck Sweater',leaf.id,'Cotton Knit','','Pink','#d797b0','{"Style":"Crew Neck","Fabric":"Cotton Knit","Color":"Pink","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',0 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Crew Neck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GSW-002','Cardigan',leaf.id,'Knit Blend','','Pink','#d797b0','{"Style":"Cardigan","Fabric":"Knit Blend","Color":"Pink","Age Group":["5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',1 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Cardigan' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GSW-003','Turtleneck Sweater',leaf.id,'Rib Knit','','Grey','#9ba0a0','{"Style":"Turtleneck","Fabric":"Rib Knit","Color":"Grey","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',2 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Turtleneck' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GSW-004','Cable Knit Sweater',leaf.id,'Wool Blend','','White','#e6e3d9','{"Style":"Cable Knit","Fabric":"Wool Blend","Color":"White","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'plain',3 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Cable Knit' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GSW-005','Hooded Sweater',leaf.id,'Cotton Blend','','Grey','#9ba0a0','{"Style":"Hooded","Fabric":"Cotton Blend","Color":"Grey","Age Group":["2–4 years","5–7 years","8–10 years"]}'::jsonb,'plain',4 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Hooded' on conflict(sku) do nothing;
insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select 'RS-GSW-006','Printed Sweater',leaf.id,'Cotton Knit','','Pink','#d797b0','{"Style":"Printed","Fabric":"Cotton Knit","Color":"Pink","Age Group":["2–4 years","5–7 years","8–10 years","11–14 years"]}'::jsonb,'print',5 from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug='girls' and root.parent_id is null and sub.slug='sweaters' and leaf.name='Printed' on conflict(sku) do nothing;
insert into public.partners(name,sort_order) select 'PRIMARK',0 where not exists(select 1 from public.partners where name='PRIMARK');
insert into public.partners(name,sort_order) select 'sallinggroup',1 where not exists(select 1 from public.partners where name='sallinggroup');
insert into public.partners(name,sort_order) select 'Kmart',2 where not exists(select 1 from public.partners where name='Kmart');
insert into public.partners(name,sort_order) select 'Nutmeg',3 where not exists(select 1 from public.partners where name='Nutmeg');
insert into public.partners(name,sort_order) select 'MATALAN',4 where not exists(select 1 from public.partners where name='MATALAN');
insert into public.partners(name,sort_order) select 'TALLY',5 where not exists(select 1 from public.partners where name='TALLY');
insert into public.partners(name,sort_order) select 'next',6 where not exists(select 1 from public.partners where name='next');
insert into public.partners(name,sort_order) select 'H&M',7 where not exists(select 1 from public.partners where name='H&M');
-- Certifications intentionally start empty. Add only verified certifications in the admin.


-- 003-enquiries.sql
-- Contact enquiries may not have an agreed quantity yet.

alter table public.quote_requests alter column quantity drop not null;


-- 004-category-roots.sql
-- Allow administrators to create top-level categories as well as groups/subcategories.
-- Existing records and root URL names are preserved.

do $$ declare constraint_name text; begin
  for constraint_name in
    select conname from pg_constraint
    where conrelid = 'public.categories'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%parent_id%'
  loop
    execute format('alter table public.categories drop constraint %I', constraint_name);
  end loop;
end; $$;
alter table public.categories add constraint categories_depth_parent_check
  check ((parent_id is null and level = 1) or (parent_id is not null and level > 1));


-- 005-home-slider.sql
-- Keep existing banners. Home supports multiple slides; other pages retain one banner.

alter table public.hero_banners add column slot text not null default 'single';
alter table public.hero_banners add column sort_order integer not null default 0 check (sort_order >= 0);
alter table public.hero_banners drop constraint hero_banners_page_key;
alter table public.hero_banners add constraint hero_banners_page_slot_key unique(page, slot);
alter table public.hero_banners add constraint hero_banners_single_page_check check (page = 'home' or slot = 'single');


-- 006-product-skus.sql

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


-- 007-media-cleanup.sql

-- Only removed/replaced website images are queued. Existing unrelated uploads are untouched.
create table public.media_cleanup_queue (
  asset_id uuid primary key references public.media_assets(id) on delete cascade,
  queued_at timestamptz not null default now(),
  last_error text not null default ''
);
alter table public.media_cleanup_queue enable row level security;
revoke all on public.media_cleanup_queue from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname='anon') then revoke all on public.media_cleanup_queue from anon; end if;
  if exists(select 1 from pg_roles where rolname='authenticated') then revoke all on public.media_cleanup_queue from authenticated; end if;
end; $$;

create function public.queue_removed_media() returns trigger language plpgsql set search_path='' as $$
declare previous jsonb; current_row jsonb; image text;
begin
  previous := to_jsonb(old);
  if TG_OP='UPDATE' then current_row := to_jsonb(new); else current_row := '{}'::jsonb; end if;
  foreach image in array array[previous->>'image_url', previous->>'hero_image_url',previous->'config'->>'bannerImage'] loop
    if image is not null and image <> '' and not (
      image = coalesce(current_row->>'image_url','') or image = coalesce(current_row->>'hero_image_url','')
      or image = coalesce(current_row->'config'->>'bannerImage','')
    ) then
      insert into public.media_cleanup_queue(asset_id) select id from public.media_assets where url=image
      on conflict(asset_id) do nothing;
    end if;
  end loop;
  if TG_OP='DELETE' then return old; end if;
  return new;
end; $$;
create trigger products_media_cleanup after update or delete on public.products for each row execute function public.queue_removed_media();
create trigger banners_media_cleanup after update or delete on public.hero_banners for each row execute function public.queue_removed_media();
create trigger partners_media_cleanup after update or delete on public.partners for each row execute function public.queue_removed_media();
create trigger categories_media_cleanup after update or delete on public.categories for each row execute function public.queue_removed_media();

create function public.media_is_referenced(asset_url text) returns boolean language plpgsql stable set search_path='' as $$
declare legacy_table text; found boolean;
begin
  if exists(select 1 from public.products where image_url=asset_url)
    or exists(select 1 from public.hero_banners where image_url=asset_url)
    or exists(select 1 from public.partners where image_url=asset_url)
    or exists(select 1 from public.categories where hero_image_url=asset_url or config->>'bannerImage'=asset_url)
    then return true; end if;
  -- Upgraded installations may still have older content records using an image.
  foreach legacy_table in array array['homepage_categories','certifications'] loop
    if to_regclass('public.'||legacy_table) is not null then
      execute format('select exists(select 1 from public.%I where image_url=$1)',legacy_table) into found using asset_url;
      if found then return true; end if;
    end if;
  end loop;
  if to_regclass('public.site_settings') is not null then
    execute 'select exists(select 1 from public.site_settings where value->>''image_url''=$1)' into found using asset_url;
    if found then return true; end if;
  end if;
  return false;
end; $$;
revoke all on function public.queue_removed_media(), public.media_is_referenced(text) from public;


-- Current Supabase storage setup. Run after npm run db:migrate; local storage does not need this.
-- Image files are public; uploads go through the backend.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site-media', 'site-media', true, 5242880, array['image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;


create policy roann_media_read on storage.objects for select to anon, authenticated
using (bucket_id = 'site-media');
-- Deliberately no authenticated INSERT/UPDATE/DELETE policies:
-- only the server service role writes, so every upload passes Sharp compression.
-- Keep this bucket dedicated to website images; never put private quote data in it.


create table public.schema_migrations (name text primary key, applied_at timestamptz not null default now());
revoke all on public.schema_migrations from public, anon, authenticated;
alter table public.schema_migrations enable row level security;
insert into public.schema_migrations(name) values ('001-schema.sql'), ('002-seed.sql'), ('003-enquiries.sql'), ('004-category-roots.sql'), ('005-home-slider.sql'), ('006-product-skus.sql'), ('007-media-cleanup.sql');
commit;
