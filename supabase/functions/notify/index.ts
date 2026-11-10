// Ferents Team Training — надсилає сповіщення на телефони (Web Push + Telegram).
// Supabase → Edge Functions → назва «notify». Секрети: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, TELEGRAM_BOT_TOKEN.
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
      : kind === "request" ? await rpc("has_join_request")
      : ["announcement", "event", "event_join", "plan", "poll", "poll_close"].includes(kind) ? await rpc("is_coach")
      : false;
    if (!allowed) return json({ error: "forbidden" }, 403);

    // Кому надсилати — рахує база (service role)
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const tgToken = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
    const tgApi = async (method: string, body: unknown) =>
      await fetch(`https://api.telegram.org/bot${tgToken}/${method}`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
      }).then((x) => x.json()).catch(() => null);

    // Тренер закрив опитування — зупиняємо його в Telegram
    if (kind === "poll_close") {
      const { data: msgs } = await admin.from("poll_messages").select("chat_id, message_id").eq("poll_id", Number(b.poll_id));
      let stopped = 0;
      if (tgToken) for (const m of msgs ?? []) {
        const r = await tgApi("stopPoll", { chat_id: m.chat_id, message_id: m.message_id });
        if (r?.ok) stopped++;
        await new Promise((res) => setTimeout(res, 40));
      }
      return json({ stopped });
    }
    // Учасники події: лише акаунти, привʼязані до доданих спортсменів (спортсмени й батьки)
    let joinEmails: string[] | null = null;
    if (kind === "event_join") {
      const ids = (Array.isArray(b.athlete_ids) ? b.athlete_ids : []).map(String).slice(0, 300);
      const { data: links } = ids.length
        ? await admin.from("member_athletes").select("email").in("athlete_id", ids) : { data: [] };
      joinEmails = [...new Set((links ?? []).map((l: { email: string }) => String(l.email).toLowerCase()))]
        .filter((e) => e !== user.email!.toLowerCase());
      if (!joinEmails.length) return json({ sent: 0, telegram: 0, telegram_targets: 0 });
    }
    const { data: targets, error } = joinEmails
      ? await admin.from("push_subscriptions").select("endpoint, sub").in("email", joinEmails)
      : await admin.rpc("push_targets", {
        p_kind: kind,
        p_audience: b.audience ?? "all",
        p_section: b.section || null,
        p_group: b.group || null,
        p_exclude: user.email,
      });

    // Web Push — окремо: якщо ключі VAPID не задані чи щось зламалось, Telegram однаково піде
    let sent = 0;
    const gone: string[] = [];
    let pushError = "";
    try {
      if (error) throw new Error(error.message);
      const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
      if (!pub || !priv) throw new Error("no_vapid_keys");
      webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "mailto:rostyslavferents@gmail.com", pub, priv);
      const payload = JSON.stringify({
        title: String(b.title || "Ferents Team").slice(0, 80),
        body: String(b.body || "").slice(0, 240),
        url: String(b.url || "./"),
        tag: kind,
      });
      await Promise.all((targets ?? []).map(async (t: { endpoint: string; sub: webpush.PushSubscription }) => {
        try { await webpush.sendNotification(t.sub, payload, { TTL: 86400 }); sent++; }
        catch (e) { const s = (e as { statusCode?: number }).statusCode; if (s === 404 || s === 410) gone.push(t.endpoint); }
      }));
      // Пристрої, які відписались, прибираємо
      if (gone.length) await admin.from("push_subscriptions").delete().in("endpoint", gone);
    } catch (e) { pushError = String((e as Error)?.message || e); }

    // Telegram (якщо бот налаштований)
    let tgSent = 0, tgTargets = 0, tgError = "";
    const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
    if (!token) tgError = "no_bot_token";
    if (token) {
      const { data: chats, error: tgErr } = joinEmails
        ? await admin.from("telegram_links").select("chat_id").in("email", joinEmails)
        : await admin.rpc(kind === "poll" ? "telegram_targets_email" : "telegram_targets", {
        p_kind: kind,
        p_audience: b.audience ?? "all",
        p_section: b.section || null,
        p_group: b.group || null,
        p_exclude: user.email,
      });
      if (tgErr) tgError = tgErr.message;
      tgTargets = chats?.length ?? 0;
      // Опитування — нативне опитування Telegram; відповіді приймає функція telegram
      let poll: { id: number; question: string; options: string[]; multi: boolean } | null = null;
      if (kind === "poll" && chats?.length) {
        const { data: p } = await admin.from("polls").select("id, question, options, multi, closed").eq("id", Number(b.poll_id)).maybeSingle();
        if (p && !p.closed) poll = p as any;
        else tgError = "poll_not_found";
        // Telegram має надсилати нам відповіді на опитування (poll_answer)
        if (poll) {
          const info = await tgApi("getWebhookInfo", {});
          const allowed: string[] = info?.result?.allowed_updates ?? [];
          if (info?.result?.url && !allowed.includes("poll_answer")) {
            const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("ft-hook:" + tgToken));
            const secret = Array.from(new Uint8Array(h)).map((x) => x.toString(16).padStart(2, "0")).join("").slice(0, 48);
            await tgApi("setWebhook", { url: info.result.url, secret_token: secret, allowed_updates: ["message", "poll_answer"] });
          }
        }
      }
      if (poll) {
        const blocked: number[] = [];
        for (const c of chats as { chat_id: number }[]) {
          const r = await tgApi("sendPoll", {
            chat_id: c.chat_id, question: String(poll.question).slice(0, 300),
            options: poll.options.map((o) => ({ text: String(o).slice(0, 100) })),
            is_anonymous: false, allows_multiple_answers: !!poll.multi,
          });
          if (r?.ok) {
            tgSent++;
            await admin.from("poll_messages").upsert({
              tg_poll_id: String(r.result.poll.id), poll_id: poll.id, chat_id: c.chat_id, message_id: r.result.message_id,
            });
          } else {
            tgError = String(r?.description || "send_failed");
            if (r?.error_code === 403 || r?.error_code === 400 && /chat not found/i.test(r?.description || "")) blocked.push(c.chat_id);
          }
          await new Promise((res) => setTimeout(res, 40)); // ліміт Telegram ~30 повідомлень/с
        }
        if (blocked.length) await admin.from("telegram_links").delete().in("chat_id", blocked);
      } else if (kind !== "poll" && chats?.length) {
        const { data: cfg } = await admin.from("team_settings").select("value").eq("key", "telegram").maybeSingle();
        const app = String((cfg?.value as { app?: string } | null)?.app || "");
        const link = app ? new URL(String(b.url || "./"), app).href : "";
        const e = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));
        const title = String(b.title || "Ferents Team").slice(0, 120);
        const body = String(b.body || "").slice(0, 1000);
        const text = `<b>${e(title)}</b>` + (body ? `\n\n${e(body)}` : "");
        const blocked: number[] = [];
        for (const c of chats as { chat_id: number }[]) {
          const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              chat_id: c.chat_id, text, parse_mode: "HTML", disable_web_page_preview: true,
              ...(link.startsWith("https://") ? { reply_markup: { inline_keyboard: [[{ text: "Відкрити застосунок", url: link }]] } } : {}),
            }),
          }).then((x) => x.json()).catch(() => null);
          if (r?.ok) tgSent++;
          else {
            tgError = String(r?.description || "send_failed");
            if (r?.error_code === 403 || r?.error_code === 400 && /chat not found/i.test(r?.description || "")) blocked.push(c.chat_id);
          }
          await new Promise((res) => setTimeout(res, 40)); // ліміт Telegram ~30 повідомлень/с
        }
        // Хто заблокував бота — прибираємо
        if (blocked.length) await admin.from("telegram_links").delete().in("chat_id", blocked);
      }
    }
    return json({ sent, removed: gone.length, push_error: pushError || undefined,
      telegram: tgSent, telegram_targets: tgTargets, telegram_error: tgError || undefined });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
