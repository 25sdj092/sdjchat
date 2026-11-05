-- Add the red angry-face reaction to the supported reaction set.
alter table public.message_reactions
  drop constraint if exists message_reactions_emoji_check;

alter table public.message_reactions
  add constraint message_reactions_emoji_check
  check (emoji in ('👍', '❤️', '😂', '😮', '😢', '🎉', '😡'));
