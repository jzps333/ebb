-- Texts go out through the website's Photon connector (Lovable edge function
-- photon-send) instead of a bridge on a Mac. Whenever a text is queued, ask
-- messaging/drain to send it right away (pg_net, async, after commit), and
-- retry anything left every minute.
create extension if not exists pg_net;

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
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  return null;
end;
$$;
revoke all on function private.kick_text_drain() from public;

create trigger outbound_texts_kick_drain
  after insert on private.outbound_texts
  for each statement execute function private.kick_text_drain();

select cron.schedule('ebb-text-drain', '* * * * *', $cron$
  select net.http_post(
    url := 'https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1/messaging/drain',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb
  )
  where exists (select 1 from private.outbound_texts where sent_at is null and attempts < 5);
$cron$);
