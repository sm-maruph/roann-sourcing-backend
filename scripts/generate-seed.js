import { writeFile } from 'node:fs/promises';
import { mensCategories, mensProducts } from '../../frontend/src/data/mens.js';
import { womensCategories, womensProducts } from '../../frontend/src/data/womens.js';
import { girlsCategories, girlsProducts } from '../../frontend/src/data/girls.js';
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const json = value => `${quote(JSON.stringify(value))}::jsonb`;
const sql = ['-- Generated starter content from the current frontend. Run after schema and storage.', '-- Existing records are preserved when this seed is rerun. Local image paths use frontend assets.', 'begin;'];
for (const [page, image] of [['home','/images/hero.jpg'],['about','/images/fabric.jpg'],['compliance','/images/textile.jpg'],['mens','/images/hero.jpg'],['womens','/images/fabric.jpg'],['girls','/images/mens/sweater.jpg']]) {
  sql.push(`insert into public.hero_banners(page,image_url) values(${quote(page)},${quote(image)}) on conflict do nothing;`);
}
for (const [audience, label, image, categories, products] of [['mens','Men’s','/images/mens/denim.jpg',mensCategories,mensProducts], ['womens','Women’s','/images/fabric.jpg',womensCategories,womensProducts], ['girls','Girls','/images/mens/sweater.jpg',girlsCategories,girlsProducts]]) {
  sql.push(`insert into public.categories(name,slug,parent_id) values(${quote(label)},${quote(audience)},null) on conflict do nothing;`);
  categories.forEach((category, i) => {
    const config = Object.fromEntries(Object.entries(category).filter(([key]) => ['filters','benefits','banner','bannerCopy','bannerImage'].includes(key)));
    sql.push(`insert into public.categories(name,slug,parent_id,hero_image_url,tagline,description,config,sort_order) select ${quote(category.label)},${quote(category.id)},id,${quote(category.hero)},${quote(category.tagline)},${quote(category.description)},${json(config)},${i} from public.categories where slug=${quote(audience)} and parent_id is null on conflict do nothing;`);
    const types = [...new Set(products.filter(product => product.category === category.id).map(product => product.type))];
    types.forEach((type, typeIndex) => {
      const slug = type.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
      sql.push(`insert into public.categories(name,slug,parent_id,sort_order) select ${quote(type)},${quote(slug)},c.id,${typeIndex} from public.categories c join public.categories root on c.parent_id=root.id where root.slug=${quote(audience)} and root.parent_id is null and c.slug=${quote(category.id)} on conflict do nothing;`);
    });
  });
  products.forEach(product => {
    const attributes = {...product.attributes};
    const colorName = product.colors?.[0] || '';
    if (Array.isArray(attributes.Color)) attributes.Color = colorName;
    sql.push(`insert into public.products(sku,name,category_id,subtitle,image_url,color_name,color_hex,attributes,pattern,sort_order) select ${quote(product.id)},${quote(product.name)},leaf.id,${quote(product.subtitle || '')},${quote(product.image || '')},${quote(colorName)},${quote(product.color)},${json(attributes)},${quote(product.pattern)},${product.order} from public.categories leaf join public.categories sub on leaf.parent_id=sub.id join public.categories root on sub.parent_id=root.id where root.slug=${quote(audience)} and root.parent_id is null and sub.slug=${quote(product.category)} and leaf.name=${quote(product.type)} on conflict(sku) do nothing;`);
  });
}
// Partner names are current frontend placeholders; upload approved logos in the admin.
for (const [i,name] of ['PRIMARK','sallinggroup','Kmart','Nutmeg','MATALAN','TALLY','next','H&M'].entries()) sql.push(`insert into public.partners(name,sort_order) select ${quote(name)},${i} where not exists(select 1 from public.partners where name=${quote(name)});`);
sql.push('commit;');
await writeFile(new URL('../db/002-seed.sql', import.meta.url), sql.join('\n') + '\n');
console.log('Generated db/002-seed.sql: 78 products, single colors, three-level category tree.');
