-- ============================================================================
-- 0049 — readings and strings read policies back to the tenancy filter.
--
-- 0035 rebuilt both tables as partitioned parents and recreated their read
-- policies as `using (true)`, so any signed-in user could select every plant's
-- rows (the api_* functions scope themselves, but the tables are also exposed
-- through PostgREST). 0024 §4 had them on `my_plant_ids()`; restore that.
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array['readings', 'strings'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (plant_id in (select public.my_plant_ids()))',
      t || '_read', t);
  end loop;
end $$;
