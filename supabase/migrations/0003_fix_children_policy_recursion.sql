-- The children insert policy read profiles, and the profiles select policy
-- reads children, so inserting a child hit "infinite recursion detected in
-- policy for relation children". Check the caller's role through a security
-- definer function instead, which does not go through profiles' policies.

create or replace function private.is_parent()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'parent')
$$;

revoke all on function private.is_parent() from public;
grant execute on function private.is_parent() to authenticated;

alter policy "children: parents create their own" on public.children
  with check (owner_id = (select auth.uid()) and (select private.is_parent()));
