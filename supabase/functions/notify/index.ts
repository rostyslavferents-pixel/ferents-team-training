// Ferents Team Training — надсилає сповіщення на телефони (Web Push).
// Supabase → Edge Functions → назва «notify». Секрети: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const authHeader = req.headers.get("Authorization") ?? "";
    // Хто надсилає — перевіряємо його правами
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user?.email) return json({ error: "not_signed_in" }, 401);

    const b = await req.json();
    const kind = String(b.kind || "");
    const rpc = async (fn: string) => (await asUser.rpc(fn)).data === true;
    const allowed = kind === "chat" ? await rpc("is_athlete_member")
      : kind === "joined" ? await rpc("is_member")
      : ["announcement", "event", "plan"].includes(kind) ? await rpc("is_coach")
      : false;
    if (!allowed) return json({ error: "forbidden" }, 403);

    // Кому надсилати — рахує база (service role)
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: targets, error } = await admin.rpc("push_targets", {
      p_kind: kind,
      p_audience: b.audience ?? "all",
      p_section: b.section || null,
      p_group: b.group || null,
      p_exclude: user.email,
    });
    if (error) return json({ error: error.message }, 500);

    webpush.setVapidDetails(
      Deno.env.get("VAPID_SUBJECT") ?? "mailto:rostyslavferents@gmail.com",
      Deno.env.get("VAPID_PUBLIC_KEY")!,
      Deno.env.get("VAPID_PRIVATE_KEY")!,
    );
    const payload = JSON.stringify({
      title: String(b.title || "Ferents Team").slice(0, 80),
      body: String(b.body || "").slice(0, 240),
      url: String(b.url || "./"),
      tag: kind,
    });

    let sent = 0;
    const gone: string[] = [];
    await Promise.all((targets ?? []).map(async (t: { endpoint: string; sub: webpush.PushSubscription }) => {
      try { await webpush.sendNotification(t.sub, payload, { TTL: 86400 }); sent++; }
      catch (e) { const s = (e as { statusCode?: number }).statusCode; if (s === 404 || s === 410) gone.push(t.endpoint); }
    }));
    // Пристрої, які відписались, прибираємо
    if (gone.length) await admin.from("push_subscriptions").delete().in("endpoint", gone);
    return json({ sent, removed: gone.length });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
