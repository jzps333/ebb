-- Defence in depth (security review): child_members rows are already
-- teacher-only by its check constraint, but also require the caller's profile
-- role to be teacher, in case other link roles are ever added.
alter policy "events: linked users set helped" on public.events
  using (child_id in (select cm.child_id from public.child_members cm
                      join public.profiles p on p.id = cm.user_id
                      where cm.user_id = (select auth.uid()) and p.role = 'teacher'))
  with check (child_id in (select cm.child_id from public.child_members cm
                           join public.profiles p on p.id = cm.user_id
                           where cm.user_id = (select auth.uid()) and p.role = 'teacher'));
