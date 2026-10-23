-- Contact enquiries may not have an agreed quantity yet.
begin;
alter table public.quote_requests alter column quantity drop not null;
commit;
