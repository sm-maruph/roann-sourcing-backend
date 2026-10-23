# Roann Sourcing backend

The admin at `/admin/login` manages hero banner images, products, categories and subcategories, partner logos, and customer enquiries. The website reads the catalog, banners and partners from this API. Product quote and contact forms submit directly to the private admin inbox.

## Database and storage setup

**New Supabase project:** run the complete [`supabase/setup.sql`](supabase/setup.sql) file once in Supabase SQL Editor. It includes tables, constraints, category triggers, indexes, RLS, starter catalog, the public `site-media` storage bucket, and the migration ledger. Do not run historical `supabase/01-schema.sql`, `03-seed.sql` or `04-admin.sql`; they describe the previous Supabase Auth implementation.

**Existing installation:** run `npm run db:migrate` instead. It preserves existing data, handles the original Supabase Auth schema and applies the enquiry quantity and category-root migrations. Then run [`supabase/02-storage.sql`](supabase/02-storage.sql) in SQL Editor. Back up your database before upgrading. Old CEO, homepage collection and certification tables may remain in an upgraded database, but this application no longer manages them.

The combined installer is for a fresh database and deliberately fails rather than replacing existing tables. `npm run sql:generate` rebuilds it from the canonical migrations and storage SQL. `npm run seed:generate` regenerates the starter catalog from the frontend content; regenerate the combined SQL afterwards if you change the seed.

## Configuration and custom login

1. Copy `.env.example` to `.env` in `backend`.
2. Set `DATABASE_URL` to your Supabase direct or session-pooler PostgreSQL URL. Connect as the application table owner (normally `postgres`) so the server can access the RLS-protected tables. Use your provider's TLS configuration.
3. Set `STORAGE_DRIVER=supabase`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_STORAGE_BUCKET=site-media`. These belong only on the server.
4. Run `npm ci`. If you already ran the combined SQL installer, the migration ledger is populated; `npm run db:migrate` safely skips it. On ordinary PostgreSQL use migrations and `STORAGE_DRIVER=local` instead of the Supabase installer.
5. Set your own `ADMIN_EMAIL` and a unique `ADMIN_PASSWORD` of at least 12 characters. Run `npm run admin:create`, then remove `ADMIN_PASSWORD` from `.env`.
6. Development: run `npm run dev` in both `backend` and `frontend`; visit `http://localhost:5173/admin/login`. Production: build with `npm run build` in `frontend`, run `npm start` in `backend`, and visit `/admin/login` on the backend host. The backend serves both the built website and API.

Authentication uses the custom **`public.admin_users` user table**, independently of `auth.users`. Passwords are salted scrypt hashes. Login issues a random token valid for eight hours; only its SHA-256 hash is stored in `admin_sessions`. Logout revokes the session. Re-running `admin:create` rotates the account password and revokes its sessions. There is no public registration or default password. The browser holds the token in tab-scoped session storage.

Use HTTPS, set `ALLOWED_ORIGINS`, and set `TRUST_PROXY` to your deployment's actual proxy hop count. Production rate limits currently use process memory; multiple server instances need a shared store.

## Managing the website

- **Page banners:** home supports multiple slides. Use Manage homepage slider to select multiple image files together, preview them, move slides up/down, remove slides, or hide them. Save homepage slider commits the full ordered list atomically. Up to 30 images are supported. All saved banners have small previews in the admin list. Other pages retain one banner each; saving a new banner for those pages replaces their image. Edit slider on any home row opens the same complete homepage editor. Set page banner opens the single-image editor for other pages and excludes home from its page selector. The homepage, About, Compliance, Men’s, Women’s and Girls’ heroes use these images. A page banner applies across that collection's categories. Disable/remove it to use the local or category fallback image. Banner text remains part of the website design.
- **Categories & subcategories:** the fixed collection roots are Men’s, Women’s and Girls’. Select a root when creating a category; select a category when creating a subcategory. Maximum depth is collection → category → subcategory. Products can be assigned to either a group or subcategory. Subcategories appear as catalog filters. Existing parents and root slugs are fixed to preserve the hierarchy. Delete child categories/products before deleting a referenced category.
- **Products:** set SKU, name, category/subcategory, product image, attributes and visibility. Upload directly in the editor, wait for the preview, then save. Each product has one color. Use separate product records for color variants.
- **Partners:** create a partner, upload its logo, optionally add an HTTPS website link, and set display order and visibility. Active partners appear on the homepage.
- **Quote requests:** public product quotes and Contact enquiries appear here. Review customer details, update status and save private notes. General enquiries may have no quantity or product. Product enquiries store authoritative product details at submission; snapshots survive product deletion. Submitting a form does not send an email notification or an automated reply.
- **Images:** upload directly inside the relevant editor. Remove image and save to detach it and delete its Storage file if unused elsewhere. Deleting records, replacing images, and saving removed homepage slides also delete unused managed files. Media Library has been removed.

Saved changes appear after refreshing the public page. Catalog API errors show a retry state; an empty catalog displays a contact link. Other pages retain their local banner design if the content API is unavailable. The CEO portrait and other editorial website content remain in the frontend.

## Tables and endpoints

| Table | Purpose |
| --- | --- |
| `admin_users` | Custom administrator credentials |
| `admin_sessions` | Hashed, expiring session tokens |
| `hero_banners` | Multiple ordered homepage slides; one banner per other page |
| `categories` | Collection/category/subcategory tree |
| `products` | Products, category references and image URLs |
| `partners` | Partner logos and links |
| `quote_requests` | Private customer enquiries, status and notes |
| `media_assets` | Uploaded image metadata |
| `schema_migrations` | Applied migration ledger |

Public endpoints: `GET /api/health`, `GET /api/config`, `GET /api/content`, `GET /api/catalog/:audience` (`mens`, `womens`, `girls`), `POST /api/quotes`.

Authentication: `POST /api/auth/login` with `{ "email": "your@email.com", "password": "your password" }`; `POST /api/auth/logout`. Send the returned token as `Authorization: Bearer TOKEN` on protected requests.

Protected endpoints: `GET /api/admin/me`; CRUD at `/api/admin/hero_banners`, `/categories`, `/products`, `/partners` (under `/api/admin`); `GET /api/admin/quotes?page=1&status=new`; `PATCH /api/admin/quotes/:id` with `status` and `admin_notes`; `POST /api/admin/uploads` with multipart fields `image` and `kind` (`hero`, `category`, `product`, `logo`); `POST /api/admin/uploads/remove` for discarding unused staged uploads.

CRUD uses GET/POST on the collection and PUT/DELETE on `/:id`. PUT accepts the complete editable record. Request schemas are in `src/validation.js`.

## Storage and access

`site-media` contains only public website images in `hero/`, `category/`, `product/` and `logo/` paths. Images up to 12 MB and 40 megapixels are decoded, rotated, resized and converted to WebP on the backend. The bucket accepts WebP up to 5 MB. The server storage key uploads files after custom login validation; browser Supabase roles receive no write policy. Application tables have RLS enabled and browser privileges revoked. Quote details and credential hashes never belong in the public bucket.

This follows [Supabase's storage access control model](https://supabase.com/docs/guides/storage/security/access-control). Custom session tokens are checked by Express; they are not Supabase Auth tokens.

For local file storage set `STORAGE_DRIVER=local` and `MEDIA_DIRECTORY` to a persistent directory. Files are served under `/media/`. Moving hosts requires both a PostgreSQL export and a separate file export; update stored image URL prefixes when moving from Supabase to local storage. Never expose database URLs or service role keys in frontend environment variables.

## Verification

`npm test` runs isolated PGlite database/API tests. Build the frontend and run `npm run test:ui` for browser verification (requires Playwright in the frontend and Microsoft Edge). Tests do not load production credentials. Supabase network uploads and deployment TLS/proxy settings still require verification on your host. This work prepares the SQL and application; it does not apply changes to your live database.

For the category workbench update on an existing database, run `npm run db:migrate` or run `db/004-category-roots.sql` in Supabase SQL Editor. It permits new top-level categories without replacing existing records. Do not rerun the fresh installer.

For the homepage slider update, run `npm run db:migrate` or run `db/005-home-slider.sql` once in Supabase SQL Editor. This retains all existing images and changes uniqueness to allow multiple homepage slides. The homepage advances every five seconds with previous/next, dot and pause/play controls; reduced-motion users start paused. The fresh-project installer includes this migration.

`PUT /api/admin/home-slides` accepts `{ "slides": [{ "id": "existing-uuid-if-kept", "image_url": "/images/hero.jpg", "is_active": true }] }`. Omit id for a new slide. The array order determines display order; omitted existing homepage slides are removed. Changes are transactional and leave other page banners untouched. Browser upload remains one request per selected image, followed by one save for the complete slider.

## Automatic product SKUs

The product editor shows a read-only SKU preview after selecting a category/group/subcategory. The selected subcategory resolves to its parent group?s series: Men?s ? T-Shirts ? Crew Neck uses `RS-MTS-001`, `RS-MTS-002`, etc. Existing series are continued from the largest saved number. Other starter codes include MDN, MTR, MSW, MBX, WTS, WLG, WLN, WSW, GTS, GDN and GSW. New category/group names derive an uppercase code from their URL names.

`006-product-skus.sql` adds a private counter table and database trigger. Counters allocate numbers atomically when a product is inserted, continue across product deletion, and preserve existing SKUs on edits. The preview does not reserve a number; another saved product can advance it. Product POST/PUT requests cannot override the SKU. Existing product identifiers are preserved. Run `npm run db:migrate` for existing installations; the fresh installer includes the migration.

## Image removal and Storage cleanup

`007-media-cleanup.sql` installs a private deletion queue and triggers for products, banners, partners and categories. The queue captures removed/replaced URLs only; existing unrelated uploads are not swept. After each saved change, the API checks references across all managed image fields (including category banner configuration and legacy content tables), removes unused files through the Storage driver, then deletes their media metadata. Shared images remain until their final saved reference is removed. Local `/images/` assets and third-party URLs without managed upload metadata are not deleted.

If Storage is unavailable, the queue persists and the running backend retries every 30 seconds and on startup. Storage removal is idempotent; metadata is kept until success. Upload editors also request cleanup of unused temporary uploads on closing. Removing a saved image takes effect after Save, so Cancel keeps existing content intact. `POST /api/admin/uploads/remove` accepts `{ "url": "managed-upload-url" }` and skips images still referenced by saved content. The `media_assets` table remains as internal upload metadata; it is not a library UI.

Storage deletion uses the official [Supabase remove API](https://supabase.com/docs/reference/javascript/storage-from-remove). Database/API and browser tests verify local file removal, shared-image protection, image replacement, homepage slide removal and retries. These tests do not delete production images.

## Administration dashboard

The Overview screen reads `GET /api/admin/dashboard` (custom admin session required). It shows live product totals and visibility, top-level category/group/subcategory counts, partner totals, homepage/banner counts, customer request totals and status counts, unique enquiry email counts, seven days of daily enquiry activity, product distribution by top-level category, and recent products/requests. Charts use actual counts, including zero values. Enquiry day boundaries and dates use Asia/Dhaka. The dashboard reloads on opening Overview and supports a manual refresh button; it does not poll continuously.

The administration UI uses a consistent navy, sage, lavender and warm-neutral palette, responsive navigation, shared form/dialog styling, visible focus states, and the existing product/category/banner/quote workflows. No database migration is required for the dashboard endpoint.

## Quote request inbox

The redesigned inbox displays each request's original received date and time (including seconds) in Asia/Dhaka, with GMT+6 explicitly labelled. The detail panel separately labels the last-updated time; updating status or notes does not change the original requested time. Select a request in the inbox to review its customer, company, email, quantity, product and requirements.

`GET /api/admin/quotes/summary` returns total/new/reviewing/responded/closed/today counts across all requests; today's boundary uses Asia/Dhaka. `GET /api/admin/quotes` supports `page`, `status`, `q` (customer/email/company/product/SKU, up to 200 characters) and `sort=newest|oldest`. Search is parameterized and treats wildcard characters literally. Status and private note updates retain the existing PATCH endpoint. The frontend includes search, status filtering, chronological ordering, refresh, pagination and mobile layouts. No database migration is required.

## Admin branding, loading and exit confirmation

The admin sidebar, login and loading views reuse the actual Roann logo from the public site. The initial bundle/session/login transitions show a branded loading screen. Dashboard, product, category, banner, partner and quote requests use layout-shaped shimmer skeletons while their data requests are pending. No artificial loading delay is added, and reduced-motion preferences disable the shimmer/pulse/dialog motion.

Website/reference links and the normal Back button show a small animated Leave admin confirmation. Stay keeps the current tab and unsaved editor state; Leave follows the original destination or returns to the prior page. Links intended for a new tab still open a new tab after confirmation. Leaving the workspace does not sign the administrator out. Refresh, address-bar navigation and closing the browser/tab use the browser-native confirmation because a custom modal cannot replace those browser-controlled prompts; see [MDN beforeunload](https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeunload_event). Browser history markers are preserved across session checks and login/logout to avoid repeatedly adding guard entries.

Browser tests hold actual API responses to verify the loading screen and skeletons for every tab, and verify exit cancellation, confirmed website navigation, confirmed Back navigation and preservation of an unsaved product draft. No new SQL migration is needed.
