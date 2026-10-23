-- Only for the original Supabase schema with admin_users.user_id.
-- Content, quotes, media rows and files are preserved. Recreate custom admin accounts afterwards.
-- Supabase Auth accounts remain untouched; old Supabase admin membership is replaced.
do $$ declare p record; begin
  for p in select tablename, policyname from pg_policies where schemaname='public'
    and tablename in ('admin_users','site_settings','hero_banners','homepage_categories','partners','certifications','categories','products','quote_requests','media_assets') loop
    execute format('drop policy %I on public.%I',p.policyname,p.tablename);
  end loop;
end; $$;
drop function public.is_admin();
drop table public.admin_users;
create table public.admin_users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check(email = lower(email) and length(email) <= 200),
  password_hash text not null, created_at timestamptz not null default now()
);
create table public.admin_sessions (
  token_hash text primary key, admin_id uuid not null references public.admin_users(id) on delete cascade,
  expires_at timestamptz not null
);
create index admin_sessions_expiry on public.admin_sessions(expires_at);
-- Old uploader IDs belong to Supabase Auth rather than the new custom admin accounts.
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid='public.media_assets'::regclass and contype='f'
    and confrelid='auth.users'::regclass loop
    execute format('alter table public.media_assets drop constraint %I',c.conname);
  end loop;
end; $$;
update public.media_assets set uploaded_by=null;
alter table public.media_assets add constraint media_assets_uploaded_by_fkey foreign key(uploaded_by) references public.admin_users(id) on delete set null;
do $$ declare t text; begin
  foreach t in array array['admin_users','admin_sessions','site_settings','hero_banners','homepage_categories','partners','certifications','categories','products','quote_requests','media_assets'] loop
    execute format('revoke all on public.%I from public, anon, authenticated',t);
    execute format('alter table public.%I enable row level security',t);
  end loop;
end; $$;
create index if not exists quote_requests_created on public.quote_requests(created_at desc);
