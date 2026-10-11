-- Security review: messaging/drain had no secret, so anyone could call it in
-- a loop and burn a queued text's 5 attempts while sending was failing
-- (dropping login codes). The trigger and cron now send x-drain-secret, a
-- random value created here and kept in Vault; the function checks it through
-- ebb_text_drain_ok (service role only). Nobody ever has to copy it.
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'ebb_drain_secret',
                           'messaging/drain caller secret');

create or replace function private.drain_secret()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'ebb_drain_secret' limit 1
$$;
revoke all on function private.drain_secret() from public;

create or replace function public.ebb_text_drain_ok(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_secret is not null and length(p_secret) >= 32
     and extensions.digest(p_secret, 'sha256') = extensions.digest(private.drain_secret(), 'sha256')
$$;
revoke all on function public.ebb_text_drain_ok(text) from public, anon, authenticated;
grant execute on function public.ebb_text_drain_ok(text) to service_role;

create or replace function private.kick_text_drain()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform net.http_post(
    url := 'https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1/messaging/drain',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-drain-secret', private.drain_secret())
  );
  return null;
end;
$$;
revoke all on function private.kick_text_drain() from public;

select cron.schedule('ebb-text-drain', '* * * * *', $cron$
  select net.http_post(
    url := 'https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1/messaging/drain',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-drain-secret', private.drain_secret())
  )
  where exists (select 1 from private.outbound_texts where sent_at is null and attempts < 5);
$cron$);
