-- Security review: iMessage senders can be email handles. e164() stripped
-- every non-digit, so "x+15551234567@icloud.com" became +15551234567 and
-- could act as that number's parent or teacher. Only plain phone strings
-- (digits, spaces, + ( ) - .) are accepted now; anything else is null.
create or replace function private.e164(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_phone is null or p_phone !~ '^\s*\+?[0-9 ()\-.]{7,24}\s*$' then null
    when d is null then null
    when char_length(d) = 10 then '+1' || d                 -- bare US number
    when char_length(d) between 8 and 15 and d !~ '^0' then '+' || d
    else null
  end
  from (select nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') as d) x
$$;
revoke all on function private.e164(text) from public;
