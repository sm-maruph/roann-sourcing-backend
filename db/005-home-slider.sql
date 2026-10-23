-- Keep existing banners. Home supports multiple slides; other pages retain one banner.
begin;
alter table public.hero_banners add column slot text not null default 'single';
alter table public.hero_banners add column sort_order integer not null default 0 check (sort_order >= 0);
alter table public.hero_banners drop constraint hero_banners_page_key;
alter table public.hero_banners add constraint hero_banners_page_slot_key unique(page, slot);
alter table public.hero_banners add constraint hero_banners_single_page_check check (page = 'home' or slot = 'single');
commit;
