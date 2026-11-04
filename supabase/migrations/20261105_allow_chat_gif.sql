-- 서고챗: GIF 채팅 업로드 허용
begin;

alter table public.messages
  drop constraint if exists messages_kind_chk;

alter table public.messages
  add constraint messages_kind_chk check (
    (message_type = 'text'
      and char_length(btrim(content)) >= 1
      and storage_path is null and mime_type is null and file_size is null)
    or
    (message_type = 'image'
      and storage_path ~ ('^' || conversation_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp|gif)$')
      and mime_type in ('image/jpeg','image/png','image/webp','image/gif')
      and file_size between 1 and 10485760)
  );

create or replace function private.can_access_chat_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_name is null or p_name !~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp|gif)$'
  then
    return false;
  end if;
  return private.is_active_member(split_part(p_name, '/', 1)::uuid);
end;
$$;

update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'],
    file_size_limit = 10485760,
    public = false
where id = 'chat-images';

commit;
