-- Gentle per-user message cooldown for all message types.
-- A single short delay prevents accidental rapid repeats without slowing normal chat.
create table if not exists private.message_send_limits (
  sender_id uuid primary key references public.profiles(id) on delete cascade,
  last_sent_at timestamptz not null
);

revoke all on table private.message_send_limits from public, anon, authenticated;

create or replace function private.enforce_message_send_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, private, public
as $function$
declare
  v_last timestamptz;
  v_now timestamptz;
begin
  if new.sender_id is null then
    return new;
  end if;

  if auth.uid() is not null and new.sender_id <> auth.uid() then
    raise exception 'message_sender_mismatch' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('sdjchat-message-rate:' || new.sender_id::text, 0)
  );

  select last_sent_at
    into v_last
    from private.message_send_limits
    where sender_id = new.sender_id
    for update;

  v_now := clock_timestamp();

  if v_last is not null and v_now - v_last < interval '800 milliseconds' then
    raise exception 'message_rate_limited' using errcode = 'P0001';
  end if;

  insert into private.message_send_limits (sender_id, last_sent_at)
  values (new.sender_id, v_now)
  on conflict (sender_id)
  do update set last_sent_at = excluded.last_sent_at;

  return new;
end;
$function$;

revoke all on function private.enforce_message_send_rate_limit() from public, anon, authenticated;

drop trigger if exists messages_z_rate_limit on public.messages;
create trigger messages_z_rate_limit
before insert on public.messages
for each row execute function private.enforce_message_send_rate_limit();
