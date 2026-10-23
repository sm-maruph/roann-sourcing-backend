-- Create this custom administrator, or reset its password if it already exists.
-- Run in Supabase SQL Editor after setup.sql. This does not use Supabase Auth.
-- Temporary password is supplied separately; password_hash must remain a scrypt hash.
begin;
insert into public.admin_users (email, password_hash)
values ('admin@roannsourcing.com', 'scrypt:fe37db2e61f39f0182b89f98e291afe3:d6f1ef9b1f9286db01b484e1fdb88c32c2b17cde7c0442a3012e517ff87a399693c099b1f1c33ad3764ebe389b9ad68f361844f8326732b702fbda4dced10acf')
on conflict (email) do update set password_hash = excluded.password_hash;

-- Revoke any previous sessions for this account.
delete from public.admin_sessions
where admin_id = (select id from public.admin_users where email = 'admin@roannsourcing.com');
commit;
