import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { PGlite } from '@electric-sql/pglite';
import sharp from 'sharp';
import { createApp } from '../src/app.js';
import { createDatabase } from '../src/database.js';
import { createAuth, hashPassword } from '../src/auth.js';
import { createStorage } from '../src/storage.js';

// This isolated test deliberately does not load backend/.env.
const requireFrontend = createRequire(new URL('../../frontend/package.json', import.meta.url));
const { chromium } = requireFrontend('playwright');
const engine = new PGlite();
const pool = { query: (sql, values) => engine.query(sql, values) };
const uploadDirectory = await mkdtemp(join(tmpdir(), 'roann-admin-ui-'));
let server, browser;
try {
  await engine.exec(await readFile(new URL('../db/001-schema.sql', import.meta.url), 'utf8'));
  await engine.exec(await readFile(new URL('../db/005-home-slider.sql', import.meta.url), 'utf8'));
  await engine.exec(await readFile(new URL('../db/004-category-roots.sql', import.meta.url), 'utf8'));
  await engine.exec(await readFile(new URL('../db/003-enquiries.sql', import.meta.url), 'utf8'));
  await engine.exec(await readFile(new URL('../db/002-seed.sql', import.meta.url), 'utf8'));
  await engine.exec(await readFile(new URL('../db/006-product-skus.sql', import.meta.url), 'utf8'));
  await engine.exec(await readFile(new URL('../db/007-media-cleanup.sql', import.meta.url), 'utf8'));
  const email = 'ui-test@example.com', password = 'Isolated UI test password 2026';
  await pool.query('insert into admin_users(email,password_hash) values($1,$2)', [email, await hashPassword(password)]);
  const auth = createAuth(pool);
  server = createApp({ db: createDatabase(pool), auth, storage: createStorage(uploadDirectory), config: { origins: [] }, limits: false }).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ channel: 'msedge', headless: true });
  const page = await browser.newPage();
  page.setDefaultTimeout(10000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('dialog', dialog => dialog.accept());
  await page.goto(base + '/admin');
  await page.getByRole('heading', { name: 'Admin sign in' }).waitFor();
  assert.equal(new URL(page.url()).pathname, '/admin/login');
  assert.equal((await fetch(base + '/api/admin/products')).status, 401);
  await page.getByLabel('Email address').fill(email);
  await page.getByLabel('Password', { exact: true }).fill('incorrect-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.getByRole('alert').filter({ hasText: 'Invalid email or password' }).waitFor();
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.getByRole('heading', { name: 'Welcome to your dashboard' }).waitFor();
  assert.equal(new URL(page.url()).pathname, '/admin');
  assert.ok(!(await page.evaluate(() => JSON.stringify({ ...sessionStorage, ...localStorage }))).includes(password));
  assert.ok(await page.getByText('Saved changes appear on the public website', { exact: false }).isVisible());

  await page.locator('.dashboard-stats').getByText('78',{exact:true}).waitFor();
  assert.equal(await page.locator('.dashboard-stat').count(),4);
  const refreshedDashboard=page.waitForResponse(response=>response.url().endsWith('/api/admin/dashboard')&&response.status()===200);
  await page.getByRole('button',{name:'Refresh dashboard',exact:true}).click();
  await refreshedDashboard;
  await page.locator('.dashboard-footer').waitFor();
  await page.locator('.dashboard-stats').getByText('78',{exact:true}).waitFor();
  for (const [width,height] of [[1440,900],[1366,768],[1280,720],[1024,768]]) {
    await page.setViewportSize({width,height});
    const layout=await page.evaluate(()=>({height:document.documentElement.scrollHeight,width:document.documentElement.scrollWidth,footer:document.querySelector('.dashboard-footer').getBoundingClientRect().bottom}));
    assert.ok(layout.height<=height+1,`Overview fits ${width}x${height} vertically: ${JSON.stringify(layout)}`);
    assert.ok(layout.width<=width,`Overview fits ${width}x${height} horizontally`);
    assert.ok(layout.footer<=height,`Overview footer fits ${width}x${height}`);
    const overflow=await page.locator('.dashboard-panel,.dashboard-quick-panel').evaluateAll(panels=>panels.map(panel=>({name:panel.querySelector('h2')?.textContent,x:panel.scrollWidth-panel.clientWidth,y:panel.scrollHeight-panel.clientHeight,overflow:getComputedStyle(panel).overflow})).filter(panel=>panel.x>1||panel.y>1||['auto','scroll'].includes(panel.overflow)));
    assert.deepEqual(overflow,[],`Overview panels have no overflow at ${width}x${height}: ${JSON.stringify(overflow)}`);

  }
  await page.setViewportSize({width:1366,height:768});
  await page.screenshot({path:new URL('../../admin-dashboard-desktop.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  const desktopType=await page.locator('.dashboard-heading h1').evaluate(element=>getComputedStyle(element).fontSize);
  assert.equal(desktopType,'22px');
  for(const width of [320,375,390,768,900]) {
    await page.setViewportSize({width,height:812});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Dashboard fits mobile/tablet ${width}`);
  }
  await page.setViewportSize({width:375,height:812});
  await page.getByRole('button',{name:'Open navigation',exact:true}).click();
  await page.getByRole('navigation',{name:'Admin navigation'}).getByRole('button',{name:'Products',exact:true}).waitFor();
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Expanded mobile navigation fits viewport');
  await page.getByRole('button',{name:'Close navigation',exact:true}).click();
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Dashboard fits mobile');
  await page.screenshot({path:new URL('../../admin-dashboard-mobile.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  await page.setViewportSize({width:1280,height:900});

  assert.ok((await page.locator('.admin-workspace-brand img').getAttribute('src')).includes('WhatsApp_Image_2026-10-08'));
  await page.getByRole('link',{name:'View website',exact:true}).click();
  const exitDialog=page.getByRole('dialog',{name:'Leave the admin panel?',exact:true});
  await exitDialog.waitFor();
  await page.screenshot({path:new URL('../../admin-exit-warning.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),animations:'disabled'});
  await exitDialog.getByRole('button',{name:'Stay in admin',exact:true}).click();
  await exitDialog.waitFor({state:'hidden'});
  assert.equal(new URL(page.url()).pathname,'/admin');
  await page.evaluate(()=>history.back());
  await exitDialog.waitFor();
  await exitDialog.getByRole('button',{name:'Stay in admin',exact:true}).click();
  await exitDialog.waitFor({state:'hidden'});
  assert.equal(new URL(page.url()).pathname,'/admin');
  await page.getByRole('link',{name:'View website',exact:true}).click();
  await exitDialog.getByRole('button',{name:'Leave admin',exact:true}).click();
  await page.waitForURL(base+'/');
  await page.goBack();
  await page.getByRole('heading',{name:'Welcome to your dashboard'}).waitFor();
  console.log('Sign-in, invalid credentials and access checks passed.');

  let releaseIdentity;
  const identityGate=new Promise(resolve=>{releaseIdentity=resolve;});
  await page.route('**/api/admin/me',async route=>{await identityGate;await route.continue();});
  await page.reload();
  await page.locator('.admin-route-loader').waitFor();
  await page.locator('.admin-route-loader').getByAltText('Roann Sourcing',{exact:true}).waitFor();
  await page.screenshot({path:new URL('../../admin-loading-screen.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')});
  releaseIdentity();
  await page.getByRole('heading', { name: 'Welcome to your dashboard' }).waitFor();
  await page.unroute('**/api/admin/me');


  const nav = page.getByRole('navigation', { name: 'Admin navigation' });
  for(const [tab,pattern,label] of [
    ['Products','**/api/admin/products','Loading products'],
    ['Categories & subcategories','**/api/admin/categories','Loading categories'],
    ['Page banners','**/api/admin/hero_banners','Loading page banners'],
    ['Partners','**/api/admin/partners','Loading partners'],
    ['Quote requests','**/api/admin/quotes?*','Loading quote requests'],
    ['Overview','**/api/admin/dashboard','Loading overview'],
  ]) {
    let release;
    const gate=new Promise(resolve=>{release=resolve;});
    await page.route(pattern,async route=>{await gate;await route.continue();});
    try {
      await nav.getByRole('button',{name:tab,exact:true}).click();
      await page.getByRole('status',{name:label,exact:true}).waitFor();
      assert.ok(await page.locator('.admin-skeleton-block').count()>0);
      await page.locator('.admin-skeleton-brand').getByAltText('Roann Sourcing',{exact:true}).waitFor();
    } finally {release();}
    await page.locator('.admin-skeleton').waitFor({state:'hidden'});
    await page.unroute(pattern);
  }

  const backPage=await browser.newPage();
  backPage.on('pageerror',error=>errors.push(error.message));
  backPage.on('dialog',dialog=>dialog.accept());
  await backPage.goto(base+'/about');
  await backPage.goto(base+'/admin/login');
  await backPage.getByLabel('Email address').fill(email);
  await backPage.getByLabel('Password',{exact:true}).fill(password);
  await backPage.getByRole('button',{name:'Sign in',exact:true}).click();
  await backPage.getByRole('heading',{name:'Welcome to your dashboard'}).waitFor();
  await backPage.getByRole('navigation',{name:'Admin navigation'}).getByRole('button',{name:'Products',exact:true}).click();
  await backPage.getByRole('button',{name:'Add product',exact:true}).click();
  await backPage.getByRole('dialog',{name:'Add product',exact:true}).getByLabel('Product name',{exact:true}).fill('Unsaved draft preserved');
  await backPage.evaluate(()=>history.back());
  await backPage.getByRole('dialog',{name:'Leave the admin panel?',exact:true}).getByRole('button',{name:'Stay in admin',exact:true}).click();
  assert.equal(await backPage.getByRole('dialog',{name:'Add product',exact:true}).getByLabel('Product name',{exact:true}).inputValue(),'Unsaved draft preserved');
  await backPage.getByRole('dialog',{name:'Add product',exact:true}).getByRole('button',{name:'Cancel',exact:true}).click();
  await backPage.evaluate(()=>history.back());
  await backPage.getByRole('dialog',{name:'Leave the admin panel?',exact:true}).getByRole('button',{name:'Leave admin',exact:true}).click();
  await backPage.waitForURL(base+'/about');
  await backPage.close();
  console.log('Actual logo, branded loading, skeletons for every tab, exit links and Back confirmation passed.');

  await nav.getByRole('button', { name: 'Products', exact: true }).click();
  await page.getByRole('button', { name: 'Add product', exact: true }).click();
  const dialog = page.getByRole('dialog');
  assert.ok(await dialog.getByLabel('SKU', {exact:true}).getAttribute('readonly') !== null);
  await dialog.getByLabel('Product name', { exact: true }).fill('Admin UI test product');
  const { rows: categoryRows } = await pool.query("select id,parent_id from categories where level = 2 order by id limit 1");
  assert.ok(await dialog.getByLabel('Group', {exact:true}).isDisabled());
  assert.ok(await dialog.getByLabel('Subcategory', {exact:true}).isDisabled());
  await dialog.getByLabel('Category', { exact: true }).selectOption(categoryRows[0].parent_id);
  const groupIds = await dialog.getByLabel('Group', {exact:true}).locator('option').evaluateAll(options => options.map(option => option.value).filter(Boolean));
  const expectedGroups = (await pool.query('select id from categories where parent_id=$1',[categoryRows[0].parent_id])).rows.map(row => row.id);
  assert.deepEqual(groupIds.sort(),expectedGroups.sort());
  await dialog.getByLabel('Group', {exact:true}).selectOption(categoryRows[0].id);
  const childRows = (await pool.query('select id from categories where parent_id=$1 order by id',[categoryRows[0].id])).rows;
  if (childRows.length) await dialog.getByLabel('Subcategory', {exact:true}).selectOption(childRows[0].id);
  const rootOptions = await dialog.getByLabel('Category', {exact:true}).locator('option').evaluateAll(options => options.map(option => option.value).filter(Boolean));
  const otherRoot = rootOptions.find(id => id !== categoryRows[0].parent_id);
  await dialog.getByLabel('Category', {exact:true}).selectOption(otherRoot);
  assert.equal(await dialog.getByLabel('Group', {exact:true}).inputValue(),'');
  assert.ok(await dialog.getByLabel('Subcategory', {exact:true}).isDisabled());
  await dialog.getByLabel('Category', {exact:true}).selectOption(categoryRows[0].parent_id);
  await dialog.getByLabel('Group', {exact:true}).selectOption(categoryRows[0].id);
  if (childRows.length) await dialog.getByLabel('Subcategory', {exact:true}).selectOption(childRows[0].id);
  await page.waitForFunction(() => /^RS-[A-Z0-9]+-\d+$/.test(document.querySelector('#admin-field-sku').value));
  const productSku = await dialog.getByLabel('SKU', {exact:true}).inputValue();
  await dialog.getByRole('button', { name: 'Add attribute' }).click();
  await dialog.getByLabel('Attribute 1', { exact: true }).fill('Fabric');
  await dialog.getByLabel('Values 1', { exact: true }).fill('Cotton');
  await dialog.getByRole('button', { name: 'Save changes' }).click();
  await page.getByRole('status').filter({ hasText: 'Changes saved.' }).waitFor();
  await page.getByLabel('Search products').fill('Admin UI test product');
  let row = page.getByRole('article').filter({ hasText: productSku });
  await row.waitFor();
  assert.deepEqual(await row.locator('.admin-product-classification dt').allTextContents(),['Category','Subgroup','Subcategory']);
  await row.getByRole('button',{name:'View Admin UI test product',exact:true}).click();
  await page.getByRole('dialog').getByRole('heading',{name:'Admin UI test product',exact:true}).waitFor();
  await page.getByRole('dialog').getByText(productSku,{exact:true}).waitFor();
  await page.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();
  await page.setViewportSize({width:375,height:812});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Product cards fit mobile');
  await page.setViewportSize({width:1280,height:900});

  await row.getByRole('button', { name: 'Edit', exact: true }).click();
  assert.equal(await page.getByRole('dialog').getByLabel('Category', {exact:true}).inputValue(),categoryRows[0].parent_id);
  assert.equal(await page.getByRole('dialog').getByLabel('Group', {exact:true}).inputValue(),categoryRows[0].id);
  if(childRows.length) assert.equal(await page.getByRole('dialog').getByLabel('Subcategory', {exact:true}).inputValue(),childRows[0].id);
  await page.getByRole('dialog').getByLabel('Product name', { exact: true }).fill('Admin UI updated product');
  await page.getByRole('dialog').getByRole('button', { name: 'Save changes' }).click();
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  await page.getByLabel('Search products').fill(productSku);
  row = page.getByRole('article').filter({ hasText: productSku });
  await row.getByText('Admin UI updated product', { exact: true }).waitFor();
  assert.equal((await pool.query('select attributes from products where sku=$1',[productSku])).rows[0].attributes.Fabric, 'Cotton');
  await row.getByRole('button', { name: 'Delete', exact: true }).click();
  await page.getByRole('button', { name: 'Confirm delete' }).click();
  await page.getByRole('status').filter({ hasText: 'Record deleted.' }).waitFor();
  assert.equal((await pool.query('select count(*) from products where sku=$1',[productSku])).rows[0].count, 0);
  await page.getByLabel('Search products').fill('');
  await page.locator('.admin-product-card').first().waitFor();
  await page.getByLabel('Sort products', {exact:true}).selectOption('name-desc');
  const names=await page.locator('.admin-product-body h2').allTextContents();
  assert.deepEqual(names,[...names].sort((a,b)=>b.localeCompare(a,undefined,{numeric:true,sensitivity:'base'})));
  await page.getByLabel('Sort products', {exact:true}).selectOption('sku-desc');
  const greatestSku=(await pool.query('select sku from products order by sku desc limit 1')).rows[0].sku;
  assert.equal(await page.locator('.admin-product-sku').first().textContent(),greatestSku);
  await page.getByRole('button',{name:'Next',exact:true}).click();
  await page.getByLabel('Sort products', {exact:true}).selectOption('category');
  await page.getByText('Page 1 of 4',{exact:true}).waitFor();
  await page.getByLabel('Sort products', {exact:true}).selectOption('order');
  assert.ok(await page.getByLabel('Subgroup',{exact:true}).isDisabled());
  assert.ok(await page.getByLabel('Subcategory',{exact:true}).isDisabled());
  const filterGroup=(await pool.query("select g.id,g.parent_id from categories g join categories r on g.parent_id=r.id where r.slug='mens' and g.slug='t-shirts'")).rows[0];
  await page.getByLabel('Category',{exact:true}).selectOption(filterGroup.parent_id);
  const dropdownGroups=await page.getByLabel('Subgroup',{exact:true}).locator('option').evaluateAll(options=>options.map(option=>option.value).filter(Boolean));
  const allowedGroups=(await pool.query('select id from categories where parent_id=$1',[filterGroup.parent_id])).rows.map(row=>row.id);
  assert.deepEqual(dropdownGroups.sort(),allowedGroups.sort());
  await page.getByLabel('Subgroup',{exact:true}).selectOption(filterGroup.id);
  const filterLeaf=(await pool.query('select id,name from categories where parent_id=$1 order by name limit 1',[filterGroup.id])).rows[0];
  await page.getByLabel('Subcategory',{exact:true}).selectOption(filterLeaf.id);
  const expectedLeafCount=(await pool.query('select count(*)::int as total from products where category_id=$1',[filterLeaf.id])).rows[0].total;
  assert.equal(await page.locator('.admin-product-card').count(),expectedLeafCount);
  await page.getByText(`${expectedLeafCount} matching products`,{exact:true}).waitFor();
  await page.getByLabel('Search products').fill('nonexistent product name for filter test');
  await page.getByRole('heading',{name:'No matching products',exact:true}).waitFor();
  await page.getByLabel('Search products').fill('');
  await page.getByLabel('Category',{exact:true}).selectOption('');
  assert.equal(await page.getByLabel('Subgroup',{exact:true}).inputValue(),'');
  assert.equal(await page.getByLabel('Subcategory',{exact:true}).inputValue(),'');
  assert.ok(await page.getByLabel('Subgroup',{exact:true}).isDisabled());
  assert.equal(await page.locator('.admin-product-card').count(),20);


  await page.setViewportSize({width:1440,height:1000});
  await page.screenshot({path:new URL('../../admin-products-desktop.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')});
  await page.setViewportSize({width:375,height:812});
  await page.screenshot({path:new URL('../../admin-products-mobile.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')});
  await page.setViewportSize({width:1280,height:900});
  console.log('Product create/edit/delete passed.');

  await nav.getByRole('button', { name: 'Categories & subcategories', exact: true }).click();
  await page.getByRole('heading', { name: 'Categories', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Add Category', exact: true }).click();
  await page.getByRole('dialog').getByLabel('Category name').fill('UI Accessories');
  await page.getByRole('dialog').getByRole('button', { name: 'Save category' }).click();
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  await page.getByRole('heading', { name: 'UI Accessories', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Add Group', exact: true }).click();
  await page.getByLabel('Group name', { exact: true }).fill('Bags');
  await page.locator('.category-quick-add').getByRole('button', { name: 'Add', exact: true }).click();
  await page.getByLabel('Add subcategory to Bags').fill('Tote');
  await page.locator('.category-quick-add').getByRole('button', { name: 'Add', exact: true }).click();
  await page.getByRole('button', { name: 'Tote', exact: true }).waitFor();
  assert.equal((await pool.query("select level from categories where slug = 'tote'")).rows[0].level,3);
  await page.getByRole('button', { name: 'Tote', exact: true }).click();
  await page.getByRole('dialog').getByLabel('Name', { exact: true }).fill('Canvas Tote');
  await page.getByRole('dialog').getByRole('button', { name: 'Save changes' }).click();
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Canvas Tote', exact: true }).waitFor();
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.screenshot({path: new URL('../../admin-categories-desktop.png', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  await page.setViewportSize({ width: 375, height: 812 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Category manager fits mobile');
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.getByRole('button', { name: 'Delete subcategory Canvas Tote' }).click();
  await page.getByRole('button', { name: 'Confirm delete' }).click();
  await page.getByRole('button', { name: 'Delete group Bags' }).click();
  await page.getByRole('button', { name: 'Confirm delete' }).click();
  await page.locator('.category-summary-actions').getByRole('button', { name: 'Delete', exact: true }).click();
  await page.getByRole('button', { name: 'Confirm delete' }).click();
  await page.getByRole('heading', { name: 'UI Accessories', exact: true }).waitFor({state:'hidden'});
  console.log('Category hierarchy create/edit/delete and mobile layout passed.');

  await fetch(base + '/api/quotes', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'Test Buyer', email: 'buyer@example.com', quantity: 50, product_name: 'UI quote test', message: 'Sample enquiry' }) });
  await pool.query("update quote_requests set created_at='2026-10-20T02:15:30Z'::timestamptz where product_name='UI quote test'");
  await nav.getByRole('button', { name: 'Quote requests', exact: true }).click();
  await page.getByRole('heading', { name: 'UI quote test' }).waitFor();
  const requestedTimestamp=await page.locator('.quote-received time').textContent();
  assert.ok(requestedTimestamp.includes('20 Oct 2026'));
  assert.ok(requestedTimestamp.toLowerCase().includes('08:15:30 am'));
  assert.equal(await page.locator('.quote-stats>div').count(),4);
  await page.getByLabel('Search quote requests',{exact:true}).fill('nobody matches this search');
  await page.getByRole('heading',{name:'No quote requests found.',exact:true}).waitFor();
  await page.getByLabel('Search quote requests',{exact:true}).fill('Test Buyer');
  await page.getByRole('heading',{name:'UI quote test'}).waitFor();
  await page.getByLabel('Search quote requests',{exact:true}).fill('');
  await page.getByRole('heading',{name:'UI quote test'}).waitFor();
  await page.setViewportSize({width:1440,height:1000});
  await page.screenshot({path:new URL('../../admin-quotes-desktop.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  for(const width of [320,375,768]) {
    await page.setViewportSize({width,height:812});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Quote inbox fits ${width}px`);
  }
  await page.setViewportSize({width:375,height:812});
  await page.screenshot({path:new URL('../../admin-quotes-mobile.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  await page.setViewportSize({width:1280,height:900});

  await page.getByLabel('Status', { exact: true }).selectOption('reviewing');
  await page.getByLabel('Private notes').fill('Follow up with buyer');
  await page.getByRole('button', { name: 'Save request' }).click();
  await page.getByRole('status').filter({ hasText: 'Request updated.' }).waitFor();
  assert.equal((await pool.query("select status from quote_requests where product_name = 'UI quote test'")).rows[0].status, 'reviewing');

  assert.equal(await nav.getByRole('button', { name: 'Media library', exact: true }).count(),0);
  const buffer = await sharp({ create: { width: 32, height: 32, channels: 3, background: '#ffffff' } }).png().toBuffer();

  await nav.getByRole('button', { name: 'Partners', exact: true }).click();
  await page.getByRole('button', { name: 'Add partner', exact: true }).click();
  await page.getByRole('dialog').getByLabel('Name', { exact: true }).fill('Browser test partner');
  await page.getByRole('dialog').getByLabel('Upload image', { exact: true }).setInputFiles({ name: 'partner.png', mimeType: 'image/png', buffer });
  await page.getByRole('dialog').getByAltText('Selected image preview').waitFor();
  await page.getByRole('dialog').getByRole('button', { name: 'Save changes' }).click();
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  const publicPage = await browser.newPage();
  publicPage.on('pageerror', error => errors.push(error.message));
  await publicPage.goto(base + '/');
  await publicPage.getByAltText('Browser test partner').waitFor();
  const partnerUrl=(await pool.query("select image_url from partners where name='Browser test partner'")).rows[0].image_url;
  assert.equal((await fetch(base+partnerUrl)).status,200);
  assert.equal(await page.locator('.partner-stat').count(),3);
  await page.getByLabel('Search partners',{exact:true}).fill('Browser test partner');
  assert.equal(await page.locator('.partner-card').count(),1);
  await page.getByLabel('Visibility',{exact:true}).selectOption('hidden');
  await page.getByRole('heading',{name:'No matching partners',exact:true}).waitFor();
  await page.getByLabel('Visibility',{exact:true}).selectOption('all');
  await page.getByLabel('Search partners',{exact:true}).fill('');
  await page.getByLabel('Sort partners',{exact:true}).selectOption('name');
  const partnerNames=await page.locator('.partner-card h2').allTextContents();
  assert.deepEqual(partnerNames,[...partnerNames].sort((a,b)=>a.localeCompare(b)));
  await page.setViewportSize({width:1440,height:1000});
  await page.screenshot({path:new URL('../../admin-partners-desktop.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  for(const width of [320,375,768]) {
    await page.setViewportSize({width,height:812});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Partners fit ${width}px`);
  }
  await page.setViewportSize({width:375,height:812});
  await page.screenshot({path:new URL('../../admin-partners-mobile.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  await page.setViewportSize({width:1280,height:900});

  await page.getByRole('article',{name:'Browser test partner',exact:true}).getByRole('button',{name:'Edit',exact:true}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Remove image',exact:true}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Save changes',exact:true}).click();
  await page.getByRole('dialog').waitFor({state:'hidden'});
  assert.equal((await fetch(base+partnerUrl)).headers.get('content-type')?.includes('image/'),false);
  await page.getByRole('article',{name:'Browser test partner',exact:true}).getByRole('button',{name:'Delete',exact:true}).click();
  await page.getByRole('button',{name:'Confirm delete',exact:true}).click();
  await page.getByRole('article',{name:'Browser test partner',exact:true}).waitFor({state:'hidden'});


  await nav.getByRole('button', { name: 'Page banners', exact: true }).click();
  await page.getByRole('button', { name: 'Manage homepage slider', exact: true }).click();
  const sliderEditor = page.getByRole('dialog');
  assert.equal(await sliderEditor.getByLabel('Select homepage images').getAttribute('multiple'),'');
  await sliderEditor.getByLabel('Select homepage images').setInputFiles([
    {name:'slide-one.png',mimeType:'image/png',buffer},
    {name:'slide-two.png',mimeType:'image/png',buffer},
  ]);
  await sliderEditor.getByAltText('Homepage slide 3 preview').waitFor();
  await sliderEditor.getByRole('button', {name:'Move slide 3 up'}).click();
  await sliderEditor.getByRole('button', {name:'Save homepage slider'}).click();
  await page.getByRole('dialog').waitFor({state:'hidden'});
  await page.getByRole('status').filter({hasText:'Homepage slider saved.'}).waitFor();
  assert.equal(await page.getByAltText('home banner preview', {exact:true}).count(),3);
  assert.equal(await page.locator('.banner-page-card').count(),5);
  await page.getByRole('article',{name:'About us banner',exact:true}).getByRole('button',{name:'Edit banner',exact:true}).click();
  await page.getByRole('dialog').getByLabel('Image URL',{exact:true}).fill('/images/textile.jpg');
  await page.getByRole('dialog').getByRole('button',{name:'Save changes',exact:true}).click();
  await page.getByRole('dialog').waitFor({state:'hidden'});
  await page.getByRole('status').filter({hasText:'Banner saved.'}).waitFor();
  assert.equal(await page.getByAltText('about banner preview',{exact:true}).getAttribute('src'),'/images/textile.jpg');
  await page.setViewportSize({width:1440,height:1000});
  await page.screenshot({path:new URL('../../admin-banners-desktop.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  await page.setViewportSize({width:375,height:812});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Banner manager fits mobile');
  await page.screenshot({path:new URL('../../admin-banners-mobile.png',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'),fullPage:true});
  await page.setViewportSize({width:1280,height:900});
  await page.getByRole('button',{name:'Delete About us banner',exact:true}).click();
  await page.getByRole('button',{name:'Confirm delete',exact:true}).click();
  await page.getByRole('article',{name:'About us banner',exact:true}).getByRole('button',{name:'Add banner',exact:true}).waitFor();
  await page.getByRole('article',{name:'About us banner',exact:true}).getByRole('button',{name:'Add banner',exact:true}).click();
  assert.equal(await page.getByRole('dialog').getByLabel('Page',{exact:true}).inputValue(),'about');
  await page.getByRole('dialog').getByLabel('Image URL',{exact:true}).fill('/images/fabric.jpg');
  await page.getByRole('dialog').getByRole('button',{name:'Save changes',exact:true}).click();
  await page.getByRole('dialog').waitFor({state:'hidden'});
  await page.getByRole('status').filter({hasText:'Banner saved.'}).waitFor();
  assert.equal(await page.getByAltText('home banner preview', {exact:true}).count(),3);

  await page.getByRole('button', {name:'Set page banner',exact:true}).click();
  assert.equal(await page.getByRole('dialog').getByLabel('Page', {exact:true}).locator('option[value="home"]').count(),0);
  assert.equal(await page.getByRole('dialog').getByLabel('Upload image', {exact:true}).getAttribute('multiple'),null);
  await page.getByRole('dialog').getByRole('button', {name:'Cancel',exact:true}).click();
  await publicPage.reload();
  await publicPage.getByRole('button', {name:'Next slide',exact:true}).waitFor();
  await publicPage.getByRole('button', {name:'Pause slideshow',exact:true}).click();
  await publicPage.getByRole('button', {name:'Next slide',exact:true}).click();
  assert.equal(await publicPage.getByRole('button', {name:'Show slide 2',exact:true}).getAttribute('aria-pressed'),'true');
  assert.ok((await publicPage.locator('.hero-slide.is-active').getAttribute('style')).includes('/media/hero/'));
  await publicPage.getByRole('button', {name:'Previous slide',exact:true}).click();
  assert.equal(await publicPage.getByRole('button', {name:'Show slide 1',exact:true}).getAttribute('aria-pressed'),'true');
  console.log('Homepage slides, slider controls and saved admin thumbnails passed.');

  await publicPage.goto(base + '/mens');
  await publicPage.getByRole('button', { name: 'Request Quote', exact: true }).first().click();
  const quoteForm = publicPage.getByRole('dialog');
  await quoteForm.getByLabel('Your name').fill('Browser quote buyer');
  await quoteForm.getByLabel('Work email').fill('browser@example.com');
  await quoteForm.getByLabel('Quantity (pieces)').fill('200');
  await quoteForm.getByRole('button', { name: 'Send Quote Request' }).click();
  await quoteForm.getByRole('status').filter({ hasText: 'Your quote request has been received' }).waitFor();
  assert.equal((await pool.query("select count(*) from quote_requests where name = 'Browser quote buyer'")).rows[0].count, 1);
  await publicPage.goto(base + '/contact');
  await publicPage.getByLabel('Your name').fill('Browser contact buyer');
  await publicPage.getByLabel('Your email').fill('contact@example.com');
  await publicPage.getByLabel('Subject').fill('General sourcing enquiry');
  await publicPage.getByLabel('Your message').fill('Please contact me about a collection.');
  await publicPage.getByRole('button', { name: 'Send Enquiry' }).click();
  await publicPage.getByRole('status').filter({ hasText: 'Your enquiry has been received' }).waitFor();
  assert.equal((await pool.query("select quantity from quote_requests where name = 'Browser contact buyer'")).rows[0].quantity, null);
  await publicPage.close();

  await page.setViewportSize({ width: 375, height: 812 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Admin fits mobile');
  const token = await page.evaluate(() => sessionStorage.getItem('roann-admin-session'));
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await page.getByRole('heading', { name: 'Admin sign in' }).waitFor();
  assert.equal((await fetch(base + '/api/admin/me', { headers: { Authorization: `Bearer ${token}` } })).status, 401);
  assert.equal(await page.evaluate(() => sessionStorage.getItem('roann-admin-session')), null);

  await page.getByLabel('Email address').fill(email);
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.getByRole('heading', { name: 'Welcome to your dashboard' }).waitFor();
  await auth.logout(await page.evaluate(() => sessionStorage.getItem('roann-admin-session')));
  if(await page.getByRole('button',{name:'Open navigation',exact:true}).isVisible()) await page.getByRole('button',{name:'Open navigation',exact:true}).click();
  await nav.getByRole('button', { name: 'Products', exact: true }).click();
  await page.getByRole('heading', { name: 'Admin sign in' }).waitFor();
  await page.getByRole('status').filter({ hasText: 'Your session has expired.' }).waitFor();
  assert.deepEqual(errors, []);
  console.log('Admin UI passed: login errors, protected routes, session persistence/expiry/logout, product create/edit/delete, category safeguards, quote updates, image uploads, partner publishing, public product quotes, contact enquiries and mobile layout. No live database was used.');
} finally {
  if (browser) await browser.close();
  if (server) await new Promise(resolve => server.close(resolve));
  await engine.close();
  // The target is the exact temporary directory returned by mkdtemp above.
  await rm(uploadDirectory, { recursive: true, force: true });
}
