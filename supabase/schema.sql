-- =====================================================================
-- 메신저 Supabase 스키마
-- Supabase 대시보드 > SQL Editor 에서 이 파일 전체를 한 번에 실행하세요.
-- 여러 번 실행해도 안전하도록 작성되어 있습니다(idempotent).
-- =====================================================================

create extension if not exists pg_net;      -- 새 메시지 → Edge Function 호출용

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------

-- 사용자 프로필 (Supabase Auth 익명 사용자 1명 = 프로필 1개)
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null constraint profiles_username_format_chk check (username ~ '^[가-힣0-9]{1,12}$'),
  user_code   text not null unique check (user_code ~ '^[0-9]{4}$'),   -- 공개 식별자. 인증 수단 아님
  created_at  timestamptz not null default now()
);

-- 친구 관계. (A,B)와 (B,A)는 같은 관계로 취급해 중복을 막는다.
create table if not exists public.friendships (
  id            uuid primary key default gen_random_uuid(),
  requester_id  uuid not null constraint friendships_requester_id_fkey references public.profiles(id) on delete cascade,
  receiver_id   uuid not null constraint friendships_receiver_id_fkey  references public.profiles(id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending','accepted')),
  created_at    timestamptz not null default now(),
  check (requester_id <> receiver_id)
);
create unique index if not exists friendships_pair_uq
  on public.friendships (least(requester_id, receiver_id), greatest(requester_id, receiver_id));
create index if not exists friendships_receiver_idx  on public.friendships (receiver_id, status);
create index if not exists friendships_requester_idx on public.friendships (requester_id);

-- 대화방: 개인 DM(direct) 또는 공개 오픈채팅(open)
create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  type            text not null check (type in ('direct','open')),
  name            text check (name is null or char_length(name) between 1 and 30),
  owner_id        uuid references public.profiles(id) on delete set null,
  created_by      uuid references public.profiles(id) on delete cascade,
  direct_key      text unique,
  last_message_at timestamptz,
  member_count_updated_at timestamptz,
  created_at      timestamptz not null default now(),
  check (
    (type = 'open' and name is not null and created_by is not null and direct_key is null) or
    (type = 'direct' and name is null and created_by is null and direct_key is not null)
  )
);
create unique index if not exists conversations_open_creator_uq
  on public.conversations(created_by) where type = 'open';

-- 메시지. seq 는 대화 순서와 읽음 위치 비교에 쓰는 전역 증가 번호.
create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),   -- 클라이언트가 만든 UUID (중복 전송 방지)
  seq              bigint generated always as identity,
  conversation_id  uuid not null references public.conversations(id) on delete cascade,
  sender_id        uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  content          text not null default '' check (char_length(content) <= 2000),
  message_type     text not null default 'text' check (message_type in ('text','image')),
  storage_path     text,                                          -- Storage 경로만 저장 (이미지 본문은 저장 안 함)
  mime_type        text,
  file_size        integer,
  created_at       timestamptz not null default now(),
  constraint messages_kind_chk check (
    (message_type = 'text'
       and char_length(btrim(content)) >= 1
       and storage_path is null and mime_type is null and file_size is null)
    or
    (message_type = 'image'
       and storage_path ~ ('^' || conversation_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$')
       and mime_type in ('image/jpeg','image/png','image/webp')
       and file_size between 1 and 10485760)
  )
);
create unique index if not exists messages_seq_uq   on public.messages (seq);
create index        if not exists messages_conv_seq on public.messages (conversation_id, seq desc);

-- 대화방 참여자. left_at 이 null 이면 현재 참여 중.
-- 나갔다가 다시 들어오면 같은 행이 되살아난다(이전 기록 유지).
create table if not exists public.conversation_members (
  id                    uuid primary key default gen_random_uuid(),
  conversation_id       uuid not null references public.conversations(id) on delete cascade,
  user_id               uuid not null references public.profiles(id) on delete cascade,
  joined_at             timestamptz not null default now(),
  left_at               timestamptz,
  last_read_message_id  uuid references public.messages(id) on delete set null,
  last_read_seq         bigint not null default 0,     -- last_read_message_id 의 seq (읽음 계산용)
  unique (conversation_id, user_id)
);
create index if not exists members_user_idx on public.conversation_members (user_id) where left_at is null;

-- 웹 푸시 구독 (사용자·기기별). endpoint 는 기기별로 유일.
create table if not exists public.push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  subscription  jsonb not null check (subscription ? 'endpoint'),
  endpoint      text generated always as (subscription ->> 'endpoint') stored,
  created_at    timestamptz not null default now(),
  unique (endpoint)
);
create index if not exists push_user_idx on public.push_subscriptions (user_id);

-- 서버 설정값 (Edge Function 주소/비밀값). RLS 활성 + 정책 없음 = 클라이언트 접근 불가.
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);

-- 방 코드 무차별 대입 방지용 실패 기록
create table if not exists public.join_failures (
  user_id  uuid not null,
  at       timestamptz not null default now()
);
create index if not exists join_failures_idx on public.join_failures (user_id, at);

-- ---------------------------------------------------------------------
-- 2. 권한 확인용 함수 (RLS 정책에서 사용, auth.uid() 기준)
-- ---------------------------------------------------------------------

create or replace function public.is_active_member(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = p_conv and user_id = auth.uid() and left_at is null
  )
$$;

-- 친구이거나, 내가 참여 중인 방에서 함께한 적이 있는 사람의 프로필만 볼 수 있다.
create or replace function public.can_see_profile(p_target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships f
    where (f.requester_id = auth.uid() and f.receiver_id = p_target)
       or (f.receiver_id = auth.uid() and f.requester_id = p_target)
  ) or exists (
    select 1
    from public.conversation_members a
    join public.conversation_members b on b.conversation_id = a.conversation_id
    where a.user_id = auth.uid() and a.left_at is null and b.user_id = p_target
  )
$$;

-- Storage 객체 경로("<대화방uuid>/<uuid>.<확장자>")가 올바르고 내가 참여 중인 방인지 확인
create or replace function public.can_access_chat_object(p_name text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_name is null or p_name !~
     '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
  then
    return false;
  end if;
  return public.is_active_member(split_part(p_name, '/', 1)::uuid);
end $$;

-- ---------------------------------------------------------------------
-- 3. 내부 함수 (클라이언트 호출 불가)
-- ---------------------------------------------------------------------

-- 방에 참여(또는 재참여). 참여 시점의 마지막 메시지까지 '읽은 것'으로 맞춰
-- 나중에 들어온 사람이 예전 메시지의 읽음 숫자에 포함되지 않게 한다.
create or replace function public._join_member(p_conv uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare lm_id uuid; lm_seq bigint;
begin
  select id, seq into lm_id, lm_seq
  from public.messages where conversation_id = p_conv order by seq desc limit 1;

  insert into public.conversation_members (conversation_id, user_id, last_read_message_id, last_read_seq)
  values (p_conv, p_user, lm_id, coalesce(lm_seq, 0))
  on conflict (conversation_id, user_id) do update
    set left_at = null,
        joined_at = now(),
        last_read_message_id = excluded.last_read_message_id,
        last_read_seq = excluded.last_read_seq
    where public.conversation_members.left_at is not null;
end $$;

create or replace function public._accept_friendship(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare f public.friendships; cid uuid; k text;
begin
  update public.friendships set status = 'accepted' where id = p_id returning * into f;
  if not found then return; end if;
  k := least(f.requester_id, f.receiver_id)::text || ':' || greatest(f.requester_id, f.receiver_id)::text;
  insert into public.conversations (type, direct_key) values ('direct', k)
  on conflict (direct_key) do update set direct_key = excluded.direct_key
  returning id into cid;
  perform public._join_member(cid, f.requester_id);
  perform public._join_member(cid, f.receiver_id);
end $$;

-- 새 메시지가 저장되면 Edge Function(send-push)을 비동기로 호출한다.
-- 설정이 없거나 호출이 실패해도 메시지 저장은 절대 막지 않는다.
create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare u text; s text;
begin
  select value into u from public.app_settings where key = 'push_function_url';
  select value into s from public.app_settings where key = 'push_webhook_secret';
  if u is null or s is null then return new; end if;
  begin
    perform net.http_post(
      url     := u,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', s),
      body    := jsonb_build_object('message_id', new.id),
      timeout_milliseconds := 5000
    );
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists messages_notify on public.messages;
create trigger messages_notify after insert on public.messages
  for each row execute function public.notify_new_message();

-- ---------------------------------------------------------------------
-- 4. 클라이언트 호출 함수 (RPC) - 모두 auth.uid() 로 권한 확인
-- ---------------------------------------------------------------------

-- 가입: 프로필 생성 + 4자리 코드 발급. UNIQUE 제약으로 동시 가입에서도 중복되지 않는다.
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

-- 친구 요청. 상대가 이미 나에게 요청한 상태면 바로 수락된다.
-- 반환: sent | accepted | already_friends | already_sent
create or replace function public.send_friend_request(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); target uuid; f public.friendships;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_code is null or p_code !~ '^[0-9]{4}$' then raise exception 'invalid_code' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'no_profile' using errcode = '22023'; end if;
  select id into target from public.profiles where user_code = p_code;
  if not found then raise exception 'user_not_found' using errcode = 'P0002'; end if;
  if target = uid then raise exception 'self' using errcode = '22023'; end if;

  select * into f from public.friendships
  where least(requester_id, receiver_id) = least(uid, target)
    and greatest(requester_id, receiver_id) = greatest(uid, target);
  if found then
    if f.status = 'accepted' then return 'already_friends'; end if;
    if f.requester_id = uid then return 'already_sent'; end if;
    perform public._accept_friendship(f.id);
    return 'accepted';
  end if;

  insert into public.friendships (requester_id, receiver_id) values (uid, target) on conflict do nothing;
  return 'sent';
end $$;

create or replace function public.respond_friend_request(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.friendships where id = p_id and receiver_id = uid and status = 'pending') then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
  if p_accept then
    perform public._accept_friendship(p_id);
  else
    delete from public.friendships where id = p_id;
  end if;
end $$;

-- 친구 삭제: 관계를 지우고 1:1 방에서 양쪽 모두 나간 상태로 만든다(다시 친구가 되면 기록 복원).
create or replace function public.remove_friend(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); k text;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.friendships
  where least(requester_id, receiver_id) = least(uid, p_user)
    and greatest(requester_id, receiver_id) = greatest(uid, p_user);
  k := least(uid, p_user)::text || ':' || greatest(uid, p_user)::text;
  update public.conversation_members set left_at = now()
  where left_at is null
    and conversation_id in (select id from public.conversations where direct_key = k);
end $$;

-- 공개 오픈채팅: 계정당 생성 가능한 방은 하나. 다른 방에는 여러 개 참가할 수 있다.
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

create or replace function public.list_open_rooms()
returns table (
  id uuid, name text, owner_id uuid, member_count bigint,
  recent_messages bigint, last_message_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.owner_id,
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

create schema if not exists private;

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

-- 읽음 위치 저장: 앞으로만 이동, 같은 방의 메시지만 허용, 내 행만 수정
create or replace function public.mark_read(p_conv uuid, p_message uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s bigint;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select seq into s from public.messages where id = p_message and conversation_id = p_conv;
  if not found then return; end if;
  update public.conversation_members
  set last_read_message_id = p_message, last_read_seq = s
  where conversation_id = p_conv and user_id = uid and left_at is null and last_read_seq < s;
end $$;

-- 푸시 구독 저장. 같은 브라우저(endpoint)가 다른 계정에 남아 있으면 현재 계정으로 옮긴다.
create or replace function public.save_push_subscription(p_subscription jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); ep text := p_subscription ->> 'endpoint';
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if ep is null or ep !~ '^https://' or char_length(ep) > 1000
     or coalesce(p_subscription #>> '{keys,p256dh}', '') = '' or coalesce(p_subscription #>> '{keys,auth}', '') = '' then
    raise exception 'invalid_subscription' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'no_profile' using errcode = '22023'; end if;
  insert into public.push_subscriptions (user_id, subscription)
  values (uid, jsonb_build_object('endpoint', ep, 'expirationTime', p_subscription -> 'expirationTime', 'keys', p_subscription -> 'keys'))
  on conflict (endpoint) do update set user_id = excluded.user_id, subscription = excluded.subscription, created_at = now();
end $$;

-- 읽지 않은 메시지 수 + 마지막 메시지 시각 (목록 표시용). RLS 적용(security invoker).
create or replace function public.conversation_summary()
returns table (conversation_id uuid, unread bigint, last_message_at timestamptz)
language sql stable security invoker set search_path = public as $$
  select cm.conversation_id,
         (select count(*) from public.messages m
           where m.conversation_id = cm.conversation_id and m.seq > cm.last_read_seq and m.sender_id <> cm.user_id),
         (select m.created_at from public.messages m
           where m.conversation_id = cm.conversation_id order by m.seq desc limit 1)
  from public.conversation_members cm
  where cm.user_id = auth.uid() and cm.left_at is null
$$;

-- 한 메시지를 아직 읽지 않은 참여자 수 (발신자·나간 사람 제외). 읽음 숫자와 같은 기준.
create or replace function public.message_unread_count(p_message uuid)
returns integer language sql stable security invoker set search_path = public as $$
  select count(*)::int
  from public.messages m
  join public.conversation_members cm on cm.conversation_id = m.conversation_id
  where m.id = p_message and cm.left_at is null and cm.user_id <> m.sender_id and cm.last_read_seq < m.seq
$$;

-- ---------------------------------------------------------------------
-- 5. 테이블 권한 (RLS 와 별개로 한 번 더 좁힌다)
-- ---------------------------------------------------------------------
revoke all on public.profiles, public.friendships, public.conversations, public.conversation_members,
              public.messages, public.push_subscriptions, public.app_settings, public.join_failures
  from anon, authenticated;

grant select on public.profiles, public.friendships, public.conversations, public.conversation_members,
                public.messages, public.push_subscriptions to authenticated;
grant update (username) on public.profiles to authenticated;                  -- 코드·id 는 수정 불가
grant delete on public.push_subscriptions to authenticated;
-- 메시지 작성: sender_id / seq / created_at 은 서버 기본값만 사용 (발신자·시간 위조 불가)
grant insert (id, conversation_id, content, message_type, storage_path, mime_type, file_size)
  on public.messages to authenticated;

-- ---------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.friendships          enable row level security;
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;
alter table public.push_subscriptions   enable row level security;
alter table public.app_settings         enable row level security;
alter table public.join_failures        enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.can_see_profile(id));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships for select to authenticated
  using (requester_id = (select auth.uid()) or receiver_id = (select auth.uid()));
-- 친구 요청/수락/삭제는 RPC(send_friend_request 등)로만 가능

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select to authenticated
  using (type = 'open' or public.is_active_member(id));

drop policy if exists members_select on public.conversation_members;
create policy members_select on public.conversation_members for select to authenticated
  using (user_id = (select auth.uid()) or public.is_active_member(conversation_id));
-- 참가/나가기/읽음 저장은 RPC 로만 가능

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (public.is_active_member(conversation_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = (select auth.uid()) and public.is_active_member(conversation_id));
-- 메시지 수정/삭제 정책 없음 = 불가

drop policy if exists push_select on public.push_subscriptions;
create policy push_select on public.push_subscriptions for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists push_delete on public.push_subscriptions;
create policy push_delete on public.push_subscriptions for delete to authenticated
  using (user_id = (select auth.uid()));
-- 구독 저장은 save_push_subscription RPC 로만 가능

-- ---------------------------------------------------------------------
-- 7. 함수 실행 권한: 기본값(PUBLIC)을 걷어내고 필요한 것만 authenticated 에 허용
-- ---------------------------------------------------------------------
revoke all on function
  public.is_active_member(uuid), public.can_see_profile(uuid), public.can_access_chat_object(text),
  public._join_member(uuid, uuid), public._accept_friendship(uuid), public.notify_new_message(),
  public.create_profile(text), public.send_friend_request(text), public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid), public.create_open_room(text), public.join_open_room(uuid), public.leave_open_room(uuid),
  public.list_open_rooms(), public.mark_read(uuid, uuid), public.save_push_subscription(jsonb),
  public.conversation_summary(), public.message_unread_count(uuid)
  from public, anon, authenticated;

grant execute on function
  public.is_active_member(uuid), public.can_see_profile(uuid), public.can_access_chat_object(text),
  public.create_profile(text), public.send_friend_request(text), public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid), public.create_open_room(text), public.join_open_room(uuid), public.leave_open_room(uuid),
  public.list_open_rooms(), public.mark_read(uuid, uuid), public.save_push_subscription(jsonb),
  public.conversation_summary(), public.message_unread_count(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- 8. Storage: 비공개 버킷 + 정책 (10MB, JPEG/PNG/WebP, 채팅 참여자만)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-images', 'chat-images', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = 10485760,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists chat_images_insert on storage.objects;
create policy chat_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-images' and public.can_access_chat_object(name));

drop policy if exists chat_images_select on storage.objects;
create policy chat_images_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-images' and public.can_access_chat_object(name));
-- 수정/삭제 정책 없음 = 업로드한 이미지는 클라이언트에서 변경·삭제 불가

-- ---------------------------------------------------------------------
-- 9. Realtime: 변경 이벤트를 받을 테이블 등록 (RLS 가 이벤트에도 적용됨)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['messages', 'conversation_members', 'friendships', 'conversations'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 10. 보안 보완: 내부 RLS helper를 비공개 스키마로 이동
-- ---------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create or replace function private.is_active_member(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.conversation_members
    where conversation_id = p_conv and user_id = auth.uid() and left_at is null)
$$;
create or replace function private.can_see_profile(p_target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships f
    where (f.requester_id = auth.uid() and f.receiver_id = p_target)
       or (f.receiver_id = auth.uid() and f.requester_id = p_target)
  ) or exists (
    select 1 from public.conversation_members a
    join public.conversation_members b on b.conversation_id = a.conversation_id
    where a.user_id = auth.uid() and a.left_at is null and b.user_id = p_target
  )
$$;
create or replace function private.can_access_chat_object(p_name text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_name is null or p_name !~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
  then return false; end if;
  return private.is_active_member(split_part(p_name, '/', 1)::uuid);
end $$;
revoke all on function private.is_active_member(uuid), private.can_see_profile(uuid), private.can_access_chat_object(text) from public, anon;
grant execute on function private.is_active_member(uuid), private.can_see_profile(uuid), private.can_access_chat_object(text) to authenticated;

-- RLS 및 Storage 정책이 private helper를 사용하도록 교체
 drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.can_see_profile(id));
drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select to authenticated
  using (type = 'open' or private.is_active_member(id));
drop policy if exists members_select on public.conversation_members;
create policy members_select on public.conversation_members for select to authenticated
  using (user_id = (select auth.uid()) or private.is_active_member(conversation_id));
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (private.is_active_member(conversation_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = (select auth.uid()) and private.is_active_member(conversation_id));
drop policy if exists chat_images_insert on storage.objects;
create policy chat_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-images' and private.can_access_chat_object(name));
drop policy if exists chat_images_select on storage.objects;
create policy chat_images_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-images' and private.can_access_chat_object(name));

revoke all on function public.is_active_member(uuid), public.can_see_profile(uuid), public.can_access_chat_object(text)
  from public, anon, authenticated;
drop function public.is_active_member(uuid);
drop function public.can_see_profile(uuid);
drop function public.can_access_chat_object(text);

-- ---------------------------------------------------------------------
-- 11. Web Push 설정: VAPID private key와 webhook secret은 Vault에 저장
-- ---------------------------------------------------------------------
create or replace function public.save_vapid_keys(p_public text, p_private text, p_subject text)
returns text language plpgsql security definer set search_path = public, vault as $$
declare current_public text;
begin
  if p_public is null or p_private is null or p_subject is null
     or p_public !~ '^[A-Za-z0-9_-]{80,100}$'
     or p_private !~ '^[A-Za-z0-9_-]{40,50}$'
     or p_subject !~ '^https://'
  then raise exception 'invalid_vapid_config' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('sdjchat_vapid_config'));
  select decrypted_secret into current_public from vault.decrypted_secrets where name = 'sdjchat_vapid_public_key';
  if current_public is null then
    perform vault.create_secret(p_public, 'sdjchat_vapid_public_key', 'Web Push VAPID public key');
    perform vault.create_secret(p_private, 'sdjchat_vapid_private_key', 'Web Push VAPID private key');
    perform vault.create_secret(p_subject, 'sdjchat_vapid_subject', 'Web Push VAPID subject');
    current_public := p_public;
  end if;
  return current_public;
end $$;

create or replace function public.get_push_config()
returns jsonb language sql security definer set search_path = public, vault as $$
  select coalesce(jsonb_object_agg(name, decrypted_secret), '{}'::jsonb)
  from vault.decrypted_secrets
  where name in ('sdjchat_vapid_public_key','sdjchat_vapid_private_key','sdjchat_vapid_subject','sdjchat_push_webhook_secret')
$$;
revoke all on function public.save_vapid_keys(text,text,text), public.get_push_config() from public, anon, authenticated;
grant execute on function public.save_vapid_keys(text,text,text), public.get_push_config() to service_role;

do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'sdjchat_push_webhook_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
      'sdjchat_push_webhook_secret', 'Database to Edge Function webhook authentication secret');
  end if;
end $$;

create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare u text; s text;
begin
  select value into u from public.app_settings where key = 'push_function_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'sdjchat_push_webhook_secret';
  if u is null or s is null then return new; end if;
  begin
    perform net.http_post(url := u,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret',s),
      body := jsonb_build_object('message_id',new.id), timeout_milliseconds := 5000);
  exception when others then null;
  end;
  return new;
end $$;

-- 푸시 발송 Edge Function 주소. 비밀값은 여기에 저장하지 않는다.
insert into public.app_settings (key, value)
values ('push_function_url', 'https://tunrakwqldpcxrtbdeuq.supabase.co/functions/v1/send-push')
on conflict (key) do update set value = excluded.value;


-- ---------------------------------------------------------------------
-- 12. 친구 코드 무차별 조회 제한
-- ---------------------------------------------------------------------
create table if not exists public.code_lookup_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index if not exists code_lookup_attempts_user_time_idx
  on public.code_lookup_attempts(user_id, attempted_at desc);
alter table public.code_lookup_attempts enable row level security;
revoke all on public.code_lookup_attempts from public, anon, authenticated;

create or replace function private.can_see_profile(p_target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships f
    where (f.requester_id = auth.uid() and f.receiver_id = p_target)
       or (f.receiver_id = auth.uid() and f.requester_id = p_target)
  ) or exists (
    select 1 from public.conversation_members a
    join public.conversation_members b on b.conversation_id = a.conversation_id
    where a.user_id = auth.uid() and a.left_at is null
      and b.user_id = p_target and b.left_at is null
  )
$$;

create or replace function public.send_friend_request(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); target uuid; f public.friendships; attempts integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_code is null or p_code !~ '^[0-9]{4}$' then raise exception 'invalid_code' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'no_profile' using errcode = '22023'; end if;

  perform pg_advisory_xact_lock(hashtext(uid::text));
  delete from public.code_lookup_attempts where user_id = uid and attempted_at < now() - interval '1 hour';
  select count(*) into attempts from public.code_lookup_attempts
    where user_id = uid and attempted_at > now() - interval '10 minutes';
  if attempts >= 10 then raise exception 'lookup_rate_limited' using errcode = 'P0001'; end if;
  insert into public.code_lookup_attempts(user_id) values (uid);

  select id into target from public.profiles where user_code = p_code;
  if not found then raise exception 'user_not_found' using errcode = 'P0002'; end if;
  if target = uid then raise exception 'self' using errcode = '22023'; end if;
  select * into f from public.friendships
    where least(requester_id, receiver_id) = least(uid, target)
      and greatest(requester_id, receiver_id) = greatest(uid, target);
  if found then
    if f.status = 'accepted' then return 'already_friends'; end if;
    if f.requester_id = uid then return 'already_sent'; end if;
    perform public._accept_friendship(f.id);
    return 'accepted';
  end if;
  insert into public.friendships(requester_id, receiver_id) values (uid, target) on conflict do nothing;
  return 'sent';
end $$;

-- 자주 조회되는 FK 인덱스 및 실패 이력 PK
create index if not exists messages_sender_id_idx on public.messages(sender_id);
create index if not exists conversations_owner_id_idx on public.conversations(owner_id) where owner_id is not null;
create index if not exists conversation_members_last_read_idx
  on public.conversation_members(last_read_message_id) where last_read_message_id is not null;
alter table public.join_failures add column if not exists id bigint generated always as identity;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.join_failures'::regclass and contype='p') then
    alter table public.join_failures add constraint join_failures_pkey primary key(id);
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 13. 푸시 중복 방지/발송 기록 (supabase/migrations/20261103_push_fix.sql 과 동일)
-- ---------------------------------------------------------------------
create table if not exists public.push_deliveries (
  message_id  uuid primary key,                    -- 메시지당 1행 = 발송 권한(claim)
  source      text not null default 'trigger',     -- trigger(DB 트리거) | client(보낸 사람 앱)
  claimed_at  timestamptz not null default now(),
  sent        integer,                             -- 푸시 서비스가 받아들인 기기 수
  failed      integer,                             -- 실패한 기기 수
  removed     integer,                             -- 만료/무효라서 삭제한 구독 수
  detail      jsonb                                -- 기기별 결과 (푸시 서비스 호스트: HTTP 상태)
);
create index if not exists push_deliveries_claimed_idx on public.push_deliveries (claimed_at);

-- 클라이언트(anon/authenticated)는 접근 불가. Edge Function(service_role)만 사용한다.
alter table public.push_deliveries enable row level security;
revoke all on public.push_deliveries from public, anon, authenticated;

-- 공개 오픈채팅 함수는 로그인 사용자만 호출할 수 있다.
revoke all on function public.create_open_room(text), public.join_open_room(uuid),
  public.leave_open_room(uuid), public.list_open_rooms() from public, anon, authenticated;
grant execute on function public.create_open_room(text), public.join_open_room(uuid),
  public.leave_open_room(uuid), public.list_open_rooms() to authenticated;
revoke all on function private.touch_open_room_activity() from public, anon, authenticated;
revoke all on function private.touch_open_room_members() from public, anon, authenticated;
