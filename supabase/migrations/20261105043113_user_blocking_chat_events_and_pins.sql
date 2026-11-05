-- Add bidirectional user blocking, in-chat moderation events, and pins for every conversation type.

create table public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_no_self check (blocker_id <> blocked_id)
);
alter table public.user_blocks enable row level security;
create policy user_blocks_select_participants on public.user_blocks
  for select to authenticated
  using ((select auth.uid()) = blocker_id or (select auth.uid()) = blocked_id);
grant select on public.user_blocks to authenticated;

create table public.conversation_events (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  target_id uuid references public.profiles(id) on delete set null,
  event_type text not null check (event_type in ('kicked','blocked')),
  created_at timestamptz not null default now()
);
create index conversation_events_conversation_created_idx
  on public.conversation_events(conversation_id, created_at desc);
alter table public.conversation_events enable row level security;
create policy conversation_events_select_members on public.conversation_events
  for select to authenticated
  using (exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = conversation_events.conversation_id
      and cm.user_id = (select auth.uid())
  ));
grant select on public.conversation_events to authenticated;

create table public.conversation_pins (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  message_id uuid not null,
  pinned_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint conversation_pins_message_fk
    foreign key (message_id, conversation_id)
    references public.messages(id, conversation_id) on delete cascade,
  constraint conversation_pins_unique unique (conversation_id, message_id)
);
create index conversation_pins_conversation_created_idx
  on public.conversation_pins(conversation_id, created_at desc);
alter table public.conversation_pins enable row level security;
create policy conversation_pins_select_members on public.conversation_pins
  for select to authenticated
  using (private.is_active_member(conversation_id));
grant select on public.conversation_pins to authenticated;

create or replace function public.block_user(p_user uuid, p_blocked boolean default true)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_direct uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_user is null or p_user = v_uid then
    raise exception 'invalid_block_target' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  if p_blocked then
    insert into public.user_blocks(blocker_id, blocked_id)
    values (v_uid, p_user)
    on conflict do nothing;

    delete from public.friendships
    where (requester_id = v_uid and receiver_id = p_user)
       or (requester_id = p_user and receiver_id = v_uid);

    for v_direct in
      select c.id
      from public.conversations c
      where c.type = 'direct'
        and exists (select 1 from public.conversation_members m
          where m.conversation_id = c.id and m.user_id = v_uid)
        and exists (select 1 from public.conversation_members m
          where m.conversation_id = c.id and m.user_id = p_user)
    loop
      insert into public.conversation_events(conversation_id, actor_id, target_id, event_type)
      values (v_direct, v_uid, p_user, 'blocked');
    end loop;
  else
    delete from public.user_blocks
    where blocker_id = v_uid and blocked_id = p_user;
  end if;
end;
$function$;
revoke all on function public.block_user(uuid, boolean) from public, anon;
grant execute on function public.block_user(uuid, boolean) to authenticated;

create or replace function public.pin_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_conv uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select conversation_id into v_conv from public.messages where id = p_message;
  if not found then raise exception 'message_not_found' using errcode = 'P0002'; end if;
  if not private.is_active_member(v_conv) then
    raise exception 'not_active_member' using errcode = '42501';
  end if;
  insert into public.conversation_pins(conversation_id, message_id, pinned_by)
  values (v_conv, p_message, v_uid)
  on conflict (conversation_id, message_id) do nothing;
end;
$function$;
revoke all on function public.pin_message(uuid) from public, anon;
grant execute on function public.pin_message(uuid) to authenticated;

create or replace function public.unpin_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_conv uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select conversation_id into v_conv from public.messages where id = p_message;
  if not found then raise exception 'message_not_found' using errcode = 'P0002'; end if;
  if not private.is_active_member(v_conv) then
    raise exception 'not_active_member' using errcode = '42501';
  end if;
  delete from public.conversation_pins
  where conversation_id = v_conv and message_id = p_message;
end;
$function$;
revoke all on function public.unpin_message(uuid) from public, anon;
grant execute on function public.unpin_message(uuid) to authenticated;

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
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_user is null or p_user = v_uid then
    raise exception 'invalid_kick_target' using errcode = '22023';
  end if;

  select c.owner_id into v_owner
  from public.conversations c
  where c.id = p_conv and c.type in ('open','group')
  for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0002'; end if;
  if v_owner is distinct from v_uid or not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conv and cm.user_id = v_uid and cm.left_at is null
  ) then
    raise exception 'room_owner_only' using errcode = '42501';
  end if;

  update public.conversation_members set left_at = now()
  where conversation_id = p_conv and user_id = p_user and left_at is null;
  get diagnostics affected = row_count;
  if affected = 0 then raise exception 'member_not_active' using errcode = 'P0002'; end if;

  insert into public.conversation_events(conversation_id, actor_id, target_id, event_type)
  values (p_conv, v_uid, p_user, 'kicked');
end;
$function$;
revoke all on function public.kick_room_member(uuid, uuid) from public, anon;
grant execute on function public.kick_room_member(uuid, uuid) to authenticated;

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and private.is_active_member(conversation_id)
  and not exists (
    select 1
    from public.conversations c
    join public.conversation_members other_member
      on other_member.conversation_id = c.id
     and other_member.user_id <> (select auth.uid())
     and other_member.left_at is null
    join public.user_blocks ub
      on (ub.blocker_id = (select auth.uid()) and ub.blocked_id = other_member.user_id)
      or (ub.blocker_id = other_member.user_id and ub.blocked_id = (select auth.uid()))
    where c.id = conversation_id and c.type = 'direct'
  )
);

create or replace function public.send_friend_request(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare uid uuid := auth.uid(); target uuid; f public.friendships; attempts integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode='28000'; end if;
  if p_code is null or p_code !~ '^[0-9]{4}$' then raise exception 'invalid_code' using errcode='22023'; end if;
  if not exists(select 1 from public.profiles where id=uid) then
    raise exception 'no_profile' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtext(uid::text));
  delete from public.code_lookup_attempts where user_id=uid and attempted_at<now()-interval '1 hour';
  select count(*) into attempts from public.code_lookup_attempts
    where user_id=uid and attempted_at>now()-interval '10 minutes';
  if attempts>=10 then raise exception 'lookup_rate_limited' using errcode='P0001'; end if;
  insert into public.code_lookup_attempts(user_id) values(uid);

  select id into target from public.profiles where user_code=p_code;
  if not found then raise exception 'user_not_found' using errcode='P0002'; end if;
  if target=uid then raise exception 'self' using errcode='22023'; end if;
  if exists (
    select 1 from public.user_blocks
    where (blocker_id=uid and blocked_id=target)
       or (blocker_id=target and blocked_id=uid)
  ) then raise exception 'user_blocked' using errcode='42501'; end if;

  select * into f from public.friendships
    where least(requester_id,receiver_id)=least(uid,target)
      and greatest(requester_id,receiver_id)=greatest(uid,target);
  if found then
    if f.status='accepted' then return 'already_friends'; end if;
    if f.requester_id=uid then return 'already_sent'; end if;
    perform public._accept_friendship(f.id);
    return 'accepted';
  end if;
  insert into public.friendships(requester_id,receiver_id) values(uid,target) on conflict do nothing;
  return 'sent';
end;
$function$;

alter publication supabase_realtime add table public.conversation_events;
alter publication supabase_realtime add table public.conversation_pins;
