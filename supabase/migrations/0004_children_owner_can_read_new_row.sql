-- insert into children ... returning (what supabase-js .insert().select() does)
-- failed with "new row violates row-level security policy": the returned row
-- must pass the select policy, and private.user_child_ids() runs on a snapshot
-- from before the insert, so it cannot see the new child yet. Let owners read
-- their children directly by owner_id as well.

alter policy "children: read own or linked" on public.children
  using (owner_id = (select auth.uid()) or id in (select private.user_child_ids()));
