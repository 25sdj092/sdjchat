-- 서고챗: 닉네임 중복 방지/7일 변경 제한/메시지 상호작용
begin;

alter table public.profiles
  add column if not exists username_changed_at timestamptz;

create unique index if not exists profiles_username_lower_uq
  on public.profiles (lower(username));

create or replace function public.create_profile(p_name text)
returns public.profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  uid uuid := auth.uid();
  r public.profiles;
  nm text := btrim(coalesce(p_name, ''));
  code text;
  n integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select * into r from public.profiles where id = uid;
  if found then return r; end if;

  if nm !~ '^[가-힣0-9]{1,12}$' then
    raise exception 'invalid_name' using errcode = '22023';
  end if;

  if exists (select 1 from public.profiles where lower(username) = lower(nm)) then
    raise exception 'username_taken' using errcode = '23505';
  end if;

  loop
    n := n + 1;
    if n <= 30 then
      code := lpad(floor(random() * 10000)::int::text, 4, '0');
    else
      select lpad(g::text, 4, '0') into code
      from generate_series(0, 9999) g
      where not exists (
        select 1 from public.profiles p where p.user_code = lpad(g::text, 4, '0')
      )
      order by random()
      limit 1;
      if code is null then
        raise exception 'codes_exhausted' using errcode = '53400';
      end if;
    end if;

    begin
      insert into public.profiles (id, username, user_code)
      values (uid, nm, code)
      returning * into r;
      return r;
    exception when unique_violation then
      select * into r from public.profiles where id = uid;
      if found then return r; end if;

      if exists (select 1 from public.profiles where lower(username) = lower(nm)) then
        raise exception 'username_taken' using errcode = '23505';
      end if;

      if n >= 100 then
        raise exception 'codes_exhausted' using errcode = '53400';
      end if;
    end;
  end loop;
end;
$$;

create or replace function public.update_my_name(p_name text)
returns public.profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  uid uuid := auth.uid();
  nm text := btrim(coalesce(p_name, ''));
  current_profile public.profiles;
  result public.profiles;
  next_change timestamptz;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if nm !~ '^[가-힣0-9]{1,12}$' then
    raise exception 'invalid_name' using errcode = '22023';
  end if;

  select * into current_profile
  from public.profiles
  where id = uid
  for update;

  if not found then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  if current_profile.username = nm then
    return current_profile;
  end if;

  if current_profile.username_changed_at is not null then
    next_change := current_profile.username_changed_at + interval '7 days';
    if now() < next_change then
      raise exception 'name_change_cooldown:%',
        to_char(next_change at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI')
        using errcode = 'P0001';
    end if;
  end if;

  begin
    update public.profiles
    set username = nm, username_changed_at = now()
    where id = uid
    returning * into result;
  exception when unique_violation then
    raise exception 'username_taken' using errcode = '23505';
  end;

  return result;
end;
$$;

alter table public.messages
  add column if not exists reply_to uuid references public.messages(id) on delete set null,
  add column if not exists reply_sender_id uuid references public.profiles(id) on delete set null,
  add column if not exists reply_preview text,
  add column if not exists mention_user_ids uuid[] not null default '{}'::uuid[];

create index if not exists messages_reply_to_idx
  on public.messages(reply_to) where reply_to is not null;

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

drop trigger if exists messages_validate_interactions on public.messages;
create trigger messages_validate_interactions
before insert on public.messages
for each row
execute function public.validate_message_interactions();

create table if not exists public.message_reactions (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  message_id uuid not null,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('👍','❤️','😂','😮','😢','🎉')),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji),
  constraint message_reactions_message_fk
    foreign key (message_id, conversation_id)
    references public.messages(id, conversation_id) on delete cascade
);

create unique index if not exists messages_id_conversation_uq
  on public.messages(id, conversation_id);

alter table public.message_reactions enable row level security;
revoke all on public.message_reactions from public, anon, authenticated;
grant select, insert, delete on public.message_reactions to authenticated;

drop policy if exists message_reactions_select on public.message_reactions;
create policy message_reactions_select on public.message_reactions
for select to authenticated
using (private.is_active_member(conversation_id));

drop policy if exists message_reactions_insert on public.message_reactions;
create policy message_reactions_insert on public.message_reactions
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_active_member(conversation_id)
);

drop policy if exists message_reactions_delete on public.message_reactions;
create policy message_reactions_delete on public.message_reactions
for delete to authenticated
using (
  user_id = (select auth.uid())
  and private.is_active_member(conversation_id)
);

alter table public.message_reactions replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end;
$$;

revoke all on function public.create_profile(text),
  public.update_my_name(text),
  public.validate_message_interactions()
  from public, anon, authenticated;
grant execute on function public.create_profile(text),
  public.update_my_name(text)
  to authenticated;

commit;
