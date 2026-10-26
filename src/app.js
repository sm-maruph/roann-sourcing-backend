import { createMediaCleanup } from './media-cleanup.js';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import multer from 'multer';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { schemas, quoteSchema, quoteUpdateSchema, idSchema, loginSchema, homeSlidesSchema, assetUrl } from './validation.js';
import { compressImage } from './images.js';
import { adaptCatalog } from './catalog.js';

function fail(status, message) { return Object.assign(new Error(message), {status}); }
export function checked(result) {
  if (result.error) {
    const status = ['23503','23505','23514','P0001'].includes(result.error.code) ? 409 : 500;
    throw fail(status, status === 409 ? result.error.message : 'Database operation failed. Check backend configuration and migrations.');
  }
  return result.data;
}
async function readAll(db, table, configure = query => query) {
  const rows = [];
  for (let start = 0; ; start += 500) {
    const batch = checked(await configure(db.from(table).select('*')).order('sort_order').order('id').range(start, start + 499));
    rows.push(...batch);
    if (batch.length < 500) return rows;
  }
}
export function createApp({db, config, auth, storage, limits = true}) {
  const app = express();
  const cleanupMedia = createMediaCleanup(db, storage);
  app.locals.cleanupMedia = () => cleanupMedia().catch(() => { console.error('Image cleanup will retry. Check migrations and storage configuration.'); });
  app.disable('x-powered-by');
  app.set('trust proxy', Number(config.trustProxy || 0));
  app.use(helmet({contentSecurityPolicy: {directives: {defaultSrc: ["'self'"], scriptSrc: ["'self'"], styleSrc: ["'self'", "'unsafe-inline'"], imgSrc: ["'self'", 'https:', 'blob:', 'data:'], connectSrc: ["'self'"], upgradeInsecureRequests: null}}}));
  const origins = config.origins || [];
  app.use(cors({origin(origin, callback) { callback(null, !origin || origins.includes(origin)); }}));
  app.use(express.json({limit: '100kb'}));
  if (limits) app.use('/api', rateLimit({windowMs: 60000, limit: 240, standardHeaders: 'draft-8', legacyHeaders: false}));
  app.get('/api/health', (req, res) => res.json({status: 'ok'}));
  app.get('/api/config', (req, res) => res.json({auth: 'custom', loginUrl: '/api/auth/login'}));
  app.get('/api/navigation/categories', async (req, res) => {
    const categories = await readAll(db, 'categories');
    const result = {};
    for (const root of categories.filter(row => row.parent_id === null && row.is_active)) {
      result[root.slug] = {
        name: root.name,
        categories: categories.filter(row => row.parent_id === root.id && row.is_active)
          .map(row => ({
            id: row.slug,
            label: row.name,
            subcategories: categories.filter(child => child.parent_id === row.id && child.is_active)
              .map(child => ({id: child.slug, label: child.name})),
          })),
      };
    }
    res.set('Cache-Control', 'no-store').json(result);
  });
  if (storage.root) app.use('/media', express.static(storage.root, {maxAge:'1y', immutable:true, index:false, dotfiles:'deny'}));
  const loginLimit = limits ? rateLimit({windowMs: 15 * 60000, limit: 10, standardHeaders:'draft-8', legacyHeaders:false}) : (req,res,next) => next();
  app.post('/api/auth/login', loginLimit, async (req,res) => {
    const {email,password} = loginSchema.parse(req.body);
    const session = await auth.login(email,password);
    if (!session) throw fail(401, 'Invalid email or password');
    res.set('Cache-Control','no-store').json(session);
  });
  app.post('/api/auth/logout', async (req,res) => {
    const token = req.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
    if (token) await auth.logout(token);
    res.status(204).end();
  });
  app.get('/api/content', async (req, res) => {
    const results = await Promise.all(['hero_banners', 'partners'].map(table => {
      let query = db.from(table).select('*').eq('is_active', true).order('sort_order').order('id');
      if (table === 'partners') query = query.order('sort_order').order('id');
      return query;
    }));
    const [heroes, partners] = results.map(checked);
    res.set('Cache-Control', 'no-store').json({ heroes, partners });
  });
  app.get('/api/catalog/:audience', async (req, res) => {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(req.params.audience)) throw fail(404, 'Collection not found');
    const results = await Promise.all([readAll(db, 'categories'), readAll(db, 'products', query => query.eq('is_active', true)), db.from('hero_banners').select('*').eq('page', req.params.audience).eq('is_active', true).maybeSingle()]);
    const [categories, products, heroResult] = results;
    const hero = checked(heroResult);
    res.json(adaptCatalog(categories, products, req.params.audience, hero));
  });
  const quoteLimit = limits ? rateLimit({windowMs: 15 * 60000, limit: 10, standardHeaders: 'draft-8', legacyHeaders: false, message: {error: 'Too many requests. Please try again in 15 minutes.'}}) : (req, res, next) => next();
  app.post('/api/quotes', quoteLimit, async (req, res) => {
    const parsed = quoteSchema.parse(req.body);
    if (parsed.website) return res.status(201).json({message: 'Request received'});
    const {website, ...quote} = parsed;
    if (quote.product_id) {
      const product = checked(await db.from('products').select('*').eq('id', quote.product_id).eq('is_active', true).maybeSingle());
      if (!product) throw fail(400, 'This product is no longer available. Refresh the collection.');
      const categories = await readAll(db, 'categories');
      let category = categories.find(item => item.id === product.category_id);
      while (category) {
        if (!category.is_active) throw fail(400, 'This product is no longer available.');
        category = categories.find(item => item.id === category.parent_id);
      }
      quote.product_name = product.name; quote.product_sku = product.sku; quote.color = product.color_name;
    }
    checked(await db.from('quote_requests').insert(quote));
    res.status(201).json({message: 'Thank you. Your quote request has been received.'});
  });

  app.use('/api/admin', async (req, res, next) => {
    const token = req.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
    if (!token) throw fail(401, 'Please sign in');
    const user = await auth.getUser(token);
    if (!user) throw fail(401, 'Your session has expired. Please sign in again.');
    req.user = user;
    res.set('Cache-Control','no-store');
    next();
  });
  app.get('/api/admin/me', (req, res) => res.json({email: req.user.email}));
  app.get('/api/admin/dashboard', async (req, res) => res.json(await db.dashboardStats()));
  app.get('/api/admin/products/sku-preview', async (req, res) => {
    res.json(await db.previewProductSku(idSchema.parse(req.query.category_id)));
  });
  app.put('/api/admin/home-slides', async (req, res) => {
    const {slides} = homeSlidesSchema.parse(req.body);
    const saved = await db.replaceHomeSlides(slides);
    await app.locals.cleanupMedia();
    res.json(saved);
  });
  app.get('/api/admin/quotes/summary', async (req, res) => res.json(await db.quoteSummary()));
  app.get('/api/admin/quotes', async (req, res) => {
    const page = Math.max(1, Math.min(100000, Number.parseInt(req.query.page || '1', 10) || 1));
    if (req.query.status) {
      if (!['new','reviewing','responded','closed'].includes(req.query.status)) throw fail(400, 'Invalid quote status');
    }
    const search = typeof req.query.q === 'string' ? req.query.q.trim() : '';
    if(search.length>200) throw fail(400,'Search must be 200 characters or fewer');
    if(req.query.sort && !['newest','oldest'].includes(req.query.sort)) throw fail(400,'Invalid request order');
    res.json(await db.quoteInbox({page,status:req.query.status||'',search,sort:req.query.sort||'newest'}));
  });
  app.patch('/api/admin/quotes/:id', async (req, res) => {
    const row = checked(await db.from('quote_requests').update(quoteUpdateSchema.parse(req.body)).eq('id', idSchema.parse(req.params.id)).select().maybeSingle());
    if (!row) throw fail(404, 'Quote request not found');
    res.json(row);
  });
  const upload = multer({storage: multer.memoryStorage(), limits: {fileSize: 12 * 1024 * 1024, files: 1, fields: 1}});
  app.post('/api/admin/uploads', upload.single('image'), async (req, res) => {
    if (!req.file) throw fail(400, 'Select an image');
    if (!['hero', 'category', 'product', 'logo'].includes(req.body.kind)) throw fail(400, 'Choose an image type');
    const image = await compressImage(req.file.buffer, req.body.kind);
    const path = `${req.body.kind}/${randomUUID()}.webp`;
    const url = await storage.upload(path, image.buffer);
    try {
      const asset = checked(await db.from('media_assets').insert({path, url, kind: req.body.kind, width: image.width, height: image.height, bytes: image.bytes, uploaded_by: req.user.id}).select().single());
      res.status(201).json(asset);
    } catch (error) { await storage.remove(path).catch(() => {}); throw error; }
  });
  app.post('/api/admin/uploads/remove', async (req, res) => {
    const url = assetUrl.parse(req.body.url);
    const queued = await db.requestMediaCleanup(url);
    await app.locals.cleanupMedia();
    res.json({queued});
  });
  for (const [table, schema] of Object.entries(schemas)) {
    const route = `/api/admin/${table}`;
    app.get(route, async (req, res) => {
      // Stable batches keep large catalogs complete.
      const rows = [];
      for (let start = 0; ; start += 500) {
        const batch = checked(await db.from(table).select('*').order('id').range(start, start + 499));
        rows.push(...batch);
        if (batch.length < 500) break;
      }
      res.json(rows);
    });
    app.post(route, async (req, res) => {
      const value = schema.parse(req.body);
      // Home slides are separate records; other pages replace their single banner.
      let query;
      if (table === 'hero_banners') {
        value.slot = value.page === 'home' ? randomUUID() : 'single';
        query = value.page === 'home' ? db.from(table).insert(value) : db.from(table).upsert(value, {onConflict: 'page,slot'});
      } else query = db.from(table).insert(value);
      const row = checked(await query.select().single());
      await app.locals.cleanupMedia();
      res.status(table === 'hero_banners' && value.page !== 'home' ? 200 : 201).json(row);
    });
    app.put(`${route}/:id`, async (req, res) => {
      const value = schema.parse(req.body);
      if (table === 'hero_banners' && value.page !== 'home') value.slot = 'single';
      const row = checked(await db.from(table).update(value).eq('id', idSchema.parse(req.params.id)).select().maybeSingle());
      if (!row) throw fail(404, 'Record not found');
      await app.locals.cleanupMedia();
      res.json(row);
    });
    app.delete(`${route}/:id`, async (req, res) => {
      checked(await db.from(table).delete().eq('id', idSchema.parse(req.params.id)));
      await app.locals.cleanupMedia();
      res.status(204).end();
    });
  }
  const adminDist = fileURLToPath(new URL('../admin/dist/', import.meta.url));
  if (existsSync(adminDist)) {
    app.use('/admin', express.static(adminDist));
    app.get('/admin/{*path}', (req, res) => res.sendFile(`${adminDist}/index.html`));
    app.get('/admin', (req, res) => res.redirect('/admin/'));
  }
  app.use('/api', (req, res) => res.status(404).json({error:'Endpoint not found'}));
  const frontendDist = fileURLToPath(new URL('../../frontend/dist/', import.meta.url));
  if (existsSync(`${frontendDist}/index.html`)) {
    app.use(express.static(frontendDist));
    app.get('/{*path}', (req, res) => res.sendFile(`${frontendDist}/index.html`));
  }
  app.use((error, req, res, next) => {
    if (error.name === 'ZodError') return res.status(400).json({error: error.issues.map(issue => `${issue.path.join('.')}: ${issue.message}`).join('; ')});
    if (error instanceof multer.MulterError) return res.status(400).json({error: error.code === 'LIMIT_FILE_SIZE' ? 'Images must be 12 MB or smaller' : 'Invalid upload'});
    const status = error.status || 500;
    if (status >= 500) console.error('API error:', error.message);
    res.status(status).json({error: status >= 500 ? 'Server error. Please check configuration or try again.' : error.message});
  });
  return app;
}
