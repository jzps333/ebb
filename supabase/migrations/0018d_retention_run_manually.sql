-- Adaptive Ebb, part D: deleting old or withdrawn data. Run by hand in the
-- Supabase SQL editor (the agent's migration tool doesn't run deletes).
--   - parents can delete their child's location points
--   - turning GPS off erases every point already collected
--   - hourly cleanup: sensor samples after 2 days, locations after 30 days

create policy "locations: parent deletes"
  on public.locations for delete to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())));
grant delete on public.locations to authenticated;

-- Turning GPS off erases what was collected.
create or replace function private.gps_off_erases()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.gps_enabled and not new.gps_enabled then
    delete from public.locations where child_id = new.child_id;
  end if;
  return new;
end;
$$;
revoke all on function private.gps_off_erases() from public;

create trigger child_settings_gps_off
  after update of gps_enabled on public.child_settings
  for each row execute function private.gps_off_erases();

-- ---------------------------------------------------------------------------
-- 8. Retention
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule('ebb-retention', '17 * * * *', $cron$
  delete from public.sensor_samples where at < now() - interval '2 days';
  delete from public.locations where at < now() - interval '30 days';
$cron$);
