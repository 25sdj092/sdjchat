# 서고챗

Vercel 정적 배포 + Supabase Auth / PostgreSQL / Realtime / Storage / Edge Functions를 사용하는 초경량 채팅 웹앱입니다. 개인 DM과 공개 오픈채팅을 별도 목록으로 관리합니다.

## 현재 연결된 Supabase 프로젝트

- 프로젝트: `supabase-blue-kite`
- Project ref: `tunrakwqldpcxrtbdeuq`
- Project URL: `https://tunrakwqldpcxrtbdeuq.supabase.co`
- 브라우저용 Publishable Key: `public/config.js`에 입력되어 있습니다.
- 데이터베이스 스키마, RLS, 비공개 사진 버킷, Realtime publication은 이미 이 프로젝트에 적용되어 있습니다.
- `send-push` Edge Function도 배포되어 있습니다.

> 이 ZIP을 현재 Supabase 프로젝트에 연결할 때 `supabase/schema.sql`을 다시 실행하지 마세요. 이미 적용된 마이그레이션과 중복될 수 있습니다. 새 Supabase 프로젝트에 설치할 때만 아래 SQL 단계를 사용하세요.

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
- 개인 DM / 공개 오픈채팅 `conversations`
- 참여자 및 읽음 위치 `conversation_members`
- 메시지 영구 저장 `messages`
- 푸시 구독 `push_subscriptions`
- 친구 코드 조회 시도 제한용 내부 테이블 (친구 코드 10회/10분 제한)
- RLS 정책 및 내부 helper 함수
- 4자리 친구 코드 발급 RPC
- 공개 오픈채팅 목록, 참가, 나가기 RPC
- 사용자당 오픈채팅 생성 1개 제한
- 읽음 숫자 계산 RPC
- `chat-images` 비공개 Storage 버킷: JPEG/PNG/WebP/GIF, 파일당 10 MiB (이전 GIF 첨부 메시지 호환)
- `messages`, `conversation_members`, `friendships`, `conversations` Realtime 등록
- 새 메시지 DB trigger와 `send-push` Edge Function

예전 테이블 `legacy_messages_v1`, `direct_messages`, `open_messages`는 기존 호환성을 위해 보존했으며 일반 클라이언트 권한은 차단되어 있습니다. 기존 데이터 행은 확인 당시 0개였습니다.

## 푸시 알림

### 동작 구조

| 상황 | 알림을 보여주는 주체 |
|---|---|
| 앱이 열려 있고 **그 대화방을 보는 중** | 알림 없음 (읽음 처리만) |
| 앱이 열려 있지만 **다른 방을 보거나 탭이 비활성** | 앱이 Realtime 으로 받아 브라우저 알림 표시 (권한이 없으면 앱 안 토스트) |
| **탭/브라우저 창을 닫음** | 서버가 Web Push 발송 → Service Worker 가 알림 표시 |

- 알림을 누르면 사이트가 열리고(이미 열려 있으면 그 탭으로 이동) 해당 대화방이 열립니다.
- 같은 메시지는 알림 `tag`(=메시지 id)가 같아서 앱 알림과 서버 푸시가 겹쳐도 **한 번만** 보입니다.
- 서버 발송은 두 경로가 모두 호출합니다: ① DB 트리거(`notify_new_message`) ② 메시지를 보낸 사람의 앱(저장 직후). 서버가 `push_deliveries` 로 **메시지당 1회만** 발송하도록 막고, 보낸 사람 본인에게는 보내지 않습니다. 한쪽 경로가 막혀 있어도 알림이 갑니다.
- 만료/무효 구독(푸시 서비스 응답 404·410·401·403)은 자동으로 삭제됩니다. 기기마다 구독이 따로 저장됩니다.

### 알림 설정

왼쪽의 **알림 켜기 / 알림 끄기** 버튼으로 이 브라우저의 푸시 수신을 관리합니다. 첫 활성화 때 브라우저 권한을 요청하며, 권한이 이미 허용된 기기는 로그인 후 구독을 조용히 동기화합니다. 별도의 구독 상태 문구와 테스트 버튼은 화면에 표시하지 않습니다.

### 이미 운영 중인 Supabase 프로젝트에 적용하는 방법 (순서대로)

1. **SQL Editor** 에서 `supabase/migrations/20261103_push_fix.sql` 실행 (`push_deliveries` 테이블 추가만 함. `schema.sql` 전체를 다시 실행하지 마세요.)
2. **Edge Function 재배포** (아래 둘 중 하나)
   - CLI: `npx supabase functions deploy send-push --project-ref tunrakwqldpcxrtbdeuq --no-verify-jwt`
   - 대시보드: *Edge Functions → send-push* 에 `supabase/functions/send-push/index.ts` 내용을 붙여넣어 배포하고, 함수 설정의 **Verify JWT(JWT 검증) 를 끔**
   - JWT 검증이 켜져 있으면 DB 트리거 호출이 게이트웨이에서 401 로 막힙니다. (이 경우에도 보낸 사람 앱 경로로 알림은 가지만, 끄는 것을 권장합니다.)
3. **Vercel 재배포** (`public/` 변경분 반영)
4. 각 기기에서 사이트를 **새로고침** → **알림 켜기** → 브라우저 권한을 허용한 뒤 새 메시지를 보내 푸시 알림을 확인

### 알림이 안 올 때 점검 (Supabase SQL Editor)

```sql
-- 1) 구독이 서버에 저장되어 있는가? (기기당 1행)
select user_id, left(endpoint, 60) as endpoint, created_at from public.push_subscriptions order by created_at desc;

-- 2) 최근 메시지의 발송 결과 (sent=받아들인 기기 수, failed, removed=삭제한 무효 구독, detail=기기별 상태 코드)
select message_id, source, claimed_at, sent, failed, removed, detail from public.push_deliveries order by claimed_at desc limit 10;

-- 3) DB 트리거가 Edge Function 을 호출한 결과 (status_code 가 200 이 아니면 호출이 막힌 것)
select id, status_code, error_msg, left(content::text, 200) as content, created from net._http_response order by created desc limit 10;
```

- 1)이 비어 있음 → 브라우저에서 구독이 만들어지지 않은 상태입니다. **알림 켜기**를 다시 시도하고 Edge Function 로그를 확인하세요.
- 2)에 행이 없고 3)이 401/404 → 트리거 경로가 막힘 (Verify JWT 끄기, `app_settings.push_function_url` 확인). 앱 경로는 로그인 토큰으로 호출됩니다.
- 2)의 `detail` 에 `403`/`401` → VAPID 키가 구독 때와 달라 거부됨. 해당 구독은 자동 삭제되고, 앱을 열면 새 키로 다시 구독합니다.
- *Edge Functions → send-push → Logs* 에서도 오류를 볼 수 있습니다.

### 한계

탭을 닫은 뒤의 알림은 브라우저·OS 의 Web Push 지원, 사이트 알림 권한, 기기 전원·네트워크가 필요합니다. 학교 Chromebook 관리 정책이 푸시를 막으면 동작하지 않을 수 있습니다. iPhone/iPad 는 홈 화면에 추가한 웹앱에서만 푸시를 받을 수 있습니다.

## 새 Supabase 프로젝트에 설치할 때

현재 프로젝트에는 다시 실행하지 마세요. 완전히 새 프로젝트에서만 사용합니다.

1. Supabase 프로젝트 생성
2. **Authentication → Providers → Anonymous Sign-Ins** 활성화
3. SQL Editor에서 `supabase/schema.sql` 전체 실행
4. 아래 마이그레이션을 표시된 순서대로 각각 실행
   - `supabase/migrations/20261104_profile_rooms_presence.sql`
   - `supabase/migrations/20261104_chat_interactions_unique_names.sql`
   - `supabase/migrations/20261104_chat_interaction_indexes.sql`
   - `supabase/migrations/20261104_chat_message_insert_permission.sql`
   - `supabase/migrations/20261105_allow_chat_gif.sql`
   - `supabase/migrations/20261105_giphy_gif_messages.sql`
   - `supabase/migrations/20261105_giphy_gif_url_constraint_fix.sql`
5. `supabase/functions/send-push/index.ts`를 `send-push`로 배포 (`supabase/config.toml` 에 `verify_jwt=false` 가 지정되어 있음; 함수가 별도 인증을 수행)
6. 프로젝트 URL 및 Publishable Key를 `public/config.js` 또는 Vercel 빌드 환경변수에 입력

SQL 스키마는 비공개 `chat-images` 버킷, Storage 정책, RLS, Realtime 등록 및 푸시 trigger 주소를 구성합니다. Edge Function은 Supabase가 제공하는 `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` 런타임 환경변수를 사용합니다. 서비스 키를 프런트엔드에 복사하지 마세요.

## 두 사용자 테스트

1. 서로 다른 브라우저 프로필/기기에서 각각 이름으로 가입합니다.
2. 한 사용자의 4자리 코드를 다른 사용자가 입력해 친구 요청을 보내고 수락합니다.
3. 한쪽 탭을 닫고 상대가 메시지를 보낸 뒤 다시 열어 저장된 메시지를 확인합니다.
4. 수신 기기에서 알림을 허용하고 탭을 닫은 뒤 새 메시지 푸시를 확인합니다.
5. 10 MiB 이하 JPEG/PNG/WebP를 보내고, 초과 파일은 차단되는지 확인합니다.
6. 오픈채팅방을 하나 만들고 다른 계정에서 목록에 표시되는 방에 참가한 뒤 메시지와 읽음 숫자를 확인합니다.

## 중요한 제한

- 익명 계정은 이메일/비밀번호 복구 수단이 없습니다. 브라우저 데이터 삭제 또는 기기 변경 시 계정을 복구하지 못할 수 있습니다.
- 4자리 코드는 10,000개뿐입니다. 사용자 수가 늘면 새 코드 발급이 불가능해집니다.
- 오픈채팅은 공개 목록에 표시되므로 민감한 개인정보를 공유하지 마세요. 각 계정은 오픈채팅방을 하나만 만들 수 있지만, 다른 사람이 만든 방에는 여러 개 참가할 수 있습니다.
- Web Push는 모든 브라우저/학교 관리 환경에서 보장되지 않습니다. 기기가 꺼져 있거나 인터넷이 끊기면 알림이 도착하지 않습니다.
- 기존 프로젝트는 미국 동부 리전에 있습니다. 한국 사용자에게는 서울 리전보다 지연이 있을 수 있습니다.

## Chromebook 최적화

프레임워크 없는 바닐라 JS, 단일 Realtime 연결, 폴링 없음, 30개씩 메시지 페이지 로딩, 화면 말풍선 상한 300개, 이미지 지연 로딩, 애니메이션/그림자 최소화 구조입니다.


## 서고챗 전환 마이그레이션

`supabase/migrations/20261104_open_chat_reset.sql`은 기존 계정과 모든 DM/방/메시지를 삭제하고 공개 오픈채팅 구조로 전환하는 **파괴적 마이그레이션**입니다. 현재 운영 데이터가 필요하면 실행하지 마세요. 실행 직전 실제 운영 DB에서 계정 4개, 대화방 4개, 메시지 203개를 확인했고, 2026년 11월 4일 운영 프로젝트에 마이그레이션을 적용했습니다. 적용 후 계정·친구·대화방·참여자·메시지·푸시 구독 데이터가 모두 0건임을 재확인했습니다. 기존 익명 계정은 복구할 수 없습니다. 이 마이그레이션은 이미 운영 DB에 적용했으므로 같은 운영 프로젝트에서 다시 실행하지 마세요. 기존 Storage 이미지 객체 19개는 정리하지 않아 남아 있습니다.

새 회원가입 이름은 한글과 숫자만 허용하며 최대 12자입니다. DB에서도 같은 규칙을 검증합니다.


## 서고챗 최근 기능

- 이름은 한글+숫자 1~12자, **중복 불가**이며 이름 변경은 **7일에 한 번**만 가능
- 이름 변경 전 7일 제한 안내를 표시하고, DB에서도 변경 주기를 확인
- **방 만들기**와 **방 추가**를 서로 다른 버튼과 패널로 분리
- 친구 추가 버튼은 내 4자리 코드 오른쪽에 배치
- 내 4자리 코드는 숫자 자체를 클릭하거나 키보드로 선택해 복사
- 사진은 JPEG/PNG/WebP 파일로 첨부하고, GIF 버튼에서는 GIPHY 검색·인기 GIF를 골라 메시지로 전송 가능
- 메시지의 `http://`, `https://`, `www.` URL은 클릭 가능한 링크로 표시
- 메시지에 👍 ❤️ 😂 😮 😢 🎉 반응을 추가하거나 취소 가능
- 메시지별 답글과 답글 미리보기 지원
- 입력창에서 `@`를 입력하면 현재 방 참여자 이름을 추천하고, 선택한 사용자를 멘션으로 저장
- 오픈채팅은 공개 목록에서 참가하며, 계정당 생성은 1개로 제한
- 코드방은 생성 시 6자리 숫자 코드를 발급하며, 참가 코드 입력은 계정당 10분에 10회로 제한
- 방장은 방 이름을 수정할 수 있고, 방 삭제는 1차 확인 후 `삭제하겠습니다`를 정확히 입력해야 진행
- 방장은 자신이 만든 방만 삭제할 수 있으며, 삭제 시 메시지/참여자와 방 사진도 함께 정리
- 일반 참여자는 방에서 나갈 수 있으며, DM 목록은 Supabase Realtime Presence로 온라인/오프라인 표시

운영 적용 마이그레이션: `supabase/migrations/20261104_profile_rooms_presence.sql`


## GIPHY GIF 검색

- 채팅 입력창의 **GIF** 버튼에서 인기 GIF 또는 검색어로 찾은 GIF를 선택해 전송합니다.
- GIF 파일을 Supabase Storage에 업로드하지 않습니다. GIPHY가 제공한 HTTPS 미디어 URL을 메시지 내용으로 전송합니다.
- GIPHY API는 브라우저에서 직접 호출하며, 검색 결과·미디어 URL을 앱 서버로 프록시하지 않습니다.
- GIPHY API 키는 브라우저에 전달되는 공개 키입니다. 비밀 키로 취급할 수 없으며 공개 설정 파일에 포함됩니다.
- GIF 선택창에는 GIPHY 출처 표시를 둡니다. GIPHY Beta 키는 시간당 100회 API 요청 제한이 있으므로 검색 버튼이나 Enter로 필요한 검색만 실행하세요.

