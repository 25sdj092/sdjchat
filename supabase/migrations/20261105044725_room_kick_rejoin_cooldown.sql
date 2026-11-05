-- Enforce a three-day rejoin cooldown after a room owner kicks a member.
-- The ban is checked in the shared join helper so both room join paths are covered.

create table if not exists private.conversation_kick_bans (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kicked_by uuid references public.profiles(id) on delete set null,
  kicked_at timestamptz not null default now(),
  blocked_until timestamptz not null,
  primary key (conversation_id, user_id)
);

alter table private.conversation_kick_bans enable row level security;
revoke all on table private.conversation_kick_bans from public, anon, authenticated;

create or replace function public._join_member(p_conv uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  lm_id uuid;
  lm_seq bigint;
  v_blocked_until timestamptz;
begin
  select b.blocked_until
    into v_blocked_until
  from private.conversation_kick_bans b
  where b.conversation_id = p_conv
    and b.user_id = p_user;

  if v_blocked_until is not null and v_blocked_until > now() then
    raise exception 'room_kicked_for_3_days' using errcode = 'P0001';
  end if;

  if v_blocked_until is not null then
    delete from private.conversation_kick_bans
    where conversation_id = p_conv
      and user_id = p_user
      and blocked_until <= now();
  end if;

  select id, seq
    into lm_id, lm_seq
  from public.messages
  where conversation_id = p_conv
  order by seq desc
  limit 1;

  insert into public.conversation_members(
    conversation_id, user_id, last_read_message_id, last_read_seq
  )
  values (p_conv, p_user, lm_id, coalesce(lm_seq, 0))
  on conflict (conversation_id, user_id) do update
    set left_at = null,
        joined_at = now(),
        last_read_message_id = excluded.last_read_message_id,
        last_read_seq = excluded.last_read_seq
    where public.conversation_members.left_at is not null;
end;
$function$;

revoke all on function public._join_member(uuid, uuid) from public, anon, authenticated;

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
  v_kicked_at timestamptz := now();
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
  set left_at = v_kicked_at
  where conversation_id = p_conv
    and user_id = p_user
    and left_at is null;

  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'member_not_active' using errcode = 'P0002';
  end if;

  insert into private.conversation_kick_bans(
    conversation_id, user_id, kicked_by, kicked_at, blocked_until
  )
  values (p_conv, p_user, v_uid, v_kicked_at, v_kicked_at + interval '3 days')
  on conflict (conversation_id, user_id) do update
    set kicked_by = excluded.kicked_by,
        kicked_at = excluded.kicked_at,
        blocked_until = excluded.blocked_until;

  insert into public.conversation_events(conversation_id, actor_id, target_id, event_type)
  values (p_conv, v_uid, p_user, 'kicked');
end;
$function$;

revoke all on function public.kick_room_member(uuid, uuid) from public, anon;
grant execute on function public.kick_room_member(uuid, uuid) to authenticated;
