-- Allow administrators to create top-level categories as well as groups/subcategories.
-- Existing records and root URL names are preserved.
begin;
do $$ declare constraint_name text; begin
  for constraint_name in
    select conname from pg_constraint
    where conrelid = 'public.categories'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%parent_id%'
  loop
    execute format('alter table public.categories drop constraint %I', constraint_name);
  end loop;
end; $$;
alter table public.categories add constraint categories_depth_parent_check
  check ((parent_id is null and level = 1) or (parent_id is not null and level > 1));
commit;
