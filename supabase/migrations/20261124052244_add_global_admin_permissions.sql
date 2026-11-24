create table if not exists private.app_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table private.app_admins enable row level security;
revoke all on private.app_admins from public, anon, authenticated;

create or replace function private.is_app_admin(p_user uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from private.app_admins a where a.user_id = p_user); $$;
revoke all on function private.is_app_admin(uuid) from public, anon, authenticated;

create or replace function public.list_admin_ids()
returns setof uuid language sql stable security definer set search_path = ''
as $$ select a.user_id from private.app_admins a; $$;
revoke all on function public.list_admin_ids() from public, anon;
grant execute on function public.list_admin_ids() to authenticated;

create or replace function public.admin_delete_message(p_message uuid)
returns void language plpgsql security definer set search_path = 'public', 'private', 'pg_temp'
as $$
declare uid uuid := auth.uid(); affected integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_app_admin(uid) then raise exception 'admin_only' using errcode = '42501'; end if;
  delete from public.messages where id = p_message;
  get diagnostics affected = row_count;
  if affected = 0 then raise exception 'message_not_found' using errcode = 'P0002'; end if;
end;
$$;
revoke all on function public.admin_delete_message(uuid) from public, anon;
grant execute on function public.admin_delete_message(uuid) to authenticated;

create or replace function public.admin_kick_member(p_conv uuid, p_user uuid)
returns void language plpgsql security definer set search_path = 'public', 'private', 'pg_temp'
as $$
declare uid uuid := auth.uid(); owner_uid uuid; kicked_at timestamptz := now(); affected integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_app_admin(uid) then raise exception 'admin_only' using errcode = '42501'; end if;
  if p_user is null or p_user = uid or private.is_app_admin(p_user) then
    raise exception 'invalid_kick_target' using errcode = '22023';
  end if;
  select c.owner_id into owner_uid from public.conversations c
  where c.id = p_conv and c.type in ('open','group') for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.conversation_members m
    where m.conversation_id = p_conv and m.user_id = p_user and m.left_at is null) then
    raise exception 'member_not_active' using errcode = 'P0002';
  end if;
  if owner_uid = p_user then
    insert into public.conversation_members(conversation_id,user_id,joined_at,left_at)
    values (p_conv,uid,kicked_at,null)
    on conflict (conversation_id,user_id) do update set left_at = null;
    update public.conversations set owner_id = uid where id = p_conv;
  end if;
  update public.conversation_members set left_at = kicked_at
  where conversation_id = p_conv and user_id = p_user and left_at is null;
  get diagnostics affected = row_count;
  if affected = 0 then raise exception 'member_not_active' using errcode = 'P0002'; end if;
  insert into private.conversation_kick_bans(conversation_id,user_id,kicked_by,kicked_at,blocked_until)
  values (p_conv,p_user,uid,kicked_at,kicked_at + interval '3 days')
  on conflict (conversation_id,user_id) do update
  set kicked_by=excluded.kicked_by,kicked_at=excluded.kicked_at,blocked_until=excluded.blocked_until;
  insert into public.conversation_events(conversation_id,actor_id,target_id,event_type)
  values (p_conv,uid,p_user,'kicked');
end;
$$;
revoke all on function public.admin_kick_member(uuid,uuid) from public, anon;
grant execute on function public.admin_kick_member(uuid,uuid) to authenticated;

create or replace function public.admin_delete_room(p_conv uuid, p_confirmation text)
returns void language plpgsql security definer set search_path = 'public', 'private', 'pg_temp'
as $$
declare uid uuid := auth.uid(); affected integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_app_admin(uid) then raise exception 'admin_only' using errcode = '42501'; end if;
  if p_confirmation is distinct from '삭제하겠습니다' then
    raise exception 'confirmation_text_mismatch' using errcode = '22023';
  end if;
  delete from public.conversations c where c.id = p_conv and c.type in ('open','group');
  get diagnostics affected = row_count;
  if affected = 0 then raise exception 'room_not_found' using errcode = 'P0002'; end if;
end;
$$;
revoke all on function public.admin_delete_room(uuid,text) from public, anon;
grant execute on function public.admin_delete_room(uuid,text) to authenticated;

create or replace function public.rename_room(p_conv uuid, p_name text)
returns void language plpgsql security definer set search_path = 'public', 'private', 'pg_temp'
as $$
declare uid uuid := auth.uid(); nm text := btrim(coalesce(p_name, ''));
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if nm = '' or char_length(nm) > 30 then raise exception 'invalid_room_name' using errcode = '22023'; end if;
  update public.conversations c set name = nm
  where c.id = p_conv and c.type in ('open','group')
    and (c.owner_id = uid or private.is_app_admin(uid));
  if not found then raise exception 'room_owner_only' using errcode = '42501'; end if;
end;
$$;
revoke all on function public.rename_room(uuid,text) from public, anon;
grant execute on function public.rename_room(uuid,text) to authenticated;
