create or replace function public.admin_list_conversations()
returns table(id uuid,type text,name text,owner_id uuid,room_code text,last_message_at timestamptz)
language plpgsql stable security definer set search_path = 'public', 'private', 'pg_temp'
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_app_admin(auth.uid()) then raise exception 'admin_only' using errcode = '42501'; end if;
  return query select c.id,c.type,c.name,c.owner_id,c.room_code,c.last_message_at
    from public.conversations c order by c.last_message_at desc nulls last;
end;
$$;
revoke all on function public.admin_list_conversations() from public, anon;
grant execute on function public.admin_list_conversations() to authenticated;

drop policy if exists conversations_admin_select on public.conversations;
create policy conversations_admin_select on public.conversations for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists members_admin_select on public.conversation_members;
create policy members_admin_select on public.conversation_members for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists messages_admin_select on public.messages;
create policy messages_admin_select on public.messages for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists profiles_admin_select on public.profiles;
create policy profiles_admin_select on public.profiles for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists conversation_events_admin_select on public.conversation_events;
create policy conversation_events_admin_select on public.conversation_events for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists conversation_pins_admin_select on public.conversation_pins;
create policy conversation_pins_admin_select on public.conversation_pins for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists message_reactions_admin_select on public.message_reactions;
create policy message_reactions_admin_select on public.message_reactions for select to authenticated
using (private.is_app_admin((select auth.uid())));
drop policy if exists chat_images_select_admin on storage.objects;
create policy chat_images_select_admin on storage.objects for select to authenticated
using (bucket_id = 'chat-images' and private.is_app_admin((select auth.uid())));
