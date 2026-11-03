# SDJ Chat — Supabase 기반 초경량 메신저

Vercel 정적 배포 + Supabase Auth / PostgreSQL / Realtime / Storage / Edge Functions를 사용하는 메신저입니다. 기존 PeerJS 통신은 사용하지 않습니다.

## 현재 연결된 Supabase 프로젝트

- 프로젝트: `supabase-blue-kite`
- Project ref: `tunrakwqldpcxrtbdeuq`
- Project URL: `https://tunrakwqldpcxrtbdeuq.supabase.co`
- 브라우저용 Publishable Key: `public/config.js`에 입력되어 있습니다.
- 데이터베이스 스키마, RLS, 비공개 사진 버킷, Realtime publication은 이미 이 프로젝트에 적용되어 있습니다.
- `send-push` Edge Function도 배포되어 있습니다.

> 현재 연결된 프로젝트에는 데이터베이스 설정이 이미 적용되어 있습니다. 이 저장소의 `supabase/` 폴더에는 CLI 설정과 배포된 Edge Function 소스가 들어 있지만, 기존 5개 마이그레이션의 SQL 원문은 아직 포함되어 있지 않습니다. 따라서 새 Supabase 프로젝트를 이 저장소만으로 초기화할 수는 없습니다. 세부 내용은 `supabase/README.md`를 확인하세요.

## 가장 먼저 할 일: 익명 로그인 활성화

Supabase Dashboard에서 다음 페이지를 열고 **Anonymous Sign-Ins**를 켜세요.

<https://supabase.com/dashboard/project/tunrakwqldpcxrtbdeuq/auth/providers>

메뉴 경로: **Authentication → Sign In / Providers → Anonymous Sign-Ins → Enable**.

이 설정은 현재 MCP 관리 도구에서 변경할 수 없어 Dashboard에서 한 번 직접 켜야 합니다. 이름만 입력하는 가입은 Supabase Anonymous Auth를 사용합니다.

## Vercel 배포

1. 이 프로젝트를 Vercel에 가져옵니다.
2. Framework Preset은 `Other`로 둡니다.
3. Build Command는 `node scripts/build.mjs`, Output Directory는 `public`입니다. `vercel.json`에 이미 지정되어 있습니다.
4. 현재 연결된 프로젝트용 공개 설정은 `public/config.js`에 포함되어 있으므로 별도 환경변수 입력은 필수가 아닙니다.
5. 배포 후 HTTPS 주소로 접속합니다. Service Worker와 Web Push에는 HTTPS가 필요합니다.

환경변수로 설정하고 싶다면 다음 공개 값만 사용하세요.

- `SUPABASE_URL=https://tunrakwqldpcxrtbdeuq.supabase.co`
- `SUPABASE_PUBLISHABLE_KEY=sb_publishable_...`

`service_role` 또는 `sb_secret_` 키를 Vercel 프런트엔드 변수나 `public/config.js`에 넣지 마세요.

## 현재 Supabase에 이미 적용된 항목

- 익명 사용자 프로필 및 4자리 코드용 `profiles`
- 친구 요청 `friendships`
- 1:1 / 그룹 대화 `conversations`
- 참여자 및 읽음 위치 `conversation_members`
- 메시지 영구 저장 `messages`
- 푸시 구독 `push_subscriptions`
- 방 코드 및 친구 코드 조회 시도 제한용 내부 테이블 (친구 코드 10회/10분 제한)
- RLS 정책 및 내부 helper 함수
- 6자리 그룹방 코드 / 4자리 사용자 코드 발급 RPC
- 읽음 숫자 계산 RPC
- `chat-images` 비공개 Storage 버킷: JPEG/PNG/WebP, 파일당 10 MiB
- `messages`, `conversation_members`, `friendships` Realtime 등록
- 새 메시지 DB trigger와 `send-push` Edge Function

예전 테이블 `legacy_messages_v1`, `direct_messages`, `open_messages`는 기존 호환성을 위해 보존했으며 일반 클라이언트 권한은 차단되어 있습니다. 기존 데이터 행은 확인 당시 0개였습니다.

## 푸시 알림 설정

`send-push` Edge Function은 이미 배포되어 있습니다. VAPID 개인 키와 DB→함수 인증용 비밀값은 브라우저에 포함하지 않고 Supabase Vault에 보관하도록 구성했습니다.

사용자가 메신저에서 **알림 켜기**를 누르면:

1. 로그인 세션을 확인하고 Edge Function에서 VAPID 공개 키를 요청합니다.
2. 필요한 경우 Edge Function이 VAPID 키 쌍을 생성하고 Vault에 저장합니다.
3. 브라우저가 Push Subscription을 생성하고 `push_subscriptions`에 저장합니다.
4. 메시지 저장 트리거가 Edge Function을 호출하고, 수신자의 기기에 Web Push를 보냅니다.

탭을 닫은 상태에서도 알림을 받을 수 있지만, 브라우저·운영체제의 Web Push 지원, 사이트 알림 권한, 기기 전원 및 네트워크 연결이 필요합니다. 학교 Chromebook 관리 정책이 푸시를 막으면 동작하지 않을 수 있습니다.

## 새 Supabase 프로젝트에 설치할 때

현재 저장소에는 기존 데이터베이스 마이그레이션 SQL 원문이 포함되어 있지 않습니다. 따라서 이 저장소를 새 프로젝트에 연결한 뒤 곧바로 `supabase db push` 또는 `supabase db reset`을 실행하지 마세요. 기존 프로젝트의 데이터베이스 구조는 이미 적용되어 있습니다.

현재 프로젝트에 배포된 Edge Function의 소스는 `supabase/functions/send-push/index.ts`에 보관되어 있으며, 설정은 `supabase/config.toml`에 있습니다. 새 프로젝트용 전체 데이터베이스 설치 절차가 필요한 경우 마이그레이션 원문을 먼저 확보해야 합니다.

## 두 사용자 테스트

1. 서로 다른 브라우저 프로필/기기에서 각각 이름으로 가입합니다.
2. 한 사용자의 4자리 코드를 다른 사용자가 입력해 친구 요청을 보내고 수락합니다.
3. 한쪽 탭을 닫고 상대가 메시지를 보낸 뒤 다시 열어 저장된 메시지를 확인합니다.
4. 수신 기기에서 알림을 허용하고 탭을 닫은 뒤 새 메시지 푸시를 확인합니다.
5. 10 MiB 이하 JPEG/PNG/WebP를 보내고, 초과 파일은 차단되는지 확인합니다.
6. 그룹방을 만들고 6자리 코드로 참가한 뒤 읽음 숫자가 감소하는지 확인합니다.

## 중요한 제한

- 익명 계정은 이메일/비밀번호 복구 수단이 없습니다. 브라우저 데이터 삭제 또는 기기 변경 시 계정을 복구하지 못할 수 있습니다.
- 4자리 코드는 10,000개뿐입니다. 사용자 수가 늘면 새 코드 발급이 불가능해집니다.
- 6자리 방 코드는 비밀 인증 수단이 아닙니다. 방 코드 추측 시도 제한은 있지만 민감한 정보를 공유하는 용도로 사용하지 마세요.
- Web Push는 모든 브라우저/학교 관리 환경에서 보장되지 않습니다. 기기가 꺼져 있거나 인터넷이 끊기면 알림이 도착하지 않습니다.
- 기존 프로젝트는 미국 동부 리전에 있습니다. 한국 사용자에게는 서울 리전보다 지연이 있을 수 있습니다.

## Chromebook 최적화

프레임워크 없는 바닐라 JS, 단일 Realtime 연결, 폴링 없음, 30개씩 메시지 페이지 로딩, 화면 말풍선 상한 300개, 이미지 지연 로딩, 애니메이션/그림자 최소화 구조입니다.
