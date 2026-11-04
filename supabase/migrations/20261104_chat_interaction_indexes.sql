-- 서고챗 메시지 상호작용 FK 인덱스
create index if not exists message_reactions_conversation_idx
  on public.message_reactions(conversation_id);
create index if not exists message_reactions_message_conversation_idx
  on public.message_reactions(message_id, conversation_id);
create index if not exists message_reactions_user_idx
  on public.message_reactions(user_id);
create index if not exists messages_reply_sender_idx
  on public.messages(reply_sender_id) where reply_sender_id is not null;
