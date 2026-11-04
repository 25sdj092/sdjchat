-- 서대전챗: 계정 초기화 + 코드방 제거 + 공개 오픈채팅 전환
-- 이 마이그레이션은 현재 계정과 대화 데이터를 영구 삭제합니다.
begin;

-- 요청한 초기화: 모든 계정과 현재 방/DM/메시지를 삭제한다.
-- conversations 삭제로 messages와 conversation_members가 cascade 삭제된다.
delete from public.conversations;
delete from auth.users;
-- 기존 코드 기반 그룹방 RPC를 제거한다.
drop function if exists public.create_room(text);
drop function if exists public.join_room(text);
drop function if exists public.leave_room(uuid);

delete from public.join_failures;
drop table if exists public.join_failures;

-- 새 이름 규칙: 한글 완성형 음절 + 숫자, 1~12자
alter table public.profiles drop constraint if exists profiles_username_length_chk;
alter table public.profiles drop constraint if exists profiles_username_check;
alter table public.profiles drop constraint if exists profiles_username_format_chk;
alter table public.profiles
  add constraint profiles_username_format_chk
  check (username ~ '^[가-힣0-9]{1,12}$');

-- 숫자 방 코드를 제거하고 direct/open 두 종류만 허용한다.
alter table public.conversations
  drop constraint if exists conversations_check,
  drop constraint if exists conversations_type_check,
  drop constraint if exists conversations_room_code_check,
  drop constraint if exists conversations_room_code_key;
alter table public.conversations drop column if exists room_code;
alter table public.conversations
  add column if not exists created_by uuid references public.profiles(id) on delete cascade,
  add column if not exists last_message_at timestamptz,
  add column if not exists member_count_updated_at timestamptz;
alter table public.conversations
  add constraint conversations_type_check check (type in ('direct','open')),
  add constraint conversations_shape_check check (
    (type = 'open' and name is not null and created_by is not null and direct_key is null) or
    (type = 'direct' and name is null and created_by is null and direct_key is not null)
  );
create unique index if not exists conversations_open_creator_uq
  on public.conversations(created_by) where type = 'open';

-- 회원가입 이름 검증은 DB에서도 강제한다.
create or replace function public.create_profile(p_name text)
returns public.profiles language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.profiles; nm text; code text; n int := 0;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.profiles where id = uid;
  if found then return r; end if;
  nm := coalesce(p_name, '');
  if nm !~ '^[가-힣0-9]{1,12}$' then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  loop
    n := n + 1;
    if n <= 30 then
      code := lpad(floor(random() * 10000)::int::text, 4, '0');
    else
      select lpad(g::text, 4, '0') into code
      from generate_series(0, 9999) g
      where not exists (select 1 from public.profiles p where p.user_code = lpad(g::text, 4, '0'))
      order by random() limit 1;
      if code is null then raise exception 'codes_exhausted' using errcode = '53400'; end if;
    end if;
    begin
      insert into public.profiles (id, username, user_code) values (uid, nm, code) returning * into r;
      return r;
    exception when unique_violation then
      select * into r from public.profiles where id = uid;
      if found then return r; end if;
      if n >= 100 then raise exception 'codes_exhausted' using errcode = '53400'; end if;
    end;
  end loop;
end $$;

-- 본인이 만든 오픈채팅방은 1개로 제한한다. 남의 방에는 여러 개 참가 가능.
create or replace function public.create_open_room(p_name text)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text; r public.conversations;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'no_profile' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  if exists (select 1 from public.conversations where type = 'open' and created_by = uid) then
    raise exception 'open_room_limit' using errcode = 'P0001';
  end if;
  nm := btrim(coalesce(p_name, ''));
  if nm = '' or char_length(nm) > 30 then
    raise exception 'invalid_room_name' using errcode = '22023';
  end if;
  insert into public.conversations (type, name, owner_id, created_by)
  values ('open', nm, uid, uid)
  returning * into r;
  perform public._join_member(r.id, uid);
  return r;
end $$;

create or replace function public.join_open_room(p_conv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); room_id uuid;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'no_profile' using errcode = '22023';
  end if;
  select id into room_id from public.conversations
    where id = p_conv and type = 'open' for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if exists (select 1 from public.conversation_members
    where conversation_id = room_id and user_id = uid and left_at is null) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  perform public._join_member(room_id, uid);
  return jsonb_build_object('ok', true, 'already', false);
end $$;

create or replace function public.leave_open_room(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); room public.conversations; n integer; next_owner uuid;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into room from public.conversations where id = p_conv and type = 'open' for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0002'; end if;
  update public.conversation_members set left_at = now()
    where conversation_id = p_conv and user_id = uid and left_at is null;
  if not found then return; end if;
  select count(*) into n from public.conversation_members
    where conversation_id = p_conv and left_at is null;
  if n = 0 then
    delete from public.conversations where id = p_conv;
    return;
  end if;
  if room.owner_id = uid then
    select user_id into next_owner from public.conversation_members
      where conversation_id = p_conv and left_at is null order by joined_at limit 1;
    update public.conversations set owner_id = next_owner where id = p_conv;
  end if;
end $$;

-- 공개 목록은 방 이름/참여 인원/최근 24시간 메시지 수만 반환한다.
create or replace function public.list_open_rooms()
returns table (
  id uuid, name text, member_count bigint,
  recent_messages bigint, last_message_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select c.id, c.name,
    (select count(*) from public.conversation_members cm
      where cm.conversation_id = c.id and cm.left_at is null) as member_count,
    (select count(*) from public.messages m
      where m.conversation_id = c.id and m.created_at >= now() - interval '24 hours') as recent_messages,
    coalesce(c.last_message_at, (
      select max(m.created_at) from public.messages m where m.conversation_id = c.id
    )) as last_message_at
  from public.conversations c
  where c.type = 'open' and auth.uid() is not null
  order by recent_messages desc, last_message_at desc nulls last, c.created_at desc
  limit 100
$$;

-- 메시지 insert 후 오픈채팅 활동 시각을 갱신한다.
create or replace function private.touch_open_room_activity()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = new.created_at
    where id = new.conversation_id and type = 'open';
  return new;
end $$;
drop trigger if exists messages_touch_open_room on public.messages;
create trigger messages_touch_open_room after insert on public.messages
  for each row execute function private.touch_open_room_activity();

create or replace function private.touch_open_room_members()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set member_count_updated_at = now()
    where id = new.conversation_id and type = 'open';
  return new;
end $$;
drop trigger if exists members_touch_open_room on public.conversation_members;
create trigger members_touch_open_room after insert or update of left_at on public.conversation_members
  for each row execute function private.touch_open_room_members();

-- 오픈채팅 행은 로그인 사용자 모두에게 공개하되, 메시지/참여자 데이터는 기존 RLS를 유지한다.
drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select to authenticated
  using (type = 'open' or private.is_active_member(id));

-- 새 목록은 대화방의 last_message_at 업데이트를 Realtime으로 알 수 있어야 한다.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversations'
  ) then
    alter publication supabase_realtime add table public.conversations;
  end if;
end $$;

-- 새 함수는 인증된 사용자만 호출 가능.
revoke all on function public.create_open_room(text), public.join_open_room(uuid),
  public.leave_open_room(uuid), public.list_open_rooms() from public, anon, authenticated;
grant execute on function public.create_open_room(text), public.join_open_room(uuid),
  public.leave_open_room(uuid), public.list_open_rooms() to authenticated;
revoke all on function private.touch_open_room_activity() from public, anon, authenticated;
revoke all on function private.touch_open_room_members() from public, anon, authenticated;

commit;
