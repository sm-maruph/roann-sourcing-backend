import 'dotenv/config';
import pg from 'pg';
import { createApp } from './app.js';
import { createDatabase } from './database.js';
import { createAuth } from './auth.js';
import { createStorage, createSupabaseStorage } from './storage.js';
if (!process.env.DATABASE_URL) throw new Error('Set DATABASE_URL in backend/.env');
const pool = new pg.Pool({connectionString:process.env.DATABASE_URL, max:10});
await pool.query('select 1 from public.admin_users limit 1');
const config = {origins:(process.env.ALLOWED_ORIGINS || '').split(',').map(value => value.trim()).filter(Boolean), trustProxy:process.env.TRUST_PROXY};
const driver = process.env.STORAGE_DRIVER || 'supabase';
if (!['local','supabase'].includes(driver)) throw new Error('STORAGE_DRIVER must be local or supabase');
const storage = driver === 'supabase'
  ? createSupabaseStorage({url:process.env.SUPABASE_URL,key:process.env.SUPABASE_SERVICE_ROLE_KEY,bucket:process.env.SUPABASE_STORAGE_BUCKET || 'site-media'})
  : createStorage(process.env.MEDIA_DIRECTORY || './uploads');
const app = createApp({db:createDatabase(pool), auth:createAuth(pool), storage, config});
await app.locals.cleanupMedia();
const cleanupTimer = setInterval(() => app.locals.cleanupMedia(), 30000);
cleanupTimer.unref();
const port = Number(process.env.PORT || 4000);
const server = app.listen(port, () => console.log(`Roann backend: http://localhost:${port}`));
for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => { clearInterval(cleanupTimer); server.close(() => pool.end()); });
