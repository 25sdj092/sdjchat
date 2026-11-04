-- 메시지는 메시지 INSERT RLS 정책을 통과한 로그인 사용자만 직접 저장한다.
grant insert on table public.messages to authenticated;
