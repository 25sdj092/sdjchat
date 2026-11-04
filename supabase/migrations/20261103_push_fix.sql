-- =====================================================================
-- 푸시 알림 보완 마이그레이션 (기존 데이터·테이블은 변경하지 않는 추가 전용)
-- Supabase SQL Editor 에서 한 번 실행하세요. 여러 번 실행해도 안전합니다.
--
-- 목적
--  1) 같은 메시지에 대한 푸시 중복 발송 방지 (DB 트리거 호출 + 보낸 사람 앱 호출이 겹쳐도 1회만 발송)
--  2) 발송 결과 기록 → "왜 알림이 안 오는지"를 SQL 로 바로 확인할 수 있게 함
-- =====================================================================

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
