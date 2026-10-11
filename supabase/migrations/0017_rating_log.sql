-- Log who rated a calm moment ("Did it help?") and when, for the website's
-- timeline. Filled in by a trigger, so clients cannot fake either field.

alter table public.events
  add column helped_by uuid references public.profiles (id) on delete set null,
  add column helped_at timestamptz;
create index events_helped_by_idx on public.events (helped_by);

create or replace function private.stamp_rating()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.helped is distinct from old.helped then
    new.helped_by := (select auth.uid());
    new.helped_at := case when new.helped is null then null else now() end;
  end if;
  return new;
end;
$$;

create trigger events_stamp_rating
  before update of helped on public.events
  for each row execute function private.stamp_rating();
