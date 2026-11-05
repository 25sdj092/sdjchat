-- The original column CHECK only allowed text and image, independently of messages_kind_chk.
-- Add gif without weakening the allowed message-type set.
alter table public.messages
  drop constraint if exists messages_message_type_check;

alter table public.messages
  add constraint messages_message_type_check
  check (message_type in ('text', 'image', 'gif'));
