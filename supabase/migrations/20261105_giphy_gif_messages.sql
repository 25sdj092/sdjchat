-- GIPHY GIF messages store only the API-provided HTTPS media URL, not uploaded file copies.
alter table public.messages
  drop constraint if exists messages_kind_chk;

alter table public.messages
  add constraint messages_kind_chk check (
    (
      message_type = 'text'
      and char_length(btrim(content)) >= 1
      and storage_path is null and mime_type is null and file_size is null
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
      and content ~ '^https://([A-Za-z0-9-]+[.])?giphy[.]com/media/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+[.]gif([?].*)?
      and storage_path is null and mime_type is null and file_size is null
    )
  );

create or replace function public.validate_message_interactions()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  parent public.messages;
begin
  if new.reply_to is not null then
    select * into parent
    from public.messages
    where id = new.reply_to
      and conversation_id = new.conversation_id;

    if not found then
      raise exception 'reply_target_invalid' using errcode = '22023';
    end if;

    new.reply_sender_id := parent.sender_id;
    new.reply_preview := case
      when parent.message_type = 'image' then '사진'
      when parent.message_type = 'gif' then 'GIF'
      else left(btrim(parent.content), 90)
    end;
  else
    new.reply_sender_id := null;
    new.reply_preview := null;
  end if;

  if cardinality(coalesce(new.mention_user_ids, '{}'::uuid[])) > 0
     and exists (
       select 1
       from unnest(new.mention_user_ids) as mentioned(user_id)
       where not exists (
         select 1
         from public.conversation_members cm
         where cm.conversation_id = new.conversation_id
           and cm.user_id = mentioned.user_id
           and cm.left_at is null
       )
     )
  then
    raise exception 'mention_not_active_member' using errcode = '22023';
  end if;

  return new;
end;
$$;

      and storage_path is null and mime_type is null and file_size is null
    )
  );

create or replace function public.validate_message_interactions()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  parent public.messages;
begin
  if new.reply_to is not null then
    select * into parent
    from public.messages
    where id = new.reply_to
      and conversation_id = new.conversation_id;

    if not found then
      raise exception 'reply_target_invalid' using errcode = '22023';
    end if;

    new.reply_sender_id := parent.sender_id;
    new.reply_preview := case
      when parent.message_type = 'image' then '사진'
      when parent.message_type = 'gif' then 'GIF'
      else left(btrim(parent.content), 90)
    end;
  else
    new.reply_sender_id := null;
    new.reply_preview := null;
  end if;

  if cardinality(coalesce(new.mention_user_ids, '{}'::uuid[])) > 0
     and exists (
       select 1
       from unnest(new.mention_user_ids) as mentioned(user_id)
       where not exists (
         select 1
         from public.conversation_members cm
         where cm.conversation_id = new.conversation_id
           and cm.user_id = mentioned.user_id
           and cm.left_at is null
       )
     )
  then
    raise exception 'mention_not_active_member' using errcode = '22023';
  end if;

  return new;
end;
$$;
