-- "Did it help?" is rated by the teacher, who sees the calm moment happen at
-- school; parents can still read the ratings. Unrated moments (e.g. at home)
-- simply do not count toward the weekly scene picker.
alter policy "events: linked users set helped" on public.events
  using (child_id in (select child_id from public.child_members where user_id = (select auth.uid())))
  with check (child_id in (select child_id from public.child_members where user_id = (select auth.uid())));
