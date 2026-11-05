-- Add indexes for cleanup and profile foreign-key lookups.
create index if not exists conversation_kick_bans_user_idx
  on private.conversation_kick_bans(user_id);

create index if not exists conversation_kick_bans_kicked_by_idx
  on private.conversation_kick_bans(kicked_by)
  where kicked_by is not null;
