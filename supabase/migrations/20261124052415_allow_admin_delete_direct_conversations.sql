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
  delete from public.conversations where id = p_conv;
  get diagnostics affected = row_count;
  if affected = 0 then raise exception 'conversation_not_found' using errcode = 'P0002'; end if;
end;
$$;
revoke all on function public.admin_delete_room(uuid,text) from public, anon;
grant execute on function public.admin_delete_room(uuid,text) to authenticated;
