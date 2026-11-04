-- 서고챗: 프로필/방 이름 수정, 6자리 코드방, 방장 삭제, 온라인 상태 기반
begin;

-- 대화방 유형: direct(개인 DM), open(공개 오픈채팅), group(6자리 코드방)
alter table public.conversations
  add column if not exists room_code text;

alter table public.conversations
  drop constraint if exists conversations_type_check,
  drop constraint if exists conversations_shape_check,
  drop constraint if exists conversations_room_code_check;

alter table public.conversations
  add constraint conversations_type_check
    check (type in ('direct','open','group')),
  add constraint conversations_room_code_check
    check (room_code is null or room_code ~ '^[0-9]{6}$'),
  add constraint conversations_shape_check check (
    (type = 'open' and name is not null and created_by is not null and direct_key is null and room_code is null) or
    (type = 'group' and name is not null and created_by is not null and direct_key is null and room_code is not null) or
    (type = 'direct' and name is null and created_by is null and direct_key is not null and room_code is null)
  );

create unique index if not exists conversations_room_code_uq
  on public.conversations(room_code) where room_code is not null;

-- 6자리 코드 입력 시도 제한. 클라이언트는 테이블에 직접 접근할 수 없다.
create table if not exists public.room_join_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index if not exists room_join_attempts_user_time_idx
  on public.room_join_attempts(user_id, attempted_at desc);
alter table public.room_join_attempts enable row level security;
revoke all on public.room_join_attempts from public, anon, authenticated;

-- 내 회원가입 이름 변경
create or replace function public.update_my_name(p_name text)
returns public.profiles
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  nm text := btrim(coalesce(p_name, ''));
  result public.profiles;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if nm !~ '^[가-힣0-9]{1,12}$' then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  update public.profiles set username = nm
    where id = uid
    returning * into result;
  if not found then raise exception 'profile_not_found' using errcode = 'P0002'; end if;
  return result;
end $$;

-- 6자리 코드방 생성: 생성자는 방장/첫 참여자가 된다.
create or replace function public.create_code_room(p_name text)
returns public.conversations
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  nm text := btrim(coalesce(p_name, ''));
  code text;
  result public.conversations;
  tries integer := 0;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'no_profile' using errcode = '22023';
  end if;
  if nm = '' or char_length(nm) > 30 then
    raise exception 'invalid_room_name' using errcode = '22023';
  end if;

  loop
    tries := tries + 1;
    if tries > 100 then raise exception 'room_codes_exhausted' using errcode = '53400'; end if;
    code := lpad(floor(random() * 1000000)::bigint::text, 6, '0');
    begin
      insert into public.conversations(type, name, owner_id, created_by, room_code)
      values ('group', nm, uid, uid, code)
      returning * into result;
      exit;
    exception when unique_violation then
      -- 코드 충돌이면 새 번호를 뽑는다.
      if exists (select 1 from public.conversations where room_code = code) then
        null;
      else
        raise;
      end if;
    end;
  end loop;
  perform public._join_member(result.id, uid);
  return result;
end $$;

-- 6자리 코드 참가. 10분간 10회로 제한한다.
create or replace function public.join_code_room(p_code text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  room_id uuid;
  attempts integer;
  already_joined boolean;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'no_profile' using errcode = '22023';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'invalid_room_code' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext(uid::text || ':room-code'));
  delete from public.room_join_attempts
    where user_id = uid and attempted_at < now() - interval '1 hour';
  select count(*) into attempts from public.room_join_attempts
    where user_id = uid and attempted_at > now() - interval '10 minutes';
  if attempts >= 10 then raise exception 'room_lookup_rate_limited' using errcode = 'P0001'; end if;
  insert into public.room_join_attempts(user_id) values (uid);

  select id into room_id from public.conversations
    where room_code = p_code and type = 'group' for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0002'; end if;

  select exists (
    select 1 from public.conversation_members
    where conversation_id = room_id and user_id = uid and left_at is null
  ) into already_joined;

  perform public._join_member(room_id, uid);
  return jsonb_build_object('ok', true, 'id', room_id, 'already', already_joined);
end $$;

-- 방 이름 변경: 참여 중인 방의 방장만 변경 가능
create or replace function public.rename_room(p_conv uuid, p_name text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  nm text := btrim(coalesce(p_name, ''));
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if nm = '' or char_length(nm) > 30 then
    raise exception 'invalid_room_name' using errcode = '22023';
  end if;
  update public.conversations c set name = nm
  where c.id = p_conv and c.type in ('open','group')
    and c.owner_id = uid
    and exists (
      select 1 from public.conversation_members m
      where m.conversation_id = c.id and m.user_id = uid and m.left_at is null
    );
  if not found then raise exception 'room_owner_only' using errcode = '42501'; end if;
end $$;

-- 방 삭제: 방장 + 정확한 확인 문구 필수
create or replace function public.delete_room(p_conv uuid, p_confirmation text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  affected integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_confirmation is distinct from '삭제하겠습니다' then
    raise exception 'confirmation_text_mismatch' using errcode = '22023';
  end if;
  delete from public.conversations c
  where c.id = p_conv and c.type in ('open','group') and c.owner_id = uid
    and exists (
      select 1 from public.conversation_members m
      where m.conversation_id = c.id and m.user_id = uid and m.left_at is null
    );
  get diagnostics affected = row_count;
  if affected = 0 then raise exception 'room_owner_only' using errcode = '42501'; end if;
end $$;

-- 참여자가 나가기. 방장이 나가면 가장 오래 남아 있는 참여자에게 방장 권한을 넘긴다.
create or replace function public.leave_room(p_conv uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  room public.conversations;
  members_left integer;
  next_owner uuid;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into room from public.conversations
    where id = p_conv and type in ('open','group') for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0002'; end if;

  update public.conversation_members set left_at = now()
    where conversation_id = p_conv and user_id = uid and left_at is null;
  if not found then return; end if;

  select count(*) into members_left from public.conversation_members
    where conversation_id = p_conv and left_at is null;
  if members_left = 0 then
    delete from public.conversations where id = p_conv;
    return;
  end if;

  if room.owner_id = uid then
    select user_id into next_owner from public.conversation_members
      where conversation_id = p_conv and left_at is null order by joined_at limit 1;
    update public.conversations set owner_id = next_owner where id = p_conv;
  end if;
end $$;

-- 방장만 chat-images 객체를 삭제할 수 있다. 클라이언트는 Storage API를 사용한다.
drop policy if exists chat_images_delete_owner on storage.objects;
create policy chat_images_delete_owner on storage.objects
for delete to authenticated
using (
  bucket_id = 'chat-images'
  and exists (
    select 1 from public.conversations c
    where c.id::text = split_part(storage.objects.name, '/', 1)
      and c.type in ('open','group')
      and c.owner_id = (select auth.uid())
  )
);

-- profiles UPDATE/DELETE/INSERT not exposed to the client; RPC is the only edit path.
revoke all on function public.update_my_name(text), public.create_code_room(text),
  public.join_code_room(text), public.rename_room(uuid,text),
  public.delete_room(uuid,text), public.leave_room(uuid)
  from public, anon, authenticated;
grant execute on function public.update_my_name(text), public.create_code_room(text),
  public.join_code_room(text), public.rename_room(uuid,text),
  public.delete_room(uuid,text), public.leave_room(uuid)
  to authenticated;

-- 프로필/대화방 변경 내용을 Realtime으로 전달한다.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profiles'
  ) then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;

commit;
