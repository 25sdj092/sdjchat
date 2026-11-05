-- Align the GIF media URL constraint with the GIPHY CDN host and path validation.
-- Accept GIPHY subdomains at any depth while keeping HTTPS + /media/*.gif requirements.
alter table public.messages
  drop constraint if exists messages_kind_chk;

alter table public.messages
  add constraint messages_kind_chk check (
    (
      message_type = 'text'
      and char_length(btrim(content)) >= 1
      and storage_path is null
      and mime_type is null
      and file_size is null
    )
    or
    (
      message_type = 'image'
      and storage_path ~ ('^' || conversation_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp|gif)$')
      and mime_type in ('image/jpeg','image/png','image/webp','image/gif')
      and file_size between 1 and 10485760
    )
    or
    (
      message_type = 'gif'
      and char_length(btrim(content)) between 1 and 2000
      and content ~* '^https://([a-z0-9-]+[.])*giphy[.]com/media/.+[.]gif([?].*)?$'
      and storage_path is null
      and mime_type is null
      and file_size is null
    )
  );
