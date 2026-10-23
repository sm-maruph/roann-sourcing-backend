import 'dotenv/config';
import pg from 'pg';
import { readFile } from 'node:fs/promises';
if (!process.env.DATABASE_URL) throw new Error('Set DATABASE_URL');
const client = new pg.Client({connectionString:process.env.DATABASE_URL});
await client.connect();
try {
  await client.query('select pg_advisory_lock(78132401)');
  await client.query('create table if not exists public.schema_migrations (name text primary key, applied_at timestamptz not null default now())');
  const legacy = await client.query("select 1 from information_schema.columns where table_schema='public' and table_name='admin_users' and column_name='user_id'");
  if (legacy.rowCount) {
    await client.query('begin');
    try {
      await client.query(await readFile(new URL('../db/000-upgrade-legacy.sql',import.meta.url),'utf8'));
      await client.query("insert into public.schema_migrations(name) values('001-schema.sql') on conflict do nothing");
      await client.query('commit');
      console.log('Upgraded legacy Supabase admin authentication; content preserved.');
    } catch (error) { await client.query('rollback'); throw error; }
  }
  for (const name of ['001-schema.sql','002-seed.sql','003-enquiries.sql','004-category-roots.sql','005-home-slider.sql','006-product-skus.sql','007-media-cleanup.sql']) {
    if ((await client.query('select name from public.schema_migrations where name=$1',[name])).rowCount) continue;
    const sql = await readFile(new URL(`../db/${name}`,import.meta.url),'utf8');
    await client.query('begin');
    try {
      await client.query(sql.replace(/^begin;\s*$/gmi,'').replace(/^commit;\s*$/gmi,''));
      await client.query('insert into public.schema_migrations(name) values($1)',[name]);
      await client.query('commit');
      console.log(`Applied ${name}`);
    } catch (error) { await client.query('rollback'); throw error; }
  }
} finally { await client.end(); }
