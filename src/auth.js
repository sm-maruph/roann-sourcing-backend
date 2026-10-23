import { randomBytes, scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
const derive = promisify(scrypt);
export async function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const key = await derive(password, salt, 64);
  return `scrypt:${salt}:${key.toString('hex')}`;
}
export async function verifyPassword(password, encoded) {
  const [,salt,hex] = encoded.split(':');
  const key = await derive(password, salt, 64);
  const expected = Buffer.from(hex, 'hex');
  return expected.length === key.length && timingSafeEqual(expected, key);
}
export const tokenHash = token => createHash('sha256').update(token).digest('hex');
export function createAuth(pool) {
  return {
    async login(email, password) {
      const {rows} = await pool.query('select id, email, password_hash from public.admin_users where email = $1', [email.toLowerCase()]);
      const user = rows[0];
      // Same expensive check for unknown accounts.
      const valid = await verifyPassword(password, user?.password_hash || `scrypt:${'0'.repeat(32)}:${'0'.repeat(128)}`);
      if (!user || !valid) return null;
      const token = randomBytes(32).toString('base64url');
      await pool.query('delete from public.admin_sessions where expires_at <= now()');
      await pool.query("insert into public.admin_sessions(token_hash, admin_id, expires_at) values($1,$2,now() + interval '8 hours')", [tokenHash(token),user.id]);
      return {token, email:user.email, expiresIn:28800};
    },
    async getUser(token) {
      if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
      return (await pool.query('select a.id, a.email from public.admin_users a join public.admin_sessions s on s.admin_id = a.id where s.token_hash = $1 and s.expires_at > now()', [tokenHash(token)])).rows[0] || null;
    },
    async logout(token) { await pool.query('delete from public.admin_sessions where token_hash = $1', [tokenHash(token)]); }
  };
}
