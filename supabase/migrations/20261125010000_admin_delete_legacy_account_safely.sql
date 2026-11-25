create or replace function public.is_current_app_admin()
returns boolean language sql stable security definer
set search_path = 'public', 'private', 'pg_temp'
as $$ select auth.uid() is not null and private.is_app_admin(auth.uid()); $$;
revoke all on function public.is_current_app_admin() from public, anon;
grant execute on function public.is_current_app_admin() to authenticated;

create or replace function public.admin_cleanup_legacy_account(p_user uuid)
returns jsonb language plpgsql security definer
set search_path = 'public', 'private', 'pg_temp'
as $$
declare admin_uid uuid := auth.uid(); deleted_dms integer := 0; detached_memberships integer := 0;
begin
  if admin_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_app_admin(admin_uid) then raise exception 'admin_only' using errcode = '42501'; end if;
  if p_user is null or p_user = admin_uid then raise exception 'invalid_target' using errcode = '22023'; end if;
  if not exists(select 1 from public.profiles where id=p_user) then raise exception 'profile_not_found' using errcode = 'P0002'; end if;
  if private.is_app_admin(p_user) then raise exception 'cannot_delete_admin' using errcode = '42501'; end if;
  update public.conversations
  set owner_id=case when owner_id=p_user then admin_uid else owner_id end,
      created_by=case when created_by=p_user then admin_uid else created_by end
  where type in ('open','group') and (owner_id=p_user or created_by=p_user);
  delete from public.conversations c where c.type='direct'
    and exists(select 1 from public.conversation_members m where m.conversation_id=c.id and m.user_id=p_user);
  get diagnostics deleted_dms = row_count;
  delete from public.friendships where requester_id=p_user or receiver_id=p_user;
  delete from public.conversation_members where user_id=p_user;
  get diagnostics detached_memberships = row_count;
  return jsonb_build_object('deleted_direct_conversations',deleted_dms,'removed_room_memberships',detached_memberships);
end;
$$;
revoke all on function public.admin_cleanup_legacy_account(uuid) from public, anon;
grant execute on function public.admin_cleanup_legacy_account(uuid) to authenticated;
