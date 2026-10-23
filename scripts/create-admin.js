import 'dotenv/config';
import pg from 'pg';
import { hashPassword } from '../src/auth.js';
import { z } from 'zod';
const email = z.email().max(200).parse(process.env.ADMIN_EMAIL).toLowerCase();
const password = z.string().min(12).max(1024).parse(process.env.ADMIN_PASSWORD);
if (!process.env.DATABASE_URL) throw new Error('Set DATABASE_URL');
const client = new pg.Client({connectionString:process.env.DATABASE_URL});
await client.connect();
try {
  await client.query('begin');
  const result = await client.query('insert into public.admin_users(email,password_hash) values($1,$2) on conflict(email) do update set password_hash=excluded.password_hash returning id',[email,await hashPassword(password)]);
  await client.query('delete from public.admin_sessions where admin_id=$1',[result.rows[0].id]);
  await client.query('commit');
  console.log('Admin created or password updated; previous sessions revoked. Remove ADMIN_PASSWORD from your environment now.');
} finally { await client.end(); }
