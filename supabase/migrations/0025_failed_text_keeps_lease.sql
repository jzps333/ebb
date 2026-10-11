-- Security review: a send that timed out may still have been delivered, but
-- a failure cleared claimed_at, so the very next drain sent it again. Failed
-- texts now keep their 2-minute lease and are retried only after it expires.
-- (The drain also claims at most 5 texts with a 10 s timeout each, so a whole
-- batch finishes well inside the lease.)
create or replace function private.mark_outbox(p_ids bigint[], p_errors jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.outbound_texts o
     set sent_at = now(), error = null
   where o.id = any (coalesce(p_ids, '{}'::bigint[])) and o.sent_at is null;

  update private.outbound_texts o
     set error = left(e.value, 500)
    from jsonb_each_text(coalesce(p_errors, '{}'::jsonb)) e
   where e.key ~ '^\d+$' and o.id = e.key::bigint and o.sent_at is null;
end;
$$;
revoke all on function private.mark_outbox(bigint[], jsonb) from public;
