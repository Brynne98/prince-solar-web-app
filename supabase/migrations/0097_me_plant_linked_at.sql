-- SOLAR-170: First steps stays finished until the plant is removed and added again.
--
-- The app keeps "done", "hidden" and the reserve tick in profiles.prefs.firstSteps,
-- keyed by plant id. A removed and re-added plant keeps its id, so the marks would
-- outlive the re-add. api_me now also gives each plant's linked_at; Remove login
-- deletes the plant_users row (0096) and a re-add inserts a new one, so the app
-- treats marks taken under another linked_at as gone. Body as the live api_me (0027)
-- otherwise.

create or replace function public.api_me()
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'plan', coalesce((select plan from public.profiles where user_id = auth.uid()), 'free'),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid()), '[]'::jsonb))
$$;
revoke all on function public.api_me() from public, anon;
grant execute on function public.api_me() to authenticated, service_role;
