import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PGlite } from '@electric-sql/pglite';
import sharp from 'sharp';
import { createDatabase } from '../src/database.js';
import { createAuth, hashPassword, verifyPassword } from '../src/auth.js';
import { createApp } from '../src/app.js';
import { createStorage } from '../src/storage.js';
import { createMediaCleanup } from '../src/media-cleanup.js';
import { compressImage } from '../src/images.js';

test('complete Supabase installer creates scoped tables, bucket and migration ledger', async () => {
  const engine = new PGlite();
  try {
    // Simulate Supabase-owned storage metadata; this verifies SQL, not its network service.
    await engine.exec(`create role anon; create role authenticated;
      create schema storage;
      create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
      create table storage.objects(id uuid primary key, bucket_id text);
      alter table storage.objects enable row level security;`);
    await engine.exec(await readFile(new URL('../supabase/setup.sql', import.meta.url), 'utf8'));
    assert.equal((await engine.query('select count(*) from products')).rows[0].count, 78);
    assert.equal((await engine.query('select count(*) from schema_migrations')).rows[0].count, 7);
    const bucket = (await engine.query("select * from storage.buckets where id='site-media'")).rows[0];
    assert.equal(bucket.public, true);
    assert.deepEqual(bucket.allowed_mime_types, ['image/webp']);
    await engine.exec('set role anon');
    await assert.rejects(engine.query('select * from admin_users'));
    await assert.rejects(engine.query('select * from admin_sessions'));
    await assert.rejects(engine.query('select * from quote_requests'));
    await assert.rejects(engine.query('select * from products'));
  } finally { await engine.close(); }
});

test('portable schema, seed, authentication, API and image upload', async () => {
  const engine = new PGlite();
  const pool = {query:(sql,values) => engine.query(sql,values)};
  const root = await mkdtemp(join(tmpdir(),'roann-test-'));
  let server;
  try {
    await engine.exec(await readFile(new URL('../db/001-schema.sql',import.meta.url),'utf8'));
    await engine.exec(await readFile(new URL('../db/003-enquiries.sql',import.meta.url),'utf8'));
    await engine.exec(await readFile(new URL('../db/004-category-roots.sql',import.meta.url),'utf8'));
    await engine.exec(await readFile(new URL('../db/005-home-slider.sql',import.meta.url),'utf8'));
    const seed = await readFile(new URL('../db/002-seed.sql',import.meta.url),'utf8');
    await engine.exec(seed);
    await engine.exec(seed);
    await engine.exec(await readFile(new URL('../db/006-product-skus.sql',import.meta.url),'utf8'));
    await engine.exec(await readFile(new URL('../db/007-media-cleanup.sql',import.meta.url),'utf8'));
    assert.equal(Number((await pool.query('select count(*) from products')).rows[0].count),78);
    const hash = await hashPassword('A secure test password');
    assert.equal(await verifyPassword('wrong',hash),false);
    await pool.query('insert into admin_users(email,password_hash) values($1,$2)',['admin@example.com',hash]);
    const database = createDatabase(pool);
    server = createApp({db:database,auth:createAuth(pool),storage:createStorage(root),config:{origins:[]},limits:false}).listen(0,'127.0.0.1');
    await new Promise(resolve => server.once('listening',resolve));
    const url = `http://127.0.0.1:${server.address().port}`;
    const request = (path,method='GET',body,token) => fetch(url+path,{method,headers:{'Content-Type':'application/json',...(token ? {Authorization:`Bearer ${token}`} : {})},...(body ? {body:JSON.stringify(body)} : {})});
    assert.equal((await request('/api/admin/products')).status,401);
    assert.equal((await request('/api/admin/dashboard')).status,401);
    assert.equal((await request('/api/auth/login','POST',{email:'admin@example.com',password:'wrong'})).status,401);
    assert.equal((await request('/api/auth/login','POST',{email:'nobody@example.com',password:'wrong'})).status,401);
    const login = await request('/api/auth/login','POST',{email:'ADMIN@example.com',password:'A secure test password'});
    assert.equal(login.status,200);
    const {token} = await login.json();
    assert.equal((await request('/api/admin/me','GET',null,token)).status,200);
    const stats=await (await request('/api/admin/dashboard','GET',null,token)).json();
    assert.equal(stats.products.total,78);
    assert.equal(stats.products.active,78);
    assert.equal(stats.categories.total,3);
    assert.equal(stats.quotes.total,0);
    assert.equal(stats.weeklyQuotes.length,7);
    assert.equal(stats.categoryProducts.reduce((sum,row)=>sum+row.count,0),78);
    assert.equal(stats.partners.total,8);
    assert.equal(stats.banners.total,6);

    const originalHero = (await pool.query("select id from hero_banners where page='about'")).rows[0];
    for (const image of ['/images/hero.jpg', '/images/fabric.jpg']) {
      const saved = await request('/api/admin/hero_banners','POST',{page:'about',image_url:image},token);
      assert.equal(saved.status,200);
      const banner = await saved.json();
      assert.equal(banner.id,originalHero.id);
      assert.equal(banner.image_url,image);
    }
    assert.equal((await pool.query("select count(*) from hero_banners where page='about'")).rows[0].count,1);
    const publicBanners = await (await request('/api/content')).json();
    assert.equal(publicBanners.heroes.find(row => row.page === 'about').image_url,'/images/fabric.jpg');

    const catalog = await (await request('/api/catalog/mens')).json();
    assert.ok(catalog.products.length > 0);
    const product = catalog.products[0];
    assert.equal((await request('/api/quotes','POST',{name:'Buyer',email:'buyer@example.com',quantity:100,product_id:product.databaseId,product_name:'tampered',color:'tampered'})).status,201);
    const quotes = await (await request('/api/admin/quotes','GET',null,token)).json();
    assert.equal(quotes.total,1);
    assert.equal((await request('/api/admin/quotes/summary')).status,401);
    const summary=await (await request('/api/admin/quotes/summary','GET',null,token)).json();
    assert.equal(summary.total,1);assert.equal(summary.new,1);assert.equal(summary.today,1);
    const searchResult=await (await request('/api/admin/quotes?q=Buyer&sort=oldest','GET',null,token)).json();
    assert.equal(searchResult.total,1);
    assert.equal((await (await request('/api/admin/quotes?q=%25','GET',null,token)).json()).total,0);
    assert.equal((await request('/api/admin/quotes?sort=invalid','GET',null,token)).status,400);
    const originalRequestedAt=quotes.rows[0].created_at;
    assert.equal((await request(`/api/admin/quotes/${quotes.rows[0].id}`,'PATCH',{status:'reviewing',admin_notes:'Follow up'},token)).status,200);
    assert.equal((await pool.query('select created_at from quote_requests where id=$1',[quotes.rows[0].id])).rows[0].created_at.toISOString(),new Date(originalRequestedAt).toISOString());
    assert.equal((await (await request('/api/admin/quotes/summary','GET',null,token)).json()).reviewing,1);
    await request(`/api/admin/quotes/${quotes.rows[0].id}`,'PATCH',{status:'new',admin_notes:''},token);

    const updatedStats=await (await request('/api/admin/dashboard','GET',null,token)).json();
    assert.equal(updatedStats.quotes.new,1);
    assert.equal(updatedStats.recentQuotes[0].product_name,product.name);
    assert.equal(updatedStats.weeklyQuotes.reduce((sum,day)=>sum+day.count,0),1);

    assert.equal(quotes.rows[0].product_name,product.name);
    const page = await (await request('/api/admin/quotes?page=20','GET',null,token)).json();
    assert.equal(page.total,1);
    assert.equal(page.rows.length,0);
    const partner = await (await request('/api/admin/partners','POST',{name:"Test ' partner",image_url:""},token)).json();
    assert.ok(partner.id);
    assert.equal((await request(`/api/admin/partners/${partner.id}`,'PUT',{name:'Updated',image_url:''},token)).status,200);
    assert.equal((await request(`/api/admin/partners/${partner.id}`,'DELETE',null,token)).status,204);
    assert.equal((await request('/api/quotes','POST',{name:'Contact Buyer',email:'contact@example.com',product_name:'General enquiry',quantity:null,message:'Please contact us'})).status,201);
    const content = await (await request('/api/content')).json();
    assert.equal(content.heroes.length,6);
    for (const sort_order of [2,1]) {
      const result = await request('/api/admin/hero_banners','POST',{page:'home',image_url:'/images/fabric.jpg',sort_order},token);
      assert.equal(result.status,201);
    }
    assert.equal((await pool.query("select count(*) from hero_banners where page='home'")).rows[0].count,3);
    const slides = (await (await request('/api/content')).json()).heroes.filter(row => row.page === 'home');
    assert.deepEqual(slides.map(row => row.sort_order),[0,1,2]);
    assert.equal((await database.from('hero_banners').insert({page:'about',slot:'invalid',image_url:''})).error.code,'23514');
    assert.equal((await request(`/api/admin/hero_banners/${slides[1].id}`,'PUT',{page:'home',image_url:'/images/hero.jpg',sort_order:1,is_active:false},token)).status,200);
    assert.equal((await (await request('/api/content')).json()).heroes.filter(row => row.page === 'home').length,2);
    await request(`/api/admin/hero_banners/${slides[2].id}`,'DELETE',null,token);
    assert.equal((await pool.query("select count(*) from hero_banners where page='home'")).rows[0].count,2);

    assert.ok(Array.isArray(content.partners));
    const rootResponse = await request('/api/admin/categories','POST',{name:'Accessories',slug:'accessories',parent_id:null},token);
    assert.equal(rootResponse.status,201);
    assert.equal((await request('/api/admin/categories','POST',{name:'Reserved',slug:'admin',parent_id:null},token)).status,400);
    const roots = (await pool.query('select * from categories where parent_id is null')).rows;
    const createdCategory = await request('/api/admin/categories','POST',{name:'New category',slug:'new-category',parent_id:roots[0].id},token);
    assert.equal(createdCategory.status,201);
    const categoryRow = await createdCategory.json();
    const createdSubcategory = await request('/api/admin/categories','POST',{name:'New subcategory',slug:'new-subcategory',parent_id:categoryRow.id},token);
    assert.equal(createdSubcategory.status,201);
    const subcategoryRow = await createdSubcategory.json();
    const createdProduct = await request('/api/admin/products','POST',{sku:'NEW-SUB-PRODUCT',name:'New subcategory product',category_id:subcategoryRow.id,image_url:'/images/hero.jpg'},token);
    assert.equal(createdProduct.status,201);
    const newProduct = await createdProduct.json();
    assert.match(newProduct.sku,/^RS-[A-Z0-9]+-001$/);
    const mensTshirts = (await pool.query("select c.id from categories c join categories r on c.parent_id=r.id where c.slug='t-shirts' and r.slug='mens'")).rows[0];
    const beforeSku = await (await request(`/api/admin/products/sku-preview?category_id=${mensTshirts.id}`,'GET',null,token)).json();
    assert.equal(beforeSku.sku,'RS-MTS-009');
    const simultaneous = await Promise.all([1,2].map(i => request('/api/admin/products','POST',{name:`Automatic SKU ${i}`,category_id:mensTshirts.id,sku:'TAMPERED'},token)));
    const allocated = await Promise.all(simultaneous.map(response => response.json()));
    assert.deepEqual(allocated.map(row => row.sku).sort(),['RS-MTS-009','RS-MTS-010']);
    await request(`/api/admin/products/${allocated[0].id}`,'DELETE',null,token);
    assert.equal((await (await request(`/api/admin/products/sku-preview?category_id=${mensTshirts.id}`,'GET',null,token)).json()).sku,'RS-MTS-011');
    const unchanged = await (await request(`/api/admin/products/${allocated[1].id}`,'PUT',{name:'Updated automatic product',category_id:mensTshirts.id,sku:'CHANGE-ME'},token)).json();
    assert.equal(unchanged.sku,allocated[1].sku);

    const published = await (await request(`/api/catalog/${roots[0].slug}`)).json();
    assert.equal(published.products.find(item => item.databaseId === newProduct.id).attributes.Subcategory,'New subcategory');
    assert.ok(published.categories.find(item => item.id === 'new-category').filters.Subcategory.includes('New subcategory'));
    assert.equal((await request(`/api/admin/categories/${categoryRow.id}`,'DELETE',null,token)).status,409);
    assert.equal((await request('/api/admin/categories','POST',{name:'Too deep',slug:'too-deep',parent_id:subcategoryRow.id},token)).status,409);
    await request(`/api/admin/categories/${categoryRow.id}`,'PUT',{name:'New category',slug:'new-category',parent_id:roots[0].id,is_active:false},token);
    const hidden = await (await request(`/api/catalog/${roots[0].slug}`)).json();
    assert.ok(!hidden.products.some(item => item.databaseId === newProduct.id));
    assert.equal((await request('/api/quotes','POST',{name:'Buyer',email:'buyer@example.com',quantity:10,product_name:'Hidden',product_id:newProduct.id})).status,400);

    const rejected = await database.from('products').insert({sku:'invalid',name:'Invalid',category_id:roots[0].id});
    assert.equal(rejected.error.code,'P0001');
    const png = await sharp({create:{width:20,height:20,channels:3,background:'#ffffff'}}).png().toBuffer();
    const form = new FormData(); form.append('kind','logo'); form.append('image',new Blob([png],{type:'image/png'}),'logo.png');
    const uploaded = await fetch(url+'/api/admin/uploads',{method:'POST',headers:{Authorization:`Bearer ${token}`},body:form});
    assert.equal(uploaded.status,201);
    const asset = await uploaded.json();
    assert.equal((await fetch(url+asset.url)).status,200);
    assert.equal((await request('/api/admin/ceo','PUT',{name:'CEO'},token)).status,404);
    assert.equal((await compressImage(png,'product')).contentType,'image/webp');
    await assert.rejects(compressImage(Buffer.from('invalid'),'hero'));

    assert.equal((await request('/api/admin/home-slides','PUT',{slides:[]})).status,401);
    const currentHome = (await pool.query("select * from hero_banners where page='home' order by sort_order")).rows;
    const otherBanner = (await pool.query("select * from hero_banners where page='about'")).rows[0];
    const savedSlidesResponse = await request('/api/admin/home-slides','PUT',{slides:[
      {id:currentHome[0].id,image_url:'/images/hero.jpg',is_active:true},
      {image_url:'/images/fabric.jpg',is_active:false},
    ]},token);
    assert.equal(savedSlidesResponse.status,200);
    const savedSlides = await savedSlidesResponse.json();
    assert.equal(savedSlides.length,2);
    assert.deepEqual(savedSlides.map(row => row.sort_order),[0,1]);
    assert.equal((await request('/api/admin/home-slides','PUT',{slides:[{id:otherBanner.id,image_url:'/images/hero.jpg',is_active:true}]},token)).status,409);
    assert.equal((await pool.query("select count(*) from hero_banners where page='home'")).rows[0].count,2);
    assert.equal((await pool.query("select image_url from hero_banners where id=$1",[otherBanner.id])).rows[0].image_url,otherBanner.image_url);
    assert.equal((await request('/api/admin/home-slides','PUT',{slides:[{id:savedSlides[0].id,image_url:'/images/hero.jpg'},{id:savedSlides[0].id,image_url:'/images/hero.jpg'}]},token)).status,400);
    assert.equal((await request('/api/admin/home-slides','PUT',{slides:[{id:savedSlides[0].id,image_url:'/images/fabric.jpg'}]},token)).status,200);
    assert.equal((await pool.query("select count(*) from hero_banners where page='home'")).rows[0].count,1);

    async function uploadTestAsset() {
      const form = new FormData(); form.append('kind','logo'); form.append('image',new Blob([png],{type:'image/png'}),'logo.png');
      const response = await fetch(url+'/api/admin/uploads',{method:'POST',headers:{Authorization:`Bearer ${token}`},body:form});
      assert.equal(response.status,201); return response.json();
    }
    const sharedAsset = await uploadTestAsset();
    const partnerIds = [];
    for(const name of ['Shared logo A','Shared logo B']) {
      partnerIds.push((await (await request('/api/admin/partners','POST',{name,image_url:sharedAsset.url},token)).json()).id);
    }
    assert.equal((await (await request('/api/admin/uploads/remove','POST',{url:sharedAsset.url},token)).json()).queued,false);
    await request(`/api/admin/partners/${partnerIds[0]}`,'DELETE',null,token);
    assert.ok(await readFile(join(root,sharedAsset.path)));
    await request(`/api/admin/partners/${partnerIds[1]}`,'DELETE',null,token);
    await assert.rejects(readFile(join(root,sharedAsset.path)),{code:'ENOENT'});
    assert.equal((await pool.query('select count(*) from media_assets where id=$1',[sharedAsset.id])).rows[0].count,0);

    const oldImage=await uploadTestAsset(), replacementImage=await uploadTestAsset();
    const replacePartner=(await (await request('/api/admin/partners','POST',{name:'Replace logo',image_url:oldImage.url},token)).json());
    await request(`/api/admin/partners/${replacePartner.id}`,'PUT',{name:'Replace logo',image_url:replacementImage.url},token);
    await assert.rejects(readFile(join(root,oldImage.path)),{code:'ENOENT'});
    assert.ok(await readFile(join(root,replacementImage.path)));

    const removedSlide=await uploadTestAsset();
    const homeWithUpload=await (await request('/api/admin/home-slides','PUT',{slides:[{image_url:removedSlide.url}]},token)).json();
    assert.ok(homeWithUpload[0].id);
    await request('/api/admin/home-slides','PUT',{slides:[]},token);
    await assert.rejects(readFile(join(root,removedSlide.path)),{code:'ENOENT'});

    const temporary=await uploadTestAsset();
    assert.equal((await request('/api/admin/uploads/remove','POST',{url:temporary.url})).status,401);
    await request('/api/admin/uploads/remove','POST',{url:temporary.url},token);
    await assert.rejects(readFile(join(root,temporary.path)),{code:'ENOENT'});

    const retryImage=await uploadTestAsset();
    await database.requestMediaCleanup(retryImage.url);
    await createMediaCleanup(database,{remove:async()=>{throw new Error('Storage unavailable');}})();
    assert.equal((await pool.query('select count(*) from media_cleanup_queue where asset_id=$1',[retryImage.id])).rows[0].count,1);
    assert.ok(await readFile(join(root,retryImage.path)));
    await createMediaCleanup(database,createStorage(root))();
    await assert.rejects(readFile(join(root,retryImage.path)),{code:'ENOENT'});
    assert.equal((await pool.query('select count(*) from media_cleanup_queue where asset_id=$1',[retryImage.id])).rows[0].count,0);
    await request('/api/auth/logout','POST',null,token);
    assert.equal((await request('/api/admin/me','GET',null,token)).status,401);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    await engine.close();
    await rm(root,{recursive:true,force:true});
  }
});

test('existing Supabase database upgrade preserves content and accepts custom admins', async () => {
  const engine = new PGlite();
  try {
    await engine.exec("create role anon; create role authenticated; create role service_role; create schema auth; create table auth.users(id uuid primary key, email text); create function auth.uid() returns uuid language sql as $$ select null::uuid $$;");
    const original = await readFile(new URL('../supabase/01-schema.sql',import.meta.url),'utf8');
    await engine.exec(original.replace('create extension if not exists pgcrypto;',''));
    await engine.exec(await readFile(new URL('../db/002-seed.sql',import.meta.url),'utf8'));
    await engine.exec(await readFile(new URL('../db/000-upgrade-legacy.sql',import.meta.url),'utf8'));
    assert.equal(Number((await engine.query('select count(*) from products')).rows[0].count),78);
    await engine.query('insert into admin_users(email,password_hash) values($1,$2)',['custom@example.com',await hashPassword('Custom password 123')]);
    const auth = createAuth(engine);
    assert.ok(await auth.login('custom@example.com','Custom password 123'));
    await engine.exec('set role anon');
    await assert.rejects(engine.query('select * from quote_requests'));
    await assert.rejects(engine.query('select * from admin_users'));
  } finally { await engine.close(); }
});
