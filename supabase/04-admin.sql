-- LEGACY SUPABASE SETUP: not used by the current backend. Use db/ and npm run db:migrate.
-- Create your user first: Supabase Dashboard > Authentication > Users > Add user.
-- Replace the email below with that user's email, then run in SQL Editor.
insert into public.admin_users (user_id)
select id from auth.users where lower(email) = lower('REPLACE_WITH_YOUR_ADMIN_EMAIL')
on conflict (user_id) do nothing;

-- Confirm the result; it must show your account before you can use the dashboard.
select u.id, u.email from auth.users u join public.admin_users a on a.user_id = u.id;
