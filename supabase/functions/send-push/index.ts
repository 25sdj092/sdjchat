import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }

  // The browser requests only the public half of the VAPID key pair.
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

  const messageId = String(body.message_id ?? "");
  if (!UUID_RE.test(messageId)) return json({ error: "bad_request" }, 400);

  const cfg = await getPushConfig(true).catch((error) => {
    console.error("push config read failed", error);
    return null;
  });
  if (!cfg) return json({ error: "push_config_unavailable" }, 500);
  const expectedSecret = String(cfg.sdjchat_push_webhook_secret ?? "");
  if (!expectedSecret || !safeEqual(req.headers.get("x-webhook-secret") ?? "", expectedSecret)) {
    return json({ error: "unauthorized" }, 401);
  }
  const vapidPublic = String(cfg.sdjchat_vapid_public_key ?? "");
  const vapidPrivate = String(cfg.sdjchat_vapid_private_key ?? "");
  const vapidSubject = String(cfg.sdjchat_vapid_subject ?? "");
  if (!vapidPublic || !vapidPrivate || !vapidSubject) return json({ error: "vapid_not_configured" }, 500);
  webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);

  const { data: msg, error: e1 } = await admin
    .from("messages")
    .select("id, conversation_id, sender_id, content, message_type, profiles(username), conversations(type, name)")
    .eq("id", messageId).maybeSingle();
  if (e1) return json({ error: "db_error" }, 500);
  if (!msg) return json({ sent: 0, reason: "message_not_found" });

  const { data: members, error: e2 } = await admin
    .from("conversation_members").select("user_id")
    .eq("conversation_id", msg.conversation_id).is("left_at", null).neq("user_id", msg.sender_id);
  if (e2) return json({ error: "db_error" }, 500);
  const userIds = (members ?? []).map((m) => m.user_id);
  if (!userIds.length) return json({ sent: 0, reason: "no_recipients" });

  const { data: subs, error: e3 } = await admin
    .from("push_subscriptions").select("id, subscription").in("user_id", userIds);
  if (e3) return json({ error: "db_error" }, 500);
  if (!subs?.length) return json({ sent: 0, reason: "no_subscriptions" });

  // deno-lint-ignore no-explicit-any
  const sender = (msg as any).profiles?.username ?? "새 메시지";
  // deno-lint-ignore no-explicit-any
  const conv = (msg as any).conversations;
  const title = conv?.type === "group" ? `${sender} · ${conv.name}` : sender;
  const notificationBody = msg.message_type === "image"
    ? "사진을 보냈습니다."
    : String(msg.content).replace(/\s+/g, " ").trim().slice(0, 80);
  const payload = JSON.stringify({ title, body: notificationBody, c: msg.conversation_id, tag: msg.id });

  const dead: string[] = [];
  let sent = 0;
  await Promise.allSettled(subs.map(async (sub) => {
    try {
      await webpush.sendNotification(sub.subscription, payload, { TTL: 60 * 60 * 24, urgency: "high" });
      sent++;
    } catch (error) {
      // deno-lint-ignore no-explicit-any
      const code = (error as any)?.statusCode;
      if (code === 404 || code === 410) dead.push(sub.id);
      else console.error("push failed", code, (error as Error)?.message);
    }
  }));
  if (dead.length) await admin.from("push_subscriptions").delete().in("id", dead);
  return json({ sent, removed: dead.length });
});