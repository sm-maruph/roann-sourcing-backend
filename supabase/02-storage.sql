-- Current Supabase storage setup. Run after npm run db:migrate; local storage does not need this.
-- Image files are public; uploads go through the backend.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site-media', 'site-media', true, 5242880, array['image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists roann_media_read on storage.objects;
create policy roann_media_read on storage.objects for select to anon, authenticated
using (bucket_id = 'site-media');
-- Deliberately no authenticated INSERT/UPDATE/DELETE policies:
-- only the server service role writes, so every upload passes Sharp compression.
-- Keep this bucket dedicated to website images; never put private quote data in it.
