import { mkdir, writeFile, unlink } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { createClient } from '@supabase/supabase-js';
export function createSupabaseStorage({url, key, bucket = 'site-media'}) {
  if (!url || !key) throw new Error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY for Supabase file storage');
  const client = createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  return {async upload(path, buffer) {
    const {error} = await client.storage.from(bucket).upload(path,buffer,{contentType:'image/webp',cacheControl:'31536000',upsert:false});
    if (error) throw error;
    return client.storage.from(bucket).getPublicUrl(path).data.publicUrl;
  }, async remove(path) {
    const {error} = await client.storage.from(bucket).remove([path]);
    if (error) throw error;
  }};
}
export function createStorage(root) {
  const absoluteRoot = resolve(root);
  const safePath = path => {
    if (!/^(hero|category|product|ceo|logo|certification)\/[a-f0-9-]+\.webp$/.test(path)) throw new Error('Invalid media path');
    return resolve(absoluteRoot, path);
  };
  return {root:absoluteRoot, async upload(path, buffer) {
    const target = safePath(path);
    await mkdir(dirname(target), {recursive:true});
    await writeFile(target, buffer, {flag:'wx'});
    return `/media/${path}`;
  }, async remove(path) {
    try { await unlink(safePath(path)); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }};
}
