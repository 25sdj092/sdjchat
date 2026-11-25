import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OLD_USER_ID = "04e5ca44-be63-456d-923a-0e3848a64754";
const STORAGE_PATHS = [
  "f9ce370f-9e8f-4ae5-a5d3-35ffc196dbae/ddae50b9-2362-4791-b02a-3b9d1b1c0a14.gif",
  "35501822-6795-43cd-8688-df8e5ef7d959/51de25b1-538b-4781-9146-b88ecd27fca5.jpg",
  "ec6635fb-018d-406e-bd7a-09be38d3799f/fa0585c5-0a0f-4972-8bc5-cece23560377.gif",
  "f9ce370f-9e8f-4ae5-a5d3-35ffc196dbae/a8454071-4ca1-42f3-842d-05018d16d0d4.jpg",
  "590d3091-d6b8-4012-9da7-cc924525d848/eabfa98a-a4ab-4cc6-9b8e-e5486dac9b1b.gif",
];

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return Response.json({ error: "Missing authorization" }, { status: 401 });
  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
  const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return Response.json({ error: "Invalid session" }, { status: 401 });
  const { data: isAdmin, error: adminError } = await userClient.rpc("is_current_app_admin");
  if (adminError || isAdmin !== true) return Response.json({ error: "Administrator only" }, { status: 403 });
  const { data: target, error: targetError } = await service.from("profiles").select("id,username,user_code").eq("id", OLD_USER_ID).maybeSingle();
  if (targetError) return Response.json({ error: targetError.message }, { status: 500 });
  if (!target) return Response.json({ error: "Legacy account already absent" }, { status: 404 });
  if (target.username !== "양성규기존" || target.user_code !== "4809") return Response.json({ error: "Target account identity mismatch" }, { status: 409 });
  const { error: storageError } = await service.storage.from("chat-images").remove(STORAGE_PATHS);
  if (storageError) return Response.json({ error: "Storage deletion failed: " + storageError.message }, { status: 500 });
  const { data: cleanup, error: cleanupError } = await userClient.rpc("admin_cleanup_legacy_account", { p_user: OLD_USER_ID });
  if (cleanupError) return Response.json({ error: "Database cleanup failed: " + cleanupError.message }, { status: 500 });
  const { error: deleteError } = await service.auth.admin.deleteUser(OLD_USER_ID);
  if (deleteError) return Response.json({ error: "Auth deletion failed: " + deleteError.message, cleanup }, { status: 500 });
  return Response.json({ success: true, deleted_user_id: OLD_USER_ID, deleted_storage_objects: STORAGE_PATHS.length, cleanup });
});
