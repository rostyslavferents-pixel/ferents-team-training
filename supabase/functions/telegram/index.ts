// Ferents Team Training — Telegram-бот (сповіщення в Telegram).
// Supabase → Edge Functions → назва «telegram», вимкнути «Verify JWT».
// Секрет: TELEGRAM_BOT_TOKEN (від @BotFather).
// Також надсилає батькам нагадування про оплату (кнопка в розділі «Оплати»).
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, "Content-Type": "application/json" } });

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const tg = async (method: string, body: unknown) => {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  return await r.json();
};
const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));

// Секрет вебхука виводимо з токена — окремо задавати не треба
async function hookSecret() {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("ft-hook:" + TOKEN));
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 48);
}

async function appUrl() {
  const { data } = await admin.from("team_settings").select("value").eq("key", "telegram").maybeSingle();
  return (data?.value as { app?: string } | null)?.app || "";
}
const openBtn = (url: string) => url ? { reply_markup: { inline_keyboard: [[{ text: "Відкрити застосунок", url }]] } } : {};

// Повідомлення від людей у боті
async function onUpdate(u: any) {
  const msg = u.message;
  if (!msg?.chat || msg.chat.type !== "private") return;
  const chat = msg.chat.id as number;
  const text = String(msg.text || "").trim();
  const app = await appUrl();

  if (text.startsWith("/start")) {
    const code = text.split(/\s+/)[1] || "";
    if (!code) {
      await tg("sendMessage", { chat_id: chat, parse_mode: "HTML", ...openBtn(app),
        text: "👋 Це бот <b>Ferents Team</b>.\n\nЩоб отримувати сповіщення, відкрийте застосунок → <b>Налаштування</b> → <b>Підключити Telegram</b>." });
      return;
    }
    const { data: row } = await admin.from("telegram_codes").select("email, created_at").eq("code", code).maybeSingle();
    if (!row || Date.now() - new Date(row.created_at).getTime() > 86400000) {
      await tg("sendMessage", { chat_id: chat, ...openBtn(app),
        text: "⏳ Посилання застаріло. Натисніть «Підключити Telegram» у застосунку ще раз." });
      return;
    }
    const name = [msg.from?.first_name, msg.from?.last_name].filter(Boolean).join(" ") || null;
    await admin.from("telegram_links").upsert({ chat_id: chat, email: row.email, tg_name: name });
    await admin.from("telegram_codes").delete().eq("code", code);

    // Кого стосується акаунт
    const { data: links } = await admin.from("member_athletes").select("athlete_id").eq("email", row.email);
    const ids = (links ?? []).map((l: any) => l.athlete_id);
    const { data: kids } = ids.length
      ? await admin.from("athletes").select("full_name").in("id", ids)
      : { data: [] as any[] };
    const who = (kids ?? []).map((k: any) => k.full_name).join(", ");
    await tg("sendMessage", { chat_id: chat, parse_mode: "HTML", ...openBtn(app),
      text: "✅ <b>Telegram підключено!</b>\n\n" +
        (who ? `Сповіщення про: <b>${esc(who)}</b>\n\n` : "") +
        "Сюди приходитимуть оголошення тренера, нові події та інші важливі новини.\n\nВідключити: /stop" });
    return;
  }

  if (text === "/stop") {
    await admin.from("telegram_links").delete().eq("chat_id", chat);
    await tg("sendMessage", { chat_id: chat,
      text: "🔕 Сповіщення вимкнено. Увімкнути знову — у застосунку: Налаштування → Підключити Telegram." });
    return;
  }

  const { data: linked } = await admin.from("telegram_links").select("chat_id").eq("chat_id", chat).maybeSingle();
  await tg("sendMessage", { chat_id: chat, ...openBtn(app),
    text: linked
      ? "Я надсилаю сповіщення команди Ferents Team 🥋 Усе інше — у застосунку."
      : "Щоб отримувати сповіщення, відкрийте застосунок → Налаштування → Підключити Telegram." });
}

// Тренер натиснув «Підключити бота» в застосунку
async function setup(req: Request, b: any) {
  const asUser = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  if ((await asUser.rpc("is_coach")).data !== true) return json({ error: "forbidden" }, 403);
  if (!TOKEN) return json({ error: "no_token" }, 400);

  const me = await tg("getMe", {});
  if (!me.ok) return json({ error: "bad_token" }, 400);
  const hook = await tg("setWebhook", {
    url: `${URL_}/functions/v1/telegram`,
    secret_token: await hookSecret(),
    allowed_updates: ["message"],
    drop_pending_updates: true,
  });
  if (!hook.ok) return json({ error: "webhook: " + (hook.description || "") }, 400);
  await tg("setMyCommands", { commands: [{ command: "stop", description: "Вимкнути сповіщення" }] });

  const app = /^https:\/\//.test(String(b.app || "")) ? String(b.app) : "";
  const { error } = await admin.from("team_settings").upsert({
    key: "telegram", value: { username: me.result.username, app }, updated_at: new Date().toISOString(),
  });
  if (error) return json({ error: error.message }, 500);
  return json({ username: me.result.username });
}

// Тренер натиснув «Надіслати в Telegram» у нагадуваннях про оплату.
// items: [{ id: athlete_id, text }]; dry: true — лише дізнатись, у кого підключено Telegram.
async function onRemind(req: Request, b: any) {
  const asUser = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  if ((await asUser.rpc("is_coach")).data !== true) return json({ error: "forbidden" }, 403);
  if (!TOKEN) return json({ error: "no_token" }, 400);
  const items = (Array.isArray(b.items) ? b.items : []).slice(0, 300)
    .map((i: any) => ({ id: String(i?.id ?? ""), text: String(i?.text ?? "").slice(0, 1500) })).filter((i: any) => i.id);
  if (!items.length) return json({ with: [], sent: 0 });

  // Хто з батьків (або сам спортсмен, якщо батьків немає) підключив Telegram
  const { data: links } = await admin.from("member_athletes").select("email, athlete_id").in("athlete_id", items.map((i: any) => i.id));
  const emails = [...new Set((links ?? []).map((l: any) => String(l.email).toLowerCase()))];
  const { data: mem } = emails.length ? await admin.from("members").select("email, role").in("email", emails) : { data: [] as any[] };
  const role = new Map((mem ?? []).map((m: any) => [String(m.email).toLowerCase(), m.role]));
  const { data: tl } = emails.length ? await admin.from("telegram_links").select("chat_id, email").in("email", emails) : { data: [] as any[] };
  const chatsOf = (id: string) => {
    const mine = (links ?? []).filter((l: any) => String(l.athlete_id) === id).map((l: any) => String(l.email).toLowerCase());
    const parents = mine.filter((e: string) => role.get(e) === "parent");
    const who = parents.some((e: string) => (tl ?? []).some((t: any) => String(t.email).toLowerCase() === e)) ? parents : mine;
    return [...new Set((tl ?? []).filter((t: any) => who.includes(String(t.email).toLowerCase())).map((t: any) => Number(t.chat_id)))];
  };
  const withTg = items.filter((i: any) => chatsOf(i.id).length).map((i: any) => i.id);
  if (b.dry) return json({ with: withTg });

  const app = await appUrl();
  let sent = 0;
  const reached: string[] = [];
  for (const it of items) {
    let ok = false;
    for (const chat of chatsOf(it.id)) {
      const r = await tg("sendMessage", { chat_id: chat, text: "💳 " + it.text, ...openBtn(app) });
      if (r?.ok) { sent++; ok = true; }
      await new Promise((res) => setTimeout(res, 40)); // ліміт Telegram ~30 повідомлень/с
    }
    if (ok) reached.push(it.id);
  }
  return json({ with: withTg, sent, reached });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const secret = req.headers.get("X-Telegram-Bot-Api-Secret-Token");
    if (secret !== null) {
      if (!TOKEN || secret !== await hookSecret()) return new Response("forbidden", { status: 403 });
      try { await onUpdate(await req.json()); } catch (e) { console.error(e); }
      return new Response("ok"); // Telegram завжди відповідаємо «ok», щоб не повторював
    }
    const b = await req.json().catch(() => ({}));
    if (b.action === "setup") return await setup(req, b);
    if (b.action === "remind") return await onRemind(req, b);
    return json({ error: "unknown" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
