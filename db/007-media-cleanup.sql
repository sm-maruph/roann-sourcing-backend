begin;
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
commit;
