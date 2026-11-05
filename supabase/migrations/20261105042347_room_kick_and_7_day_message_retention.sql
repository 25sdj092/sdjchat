-- Allow room owners to remove active members and retain room messages for seven days.
-- Direct messages are intentionally excluded from the retention policy.

create index if not exists messages_room_retention_idx
  on public.messages (created_at, conversation_id);

create or replace function public.kick_room_member(p_conv uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  affected integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_user is null or p_user = v_uid then
    raise exception 'invalid_kick_target' using errcode = '22023';
  end if;

  select c.owner_id into v_owner
  from public.conversations c
  where c.id = p_conv and c.type in ('open', 'group')
  for update;

  if not found then
    raise exception 'room_not_found' using errcode = 'P0002';
  end if;

  if v_owner is distinct from v_uid or not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conv
      and cm.user_id = v_uid
      and cm.left_at is null
  ) then
    raise exception 'room_owner_only' using errcode = '42501';
  end if;

  update public.conversation_members
  set left_at = now()
  where conversation_id = p_conv
    and user_id = p_user
    and left_at is null;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'member_not_active' using errcode = 'P0002';
  end if;
end;
$function$;

revoke all on function public.kick_room_member(uuid, uuid) from public, anon;
grant execute on function public.kick_room_member(uuid, uuid) to authenticated;

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

select cron.schedule(
  'sdjchat-room-message-retention',
  '0 18 * * *',
  $cron$
    select net.http_post(
      url := 'https://tunrakwqldpcxrtbdeuq.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-webhook-secret', (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'sdjchat_push_webhook_secret'
          limit 1
        )
      ),
      body := jsonb_build_object('action', 'cleanup-room-messages'),
      timeout_milliseconds := 10000
    );
  $cron$
);
