-- Fixes from Supabase's security and performance advisors after 0001.

-- Indexes for foreign keys the advisor found uncovered.
create index if not exists assessments_created_by_idx on public.assessments (created_by);
create index if not exists commands_created_by_idx    on public.commands (created_by);
create index if not exists events_command_id_idx      on public.events (command_id);
create index if not exists events_started_by_idx      on public.events (started_by);

-- rls_auto_enable() is Supabase's event-trigger helper that turns RLS on for
-- new public tables. It only needs to run as an event trigger, never over the API.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
