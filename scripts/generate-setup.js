import { readFile, writeFile } from 'node:fs/promises';

const migrations = ['001-schema.sql', '002-seed.sql', '003-enquiries.sql','004-category-roots.sql','005-home-slider.sql','006-product-skus.sql','007-media-cleanup.sql','008-product-sku-reuse.sql'];
const stripTransactions = sql => sql.replace(/^begin;\s*$/gmi, '').replace(/^commit;\s*$/gmi, '');
const sections = [];
for (const file of migrations) sections.push(`-- ${file}\n${stripTransactions(await readFile(new URL(`../db/${file}`, import.meta.url), 'utf8'))}`);
// Fresh installer creates its policy once; the standalone storage script replaces it on upgrades.
sections.push((await readFile(new URL('../supabase/02-storage.sql', import.meta.url), 'utf8')).replace('drop policy if exists roann_media_read on storage.objects;', ''));
sections.push(`create table public.schema_migrations (name text primary key, applied_at timestamptz not null default now());
revoke all on public.schema_migrations from public, anon, authenticated;
alter table public.schema_migrations enable row level security;
insert into public.schema_migrations(name) values ${migrations.map(name => `('${name}')`).join(', ')};`);
await writeFile(new URL('../supabase/setup.sql', import.meta.url), `-- COMPLETE ROANN SOURCING SETUP: run once in Supabase SQL Editor on a fresh project.
-- Existing installation? Use npm run db:migrate instead; never drop existing tables.
-- Custom users: public.admin_users. No Supabase Auth account is required.
-- After setup, provision your own credentials with npm run admin:create.
-- There are no default accounts or passwords. All application access goes through Express.
begin;
${sections.join('\n\n')}
commit;
`);
console.log('Generated supabase/setup.sql: schema, starter catalog, enquiry migration, storage bucket and migration ledger.');
