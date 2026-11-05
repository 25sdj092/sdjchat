-- Include conversation_id on pin DELETE events so clients can refresh only the affected chat.
alter table public.conversation_pins replica identity full;
