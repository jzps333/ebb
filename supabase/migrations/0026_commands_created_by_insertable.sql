-- The website (Lovable) sends created_by when it starts or stops calm, which
-- failed with "permission denied" because only device_id, child_id and type
-- were insertable. Allowing created_by is safe: the insert policy still
-- requires created_by = auth.uid(), a linked child, and that child's watch.
grant insert (created_by) on public.commands to authenticated;
