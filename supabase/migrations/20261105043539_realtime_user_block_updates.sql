-- Keep the blocked party's UI synchronized immediately when a block is added or removed.
alter publication supabase_realtime add table public.user_blocks;
