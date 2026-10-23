// Small adapter for the query operations used by this API. Values are always bound.
const tables = new Set(['admin_users','admin_sessions','hero_banners','partners','categories','products','quote_requests','media_assets']);
const identifier = value => {
  if (!/^[a-z_][a-z0-9_]*$/.test(value)) throw new Error('Invalid SQL identifier');
  return `"${value}"`;
};
export function createDatabase(pool) {
  return {
    async quoteSummary() {
      return (await pool.query(`select jsonb_build_object('total',count(*),'new',count(*) filter(where status='new'),
        'reviewing',count(*) filter(where status='reviewing'),'responded',count(*) filter(where status='responded'),
        'closed',count(*) filter(where status='closed'),'today',count(*) filter(where (created_at at time zone 'Asia/Dhaka')::date=(now() at time zone 'Asia/Dhaka')::date)) as summary from public.quote_requests`)).rows[0].summary;
    },
    async quoteInbox({page,status,search,sort}) {
      const values=[];const filters=[];
      if(status){values.push(status);filters.push(`status=$${values.length}`);}
      if(search){values.push(`%${search.replace(/[\\%_]/g,'\\$&')}%`);const parameter=`$${values.length}`;filters.push(`(name ilike ${parameter} or email ilike ${parameter} or company ilike ${parameter} or product_name ilike ${parameter} or product_sku ilike ${parameter})`);}
      const where=filters.length?` where ${filters.join(' and ')}`:'';
      const total=Number((await pool.query(`select count(*) as total from public.quote_requests${where}`,values)).rows[0].total);
      const direction=sort==='oldest'?'asc':'desc';
      const rows=(await pool.query(`select * from public.quote_requests${where} order by created_at ${direction},id ${direction} limit 25 offset $${values.length+1}`,[...values,(page-1)*25])).rows;
      return {rows,total,page};
    },
    async dashboardStats() {
      const result = await pool.query(`with recursive tree(root_id,id) as (
        select id,id from public.categories where parent_id is null
        union all select tree.root_id,c.id from public.categories c join tree on c.parent_id=tree.id
      ), days as (
        select generate_series((now() at time zone 'Asia/Dhaka')::date-6,(now() at time zone 'Asia/Dhaka')::date,interval '1 day')::date as day
      ) select jsonb_build_object(
        'products',(select jsonb_build_object('total',count(*),'active',count(*) filter(where is_active),'hidden',count(*) filter(where not is_active)) from public.products),
        'categories',(select jsonb_build_object('total',count(*) filter(where level=1),'groups',count(*) filter(where level=2),'subcategories',count(*) filter(where level=3)) from public.categories),
        'quotes',(select jsonb_build_object('total',count(*),'new',count(*) filter(where status='new'),'reviewing',count(*) filter(where status='reviewing'),'responded',count(*) filter(where status='responded'),'closed',count(*) filter(where status='closed'),'customers',count(distinct lower(email))) from public.quote_requests),
        'partners',(select jsonb_build_object('total',count(*),'active',count(*) filter(where is_active)) from public.partners),
        'banners',(select jsonb_build_object('total',count(*),'home',count(*) filter(where page='home'),'active',count(*) filter(where is_active)) from public.hero_banners),
        'weeklyQuotes',(select coalesce(jsonb_agg(row_to_json(w) order by w.day),'[]'::jsonb) from (select days.day,count(q.id)::int as count from days left join public.quote_requests q on (q.created_at at time zone 'Asia/Dhaka')::date=days.day group by days.day) w),
        'categoryProducts',(select coalesce(jsonb_agg(row_to_json(c) order by c.count desc,c.name),'[]'::jsonb) from (select r.name,r.id,count(p.id)::int as count from public.categories r join tree on tree.root_id=r.id left join public.products p on p.category_id=tree.id where r.parent_id is null group by r.id,r.name) c),
        'recentQuotes',(select coalesce(jsonb_agg(row_to_json(q) order by q.created_at desc),'[]'::jsonb) from (select id,name,email,product_name,status,created_at from public.quote_requests order by created_at desc,id limit 5) q),
        'recentProducts',(select coalesce(jsonb_agg(row_to_json(p) order by p.created_at desc),'[]'::jsonb) from (select id,name,sku,image_url,is_active,created_at from public.products order by created_at desc,id limit 4) p)
      ) as dashboard`);
      return result.rows[0].dashboard;
    },
    async mediaCleanupCandidates() {
      return (await pool.query('select a.* from public.media_assets a join public.media_cleanup_queue q on q.asset_id=a.id order by q.queued_at limit 100')).rows;
    },
    async mediaIsReferenced(url) { return (await pool.query('select public.media_is_referenced($1) as used',[url])).rows[0].used; },
    async cancelMediaCleanup(id) { await pool.query('delete from public.media_cleanup_queue where asset_id=$1',[id]); },
    async completeMediaCleanup(id) { await pool.query('delete from public.media_assets where id=$1',[id]); },
    async failMediaCleanup(id) { await pool.query("update public.media_cleanup_queue set last_error='Storage removal failed; retry pending',queued_at=now() where asset_id=$1",[id]); },
    async requestMediaCleanup(url) {
      if (await this.mediaIsReferenced(url)) return false;
      await pool.query('insert into public.media_cleanup_queue(asset_id) select id from public.media_assets where url=$1 on conflict(asset_id) do nothing',[url]);
      return true;
    },
    async previewProductSku(categoryId) {
    const result = await pool.query(`with code as (select public.product_sku_prefix($1::uuid) as prefix)
      select code.prefix || '-' || lpad((coalesce(c.last_number,0)+1)::text,
        greatest(3,length((coalesce(c.last_number,0)+1)::text)),'0') as sku
      from code left join public.product_sku_counters c on c.prefix=code.prefix`, [categoryId]);
    return result.rows[0];
  }, async replaceHomeSlides(slides) {
    const client = pool.connect ? await pool.connect() : pool;
    try {
      await client.query('begin');
      await client.query('select pg_advisory_xact_lock(78132402)');
      const existing = (await client.query("select id from public.hero_banners where page = 'home' for update")).rows;
      const known = new Set(existing.map(row => row.id));
      if (slides.some(slide => slide.id && !known.has(slide.id))) throw Object.assign(new Error('A slide has changed or was deleted. Reload the editor and try again.'), {status: 409});
      const saved = [];
      for (const [index, slide] of slides.entries()) {
        const result = slide.id
          ? await client.query("update public.hero_banners set image_url=$1, is_active=$2, sort_order=$3 where id=$4 and page='home' returning *", [slide.image_url, slide.is_active, index, slide.id])
          : await client.query("insert into public.hero_banners(page,slot,image_url,is_active,sort_order) values('home',gen_random_uuid()::text,$1,$2,$3) returning *", [slide.image_url, slide.is_active, index]);
        saved.push(result.rows[0]);
      }
      await client.query("delete from public.hero_banners where page='home' and not (id = any($1::uuid[]))", [saved.map(row => row.id)]);
      await client.query('commit');
      return saved;
    } catch (error) { await client.query('rollback'); throw error; }
    finally { client.release?.(); }
  }, from(table) {
    if (!tables.has(table)) throw new Error('Unknown table');
    return new Query(pool, table);
  }};
}
class Query {
  constructor(pool, table) { this.pool = pool; this.table = table; this.filters = []; this.orders = []; this.operation = 'select'; this.columns = '*'; }
  select(columns = '*', options = {}) { this.columns = columns; this.returning = true; this.count = options.count; return this; }
  eq(column, value) { this.filters.push([column, value]); return this; }
  order(column, {ascending = true} = {}) { this.orders.push(`${identifier(column)} ${ascending ? 'asc' : 'desc'}`); return this; }
  range(start, end) { this.offset = start; this.max = end - start + 1; return this; }
  limit(max) { this.max = max; return this; }
  insert(value) { this.operation = 'insert'; this.value = value; return this; }
  update(value) { this.operation = 'update'; this.value = value; return this; }
  upsert(value, {onConflict}) { this.operation = 'insert'; this.value = value; this.conflict = onConflict; return this; }
  delete() { this.operation = 'delete'; return this; }
  single() { this.cardinality = 'one'; return this; }
  maybeSingle() { this.cardinality = 'optional'; return this; }
  then(resolve, reject) { return this.execute().then(resolve, reject); }
  async execute() {
    try {
      const values = [];
      const bind = value => { values.push(value); return `$${values.length}`; };
      const columns = this.columns === '*' ? '*' : this.columns.split(',').map(value => identifier(value.trim())).join(',');
      let sql;
      const name = `public.${identifier(this.table)}`;
      if (this.operation === 'insert') {
        const keys = Object.keys(this.value);
        sql = `insert into ${name} (${keys.map(identifier)}) values (${keys.map(key => bind(this.value[key]))})`;
        if (this.conflict) sql += ` on conflict (${this.conflict.split(',').map(value => identifier(value.trim())).join(',')}) do update set ${keys.filter(key => !this.conflict.split(',').includes(key)).map(key => `${identifier(key)} = excluded.${identifier(key)}`).join(',')}`;
      } else if (this.operation === 'update') {
        sql = `update ${name} set ${Object.entries(this.value).map(([key,value]) => `${identifier(key)} = ${bind(value)}`).join(',')}`;
      } else sql = this.operation === 'delete' ? `delete from ${name}` : `select ${columns}${this.count ? ', count(*) over() as __total' : ''} from ${name}`;
      if (this.filters.length) sql += ` where ${this.filters.map(([key,value]) => value === null ? `${identifier(key)} is null` : `${identifier(key)} = ${bind(value)}`).join(' and ')}`;
      if (this.operation === 'select') {
        if (this.orders.length) sql += ` order by ${this.orders.join(',')}`;
        if (this.max !== undefined) sql += ` limit ${bind(this.max)}`;
        if (this.offset !== undefined) sql += ` offset ${bind(this.offset)}`;
      } else if (this.returning) sql += ` returning ${columns}`;
      const result = await this.pool.query(sql, values);
      let count = this.count ? Number(result.rows[0]?.__total || 0) : undefined;
      // A page past the end still needs the actual total.
      if (this.count && !result.rows.length) {
        const args = [];
        const where = this.filters.map(([key,value]) => { args.push(value); return `${identifier(key)} = $${args.length}`; }).join(' and ');
        count = Number((await this.pool.query(`select count(*) as total from ${name}${where ? ` where ${where}` : ''}`, args)).rows[0].total);
      }
      const rows = result.rows.map(({__total, ...row}) => row);
      if (this.cardinality && (rows.length > 1 || (this.cardinality === 'one' && rows.length !== 1))) throw new Error('Unexpected result cardinality');
      return {data: this.cardinality ? rows[0] || null : rows, count, error: null};
    } catch (error) { return {data: null, error}; }
  }
}
