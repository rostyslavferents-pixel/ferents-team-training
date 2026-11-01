// Ferents Team Training — Telegram-бот (сповіщення в Telegram).
// Supabase → Edge Functions → назва «telegram», вимкнути «Verify JWT».
// Секрет: TELEGRAM_BOT_TOKEN (від @BotFather).
// Також надсилає тренеру нові заяви-анкети з сайту (zayava.html) разом із PDF.
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

// Нова заява з сайту: тренер отримує повідомлення і PDF у Telegram.
// Без входу, тому перевіряємо: заява справжня, свіжа (до 15 хв) і ще не надсилалась.
async function onApplication(b: any) {
  if (!TOKEN) return json({ error: "no_token" }, 400);
  const id = Number(b.id);
  if (!Number.isFinite(id)) return json({ error: "bad_id" }, 400);
  const { data: a } = await admin.from("applications")
    .select("id, created_at, child_name, section, group_name, signer_name, data, consents").eq("id", id).maybeSingle();
  if (!a) return json({ error: "not_found" }, 404);
  if (Date.now() - new Date(a.created_at).getTime() > 15 * 60000 || a.consents?.tg_sent) return json({ ok: true, skipped: true });
  await admin.from("applications").update({ consents: { ...(a.consents || {}), tg_sent: new Date().toISOString() } }).eq("id", id);

  const { data: chats } = await admin.rpc("telegram_targets", {
    p_kind: "request", p_audience: "all", p_section: null, p_group: null, p_exclude: null,
  });
  if (!chats?.length) return json({ ok: true, telegram: 0 });

  const d = a.data || {};
  const parent = ["mother", "father"].map((p) => d[p + "_name"] && d[p + "_phone"] ? `${d[p + "_name"]}, ${d[p + "_phone"]}` : "").filter(Boolean);
  const health = d.health && String(d.health).toLowerCase() !== "немає" ? String(d.health) : "";
  const text = `📝 <b>Нова заява-анкета № ${a.id}</b>\n\n<b>${esc(a.child_name)}</b>` +
    ([a.section, a.group_name].filter(Boolean).length ? `\n${esc([a.section, a.group_name].filter(Boolean).join(" · "))}` : "") +
    (d.birth ? `\nНародження: ${esc(String(d.birth).split("-").reverse().join("."))}` : "") +
    (parent.length ? `\n\n${esc(parent.join("\n"))}` : "") +
    (health ? `\n\n⚠️ Здоровʼя: ${esc(health.slice(0, 300))}` : "") +
    `\n\nПідписав(ла): ${esc(a.signer_name)}`;
  const app = await appUrl();
  const link = app ? new URL("zayava.html?id=" + a.id, app).href : "";
  const kb = link.startsWith("https://") ? { inline_keyboard: [[{ text: "Відкрити заяву", url: link }]] } : undefined;

  // PDF, який зробив телефон батьків (до 3 МБ); без нього — просто повідомлення
  let pdf: Uint8Array | null = null;
  const b64 = typeof b.pdf === "string" ? b.pdf : "";
  if (b64 && b64.length < 4_000_000) {
    try {
      const bin = atob(b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      if (bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46) pdf = bytes; // %PDF
    } catch (_) { pdf = null; }
  }
  const fileName = `Заява ${String(a.child_name).replace(/[\\/:*?"<>|]+/g, "")} №${a.id}.pdf`;

  let sent = 0;
  for (const c of chats as { chat_id: number }[]) {
    let r: any = null;
    if (pdf) {
      const fd = new FormData();
      fd.append("chat_id", String(c.chat_id));
      fd.append("caption", text.slice(0, 1000));
      fd.append("parse_mode", "HTML");
      if (kb) fd.append("reply_markup", JSON.stringify(kb));
      fd.append("document", new Blob([pdf], { type: "application/pdf" }), fileName);
      r = await fetch(`https://api.telegram.org/bot${TOKEN}/sendDocument`, { method: "POST", body: fd }).then((x) => x.json()).catch(() => null);
    }
    if (!r?.ok) r = await tg("sendMessage", { chat_id: c.chat_id, text, parse_mode: "HTML", disable_web_page_preview: true, ...(kb ? { reply_markup: kb } : {}) });
    if (r?.ok) sent++;
    await new Promise((res) => setTimeout(res, 40));
  }
  return json({ ok: true, telegram: sent });
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
    if (b.action === "application") return await onApplication(b);
    return json({ error: "unknown" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
