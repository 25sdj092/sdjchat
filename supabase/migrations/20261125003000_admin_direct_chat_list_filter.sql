create or replace function public.admin_list_conversations()
returns table(id uuid,type text,name text,owner_id uuid,room_code text,last_message_at timestamptz)
language plpgsql stable security definer set search_path = 'public', 'private', 'pg_temp'
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_app_admin(auth.uid()) then raise exception 'admin_only' using errcode = '42501'; end if;
  return query
    select c.id,c.type,c.name,c.owner_id,c.room_code,c.last_message_at
    from public.conversations c
    where c.type <> 'direct'
       or exists (
         select 1 from public.conversation_members m
         where m.conversation_id=c.id and m.user_id=auth.uid() and m.left_at is null
       )
    order by c.last_message_at desc nulls last;
end;
$$;
