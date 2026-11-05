import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}
function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function decodeBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

async function generateVapidKeys() {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const pub = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const priv = await crypto.subtle.exportKey("jwk", pair.privateKey);
  if (!pub.x || !pub.y || !priv.d) throw new Error("vapid_key_export_failed");
  const point = new Uint8Array(65);
  point[0] = 4;
  point.set(decodeBase64Url(pub.x), 1);
  point.set(decodeBase64Url(pub.y), 33);
  return {
    publicKey: encodeBase64Url(point),
    privateKey: priv.d,
    subject: SUPABASE_URL,
  };
}

async function getPushConfig(createIfMissing = false) {
  const read = await admin.rpc("get_push_config");
  if (read.error) throw new Error("push_config_read_failed");
  let cfg = read.data ?? {};
  if ((!cfg.sdjchat_vapid_public_key || !cfg.sdjchat_vapid_private_key || !cfg.sdjchat_vapid_subject) && createIfMissing) {
    const keys = await generateVapidKeys();
    const saved = await admin.rpc("save_vapid_keys", {
      p_public: keys.publicKey,
      p_private: keys.privateKey,
      p_subject: keys.subject,
    });
    if (saved.error) throw new Error("push_config_save_failed");
    const reread = await admin.rpc("get_push_config");
    if (reread.error) throw new Error("push_config_read_failed");
    cfg = reread.data ?? {};
  }
  return cfg;
}

async function authenticateUser(req: Request) {
  const header = req.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  return error ? null : data.user;
}

// 푸시 서비스가 "이 구독은 더 이상 쓸 수 없다"고 답하는 상태 코드.
// 404/410 = 만료·삭제됨, 401/403 = 구독 당시와 다른 VAPID 키 등으로 영구히 거부됨.
const DEAD_CODES = new Set([401, 403, 404, 410]);

type Sub = { id: string; subscription: { endpoint: string } };

// deno-lint-ignore no-explicit-any
async function deliver(subs: Sub[], payload: string, opts: Record<string, any>) {
  const dead: string[] = [];
  const detail: Record<string, unknown>[] = [];
  let sent = 0, failed = 0;
  await Promise.allSettled(subs.map(async (s) => {
    let host = "?";
    try { host = new URL(s.subscription.endpoint).host; } catch { /* ignore */ }
    try {
      const r = await webpush.sendNotification(s.subscription, payload, { TTL: 60 * 60 * 24, urgency: "high", timeout: 8000, ...opts });
      sent++;
      detail.push({ host, status: r.statusCode });
    } catch (error) {
      failed++;
      // deno-lint-ignore no-explicit-any
      const code = (error as any)?.statusCode as number | undefined;
      detail.push({ host, status: code ?? null, error: String((error as Error)?.message ?? error).slice(0, 120) });
      if (code && DEAD_CODES.has(code)) dead.push(s.id);
      else console.error("push failed", host, code, (error as Error)?.message);
    }
  }));
  if (dead.length) await admin.from("push_subscriptions").delete().in("id", dead);
  return { sent, failed, removed: dead.length, detail };
}

async function loadVapid() {
  const cfg = await getPushConfig(true).catch((error) => {
    console.error("push config read failed", error);
    return null;
  });
  if (!cfg) return { error: json({ error: "push_config_unavailable" }, 500) };
  const pub = String(cfg.sdjchat_vapid_public_key ?? "");
  const priv = String(cfg.sdjchat_vapid_private_key ?? "");
  const subject = String(cfg.sdjchat_vapid_subject ?? "");
  if (!pub || !priv || !subject) return { error: json({ error: "vapid_not_configured" }, 500) };
  webpush.setVapidDetails(subject, pub, priv);
  return { cfg };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }

  // 브라우저에는 공개 VAPID 키만 전달한다. 호출자는 유효한 Supabase 세션이 있어야 한다.
  if (body.action === "public-key") {
    const user = await authenticateUser(req);
    if (!user) return json({ error: "unauthorized" }, 401);
    try {
      const cfg = await getPushConfig(true);
      if (!cfg.sdjchat_vapid_public_key) return json({ error: "vapid_not_configured" }, 500);
      return json({ publicKey: cfg.sdjchat_vapid_public_key });
    } catch (error) {
      console.error("vapid initialization failed", error);
      return json({ error: "push_setup_failed" }, 500);
    }
  }

  // 로그인한 본인의 모든 기기로 테스트 알림을 보낸다. (설정 점검용)
  if (body.action === "test") {
    const user = await authenticateUser(req);
    if (!user) return json({ error: "unauthorized" }, 401);
    const v = await loadVapid();
    if (v.error) return v.error;
    const { data: subs, error } = await admin.from("push_subscriptions").select("id, subscription").eq("user_id", user.id);
    if (error) return json({ error: "db_error" }, 500);
    if (!subs?.length) return json({ sent: 0, subscriptions: 0, reason: "no_subscriptions" });
    const payload = JSON.stringify({ title: "서고챗 알림 테스트", body: "이 알림이 보이면 푸시 설정이 정상입니다.", c: null, tag: "sdj-test", test: true });
    const r = await deliver(subs as Sub[], payload, {});
    return json({ ...r, subscriptions: subs.length });
  }

  const messageId = String(body.message_id ?? "");
  if (!UUID_RE.test(messageId)) return json({ error: "bad_request" }, 400);

  // 호출 주체 확인. (1) DB 트리거: Vault 의 비밀 헤더  (2) 보낸 사람의 앱: 로그인 토큰
  const v = await loadVapid();
  if (v.error) return v.error;
  const expectedSecret = String(v.cfg.sdjchat_push_webhook_secret ?? "");
  const givenSecret = req.headers.get("x-webhook-secret") ?? "";
  let source: "trigger" | "client" = "trigger";
  let callerId: string | null = null;
  if (givenSecret) {
    if (!expectedSecret || !safeEqual(givenSecret, expectedSecret)) return json({ error: "unauthorized" }, 401);
  } else {
    const user = await authenticateUser(req);
    if (!user) return json({ error: "unauthorized" }, 401);
    source = "client";
    callerId = user.id;
  }

  // messages -> profiles 관계가 sender_id와 reply_sender_id 두 개이므로 PostgREST
  // 임베디드 관계를 생략하고 ID로 각각 조회한다. 관계 모호성에 의한 500을 방지한다.
  const { data: msg, error: e1 } = await admin
    .from("messages")
    .select("id, conversation_id, sender_id, content, message_type")
    .eq("id", messageId).maybeSingle();
  if (e1) {
    console.error("push message lookup failed", e1.code, e1.message, e1.details, e1.hint);
    return json({ error: "db_error", stage: "message" }, 500);
  }
  if (!msg) return json({ sent: 0, reason: "message_not_found" });
  // 앱에서 호출한 경우, 자기가 보낸 메시지에 대해서만 발송을 요청할 수 있다.
  if (source === "client" && msg.sender_id !== callerId) return json({ error: "forbidden" }, 403);

  const [senderResult, conversationResult] = await Promise.all([
    admin.from("profiles").select("username").eq("id", msg.sender_id).maybeSingle(),
    admin.from("conversations").select("type, name").eq("id", msg.conversation_id).maybeSingle(),
  ]);
  if (senderResult.error) {
    console.error("push sender lookup failed", senderResult.error.code, senderResult.error.message);
    return json({ error: "db_error", stage: "sender" }, 500);
  }
  if (conversationResult.error) {
    console.error("push conversation lookup failed", conversationResult.error.code, conversationResult.error.message);
    return json({ error: "db_error", stage: "conversation" }, 500);
  }
  const senderProfile = senderResult.data;
  const conversation = conversationResult.data;

  const { data: members, error: e2 } = await admin
    .from("conversation_members").select("user_id")
    .eq("conversation_id", msg.conversation_id).is("left_at", null).neq("user_id", msg.sender_id);
  if (e2) { console.error("push member lookup failed", e2.code, e2.message); return json({ error: "db_error", stage: "members" }, 500); }
  const userIds = (members ?? []).map((m) => m.user_id);
  if (!userIds.length) return json({ sent: 0, reason: "no_recipients" });

  const { data: subs, error: e3 } = await admin
    .from("push_subscriptions").select("id, subscription").in("user_id", userIds);
  if (e3) { console.error("push subscription lookup failed", e3.code, e3.message); return json({ error: "db_error", stage: "subscriptions" }, 500); }
  if (!subs?.length) return json({ sent: 0, reason: "no_subscriptions" });

  // 같은 메시지는 한 번만 발송한다. (트리거와 앱 호출이 겹치거나 이벤트가 중복돼도 안전)
  let dedupe = "ok";
  const claim = await admin.from("push_deliveries")
    .upsert({ message_id: msg.id, source }, { onConflict: "message_id", ignoreDuplicates: true }).select("message_id");
  if (claim.error) {
    // 마이그레이션이 아직 적용되지 않은 경우: 알림 자체는 막지 않는다.
    console.error("push_deliveries claim failed (run supabase/migrations/20261103_push_fix.sql)", claim.error.message);
    dedupe = "unavailable";
  } else if (!claim.data || claim.data.length === 0) {
    return json({ sent: 0, reason: "duplicate" });
  } else if (Math.random() < 0.05) {
    await admin.from("push_deliveries").delete().lt("claimed_at", new Date(Date.now() - 7 * 86400_000).toISOString());
  }

  // deno-lint-ignore no-explicit-any
  const sender = senderProfile?.username ?? "새 메시지";
  const title = (conversation?.type === "open" || conversation?.type === "group") ? `${sender} · ${conversation.name}` : sender;
  const notificationBody = msg.message_type === "image"
    ? "사진을 보냈습니다."
    : msg.message_type === "gif"
      ? "GIF를 보냈습니다."
      : String(msg.content).replace(/\s+/g, " ").trim().slice(0, 80);
  const payload = JSON.stringify({ title, body: notificationBody, c: msg.conversation_id, tag: msg.id });

  try {
    // topic: 푸시 서비스 쪽에서도 같은 메시지의 중복 전달을 하나로 합친다. (32자 이하)
    const r = await deliver(subs as Sub[], payload, { topic: msg.id.replace(/-/g, "") });
    if (dedupe === "ok") {
      await admin.from("push_deliveries")
        .update({ sent: r.sent, failed: r.failed, removed: r.removed, detail: r.detail }).eq("message_id", msg.id);
    }
    return json({ sent: r.sent, failed: r.failed, removed: r.removed, dedupe });
  } catch (error) {
    // 발송 시도 자체가 실패했다면 다시 시도할 수 있도록 권한을 반납한다.
    if (dedupe === "ok") await admin.from("push_deliveries").delete().eq("message_id", msg.id);
    console.error("deliver crashed", error);
    return json({ error: "deliver_failed" }, 500);
  }
});
