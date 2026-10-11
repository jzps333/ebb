-- Security review: a linked teacher could toggle false_alarm / helped on the
-- same calm moment over and over, and each toggle moved sensitivity again,
-- pushing motion_k / noise_k to the limit (auto-start effectively off).
-- Now each calm moment can tune sensitivity at most once.
create or replace function private.tune_sensitivity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old   real;
  v_new   real;
  v_why   text;
begin
  if new.trigger not in ('motion', 'noise') then return new; end if;
  if exists (select 1 from public.sensitivity_log where event_id = new.id) then return new; end if;

  if new.false_alarm is true and old.false_alarm is distinct from true then
    v_why := 'false alarm';
  elsif new.helped is true and old.helped is distinct from true and new.false_alarm is not true then
    v_why := 'helped';
  else
    return new;
  end if;

  select case when new.trigger = 'motion' then motion_k else noise_k end
    into v_old from public.child_settings where child_id = new.child_id;
  if v_old is null then return new; end if;

  v_new := case when v_why = 'false alarm' then least(5, v_old + 0.3) else greatest(1.5, v_old - 0.1) end;
  if v_new = v_old then return new; end if;

  if new.trigger = 'motion' then
    update public.child_settings set motion_k = v_new where child_id = new.child_id;
  else
    update public.child_settings set noise_k = v_new where child_id = new.child_id;
  end if;

  insert into public.sensitivity_log (child_id, event_id, signal, old_k, new_k, reason)
  values (new.child_id, new.id, new.trigger, v_old, v_new, v_why);
  return new;
end;
$$;
revoke all on function private.tune_sensitivity() from public;
