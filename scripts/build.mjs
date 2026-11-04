// Vercel 빌드: 환경변수 → public/config.js 생성. (외부 패키지 없음)
// 프런트엔드에는 공개 가능한 값만 들어간다. 비밀 키가 감지되면 빌드를 중단한다.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const env = process.env;
const url = (env.SUPABASE_URL || '').trim().replace(/\/+$/, '');
const key = (env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY || '').trim();
const vapid = (env.VAPID_PUBLIC_KEY || '').trim();

function fail(msg) { console.error('\n[build] ' + msg + '\n'); process.exit(1); }

if (!url && !key && !vapid) {
  console.log('[build] 환경변수가 없어 public/config.js 를 그대로 사용합니다.');
  process.exit(0);
}
if (!/^https:\/\/[a-z0-9-]+\.supabase\.(co|in)$/i.test(url) && !/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i.test(url)) {
  fail('SUPABASE_URL 형식이 올바르지 않습니다. 예) https://abcdefgh.supabase.co');
}
if (!key) fail('SUPABASE_ANON_KEY(또는 SUPABASE_PUBLISHABLE_KEY)가 없습니다.');
if (key.startsWith('sb_secret_')) fail('SUPABASE_ANON_KEY 에 비밀 키(sb_secret_...)가 들어 있습니다. 공개 가능한 anon/publishable 키만 사용하세요.');
if (key.split('.').length === 3) {
  try {
    const role = JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString('utf8')).role;
    if (role === 'service_role') fail('SUPABASE_ANON_KEY 에 service_role 키가 들어 있습니다. 절대 프런트엔드에 넣으면 안 됩니다. anon 키를 사용하세요.');
  } catch { /* JWT 가 아니면 무시 */ }
}
if (vapid && !/^[A-Za-z0-9_-]{80,100}$/.test(vapid)) fail('VAPID_PUBLIC_KEY 형식이 올바르지 않습니다. (web-push generate-vapid-keys 의 Public Key)');

const cfg = { supabaseUrl: url, supabaseAnonKey: key, vapidPublicKey: vapid };
writeFileSync(join(root, 'public', 'config.js'),
  '/* 빌드 시 자동 생성됨 (공개 가능한 값만 포함) */\nwindow.APP_CONFIG = ' + JSON.stringify(cfg, null, 2) + ';\n');
console.log('[build] public/config.js 생성 완료 (' + url + (vapid ? ', 푸시 활성' : ', 푸시 키 없음') + ')');
