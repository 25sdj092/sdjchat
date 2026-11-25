insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'chat-audio','chat-audio',false,10485760,
  array['audio/webm','audio/ogg','audio/mp4','audio/mpeg']::text[]
)
on conflict (id) do update
set name=excluded.name, public=false, file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

create or replace function private.can_access_chat_audio_object(p_name text)
returns boolean language plpgsql stable security definer set search_path = 'public'
as $$
begin
  if p_name is null or p_name !~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](webm|ogg|mp4|mp3)$'
  then return false; end if;
  return private.is_active_member(split_part(p_name, '/', 1)::uuid);
end;
$$;
revoke all on function private.can_access_chat_audio_object(text) from public, anon, authenticated;
grant execute on function private.can_access_chat_audio_object(text) to authenticated;

drop policy if exists chat_audio_insert on storage.objects;
create policy chat_audio_insert on storage.objects for insert to authenticated
with check (bucket_id='chat-audio' and private.can_access_chat_audio_object(name));
drop policy if exists chat_audio_select on storage.objects;
create policy chat_audio_select on storage.objects for select to authenticated
using (bucket_id='chat-audio' and private.can_access_chat_audio_object(name));
drop policy if exists chat_audio_select_admin on storage.objects;
create policy chat_audio_select_admin on storage.objects for select to authenticated
using (bucket_id='chat-audio' and private.is_app_admin((select auth.uid())));
drop policy if exists chat_audio_delete_admin on storage.objects;
create policy chat_audio_delete_admin on storage.objects for delete to authenticated
using (bucket_id='chat-audio' and private.is_app_admin((select auth.uid())));

alter table public.messages drop constraint if exists messages_message_type_check;
alter table public.messages add constraint messages_message_type_check
check (message_type = any (array['text'::text,'image'::text,'gif'::text,'audio'::text]));
alter table public.messages drop constraint if exists messages_kind_chk;
alter table public.messages add constraint messages_kind_chk check (
  (message_type='text' and char_length(btrim(content))>=1 and storage_path is null and mime_type is null and file_size is null)
  or (message_type='image'
    and storage_path ~ (('^'::text || conversation_id::text) || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp|gif)$'::text)
    and mime_type = any(array['image/jpeg'::text,'image/png'::text,'image/webp'::text,'image/gif'::text])
    and file_size>=1 and file_size<=10485760)
  or (message_type='gif' and char_length(btrim(content))>=1 and char_length(btrim(content))<=2000
    and content ~* '^https://([a-z0-9-]+[.])*giphy[.]com/media/.+[.]gif([?].*)?$'
    and storage_path is null and mime_type is null and file_size is null)
  or (message_type='audio' and content=''
    and storage_path ~ (('^'::text || conversation_id::text) || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](webm|ogg|mp4|mp3)$')
    and mime_type = any(array['audio/webm'::text,'audio/ogg'::text,'audio/mp4'::text,'audio/mpeg'::text])
    and file_size>=1 and file_size<=10485760)
);

create or replace function public.validate_message_interactions()
returns trigger language plpgsql set search_path = 'public', 'pg_temp'
as $function$
declare parent public.messages;
begin
  if new.reply_to is not null then
    select * into parent from public.messages
    where id=new.reply_to and conversation_id=new.conversation_id;
    if not found then raise exception 'reply_target_invalid' using errcode='22023'; end if;
    new.reply_sender_id := parent.sender_id;
    new.reply_preview := case
      when parent.message_type='image' then '사진'
      when parent.message_type='gif' then 'GIF'
      when parent.message_type='audio' then '음성 메시지'
      else left(btrim(parent.content),90)
    end;
  else
    new.reply_sender_id := null;
    new.reply_preview := null;
  end if;
  if cardinality(coalesce(new.mention_user_ids,'{}'::uuid[])) > 0
     and exists (
       select 1 from unnest(new.mention_user_ids) as mentioned(user_id)
       where not exists (
         select 1 from public.conversation_members cm
         where cm.conversation_id=new.conversation_id
           and cm.user_id=mentioned.user_id and cm.left_at is null
       )
     )
  then raise exception 'mention_not_active_member' using errcode='22023'; end if;
  return new;
end;
$function$;
