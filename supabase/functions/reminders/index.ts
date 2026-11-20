// Ferents Team Training — нагадування спортсменам старшої групи в Telegram.
// Запускається щогодини (pg_cron). Секрет: TELEGRAM_BOT_TOKEN. Verify JWT: вимкнено —
// натомість ключ x-cron-key звіряється з таблицею private_keys (її бачить лише сервер).
// Що надсилає (за київським часом):
//   • зранку (за замовчуванням о 8:00) — відмітити «Готовність» + норма води на день (лише тим, хто ще не відмітився);
//   • за 2 год до тренування групи — перекус і вода з собою;
//   • після тренування — поїсти протягом години, вода, вчасно спати;
//   • о 13:00 — нагадування про воду.
// Тренер вмикає/вимикає види нагадувань у застосунку: Налаштування → Нагадування спортсменам.
import { createClient } from "npm:@supabase/supabase-js@2";

const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: { "Content-Type": "application/json" } });

function kyivNow() {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Kyiv", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hour12: false, weekday: "short",
  }).formatToParts(new Date()).map((x) => [x.type, x.value]));
  const wd = ({ Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 } as Record<string, number>)[p.weekday];
  return { day: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) % 24, wd };
}
const hourOf = (t: string | null) => (t ? Number(String(t).slice(0, 2)) : null);
// Кінець тренування округлюємо вгору: 19:30 → о 20:00 (щоб повідомлення прийшло вже після)
const hourUp = (t: string | null) => (t ? Number(String(t).slice(0, 2)) + (Number(String(t).slice(3, 5)) > 0 ? 1 : 0) : null);
const firstName = (n: string) => String(n || "").trim().split(/\s+/)[1] || String(n || "").trim().split(/\s+/)[0] || "";
const liters = (ml: number) => (Math.round(ml / 100) / 10).toLocaleString("uk-UA");

Deno.serve(async (req) => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: k } = await db.from("private_keys").select("v").eq("k", "cron").maybeSingle();
  if (!k?.v || req.headers.get("x-cron-key") !== k.v) return json({ error: "forbidden" }, 403);
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!token) return json({ error: "no_bot_token" }, 500);

  const body = await req.json().catch(() => ({}));
  const now = kyivNow();
  const hour = typeof body.hour === "number" ? body.hour : now.hour; // для перевірки вручну

  const { data: cfgRow } = await db.from("team_settings").select("value").eq("key", "reminders").maybeSingle();
  const cfg = { enabled: true, morning: true, training: true, water: true, morning_hour: 8, ...(cfgRow?.value ?? {}) } as Record<string, any>;
  if (!cfg.enabled) return json({ skipped: "disabled" });
  const { data: tgRow } = await db.from("team_settings").select("value").eq("key", "telegram").maybeSingle();
  const app = String((tgRow?.value as { app?: string } | null)?.app || "");

  const { data: targets, error } = await db.rpc("reminder_targets", { p_day: now.day });
  if (error) return json({ error: error.message }, 500);
  const { data: sched } = await db.from("schedule").select("weekday, group_name, section, start_time, end_time").eq("group_name", "Старша");
  const today = (sched ?? []).filter((s: any) => Number(s.weekday) === now.wd);

  let sent = 0;
  const send = async (chat: number, kind: string, text: string) => {
    const { error: dup } = await db.from("reminder_log").insert({ chat_id: chat, kind, day: now.day });
    if (dup) return; // уже надсилали сьогодні
    const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text, ...(app.startsWith("https://") ? { reply_markup: { inline_keyboard: [[{ text: "Відкрити застосунок", url: app }]] } } : {}) }),
    }).then((x) => x.json()).catch(() => null);
    if (r?.ok) sent++;
    else if (r?.error_code === 403) await db.from("telegram_links").delete().eq("chat_id", chat); // заблокував бота
    await new Promise((res) => setTimeout(res, 40));
  };

  for (const t of (targets ?? []) as any[]) {
    const mySessions = today.filter((s: any) => !s.section || !t.section || s.section === t.section);
    const trainDay = mySessions.length > 0;
    const w = Number(t.weight) || 0;
    const water = w ? w * 35 + (trainDay ? 750 : 0) : (trainDay ? 2500 : 2000);
    const name = firstName(t.full_name);

    if (cfg.morning && hour === Number(cfg.morning_hour) && !t.checked)
      await send(t.chat_id, "morning", `Доброго ранку${name ? ", " + name : ""}! ☀️\nВідміть у застосунку, як ти сьогодні — сон і самопочуття, 10 секунд.\n💧 Твоя норма води сьогодні — близько ${liters(water)} л.`);

    if (cfg.training) for (const s of mySessions) {
      const st = hourOf(s.start_time), en = hourUp(s.end_time) ?? (st !== null ? st + 2 : null);
      if (st !== null && hour === st - 2)
        await send(t.chat_id, "pre-" + st, `Через 2 години тренування (${String(s.start_time).slice(0, 5)}). 🥋\n🍌 Час легкого перекусу: банан, бутерброд з медом або йогурт.\n💧 Візьми з собою пляшку води 0,5–0,75 л.`);
      if (en !== null && hour === en)
        await send(t.chat_id, "post-" + en, `Гарне тренування! 💪\n🍽 Протягом години поїж: сир або кефір з бананом, або повноцінна вечеря.\n💧 Попий води.\n😴 І лягай вчасно — сон відновлює найкраще.`);
    }

    if (cfg.water && hour === 13)
      await send(t.chat_id, "water", `💧 Нагадування про воду: випий склянку зараз.\nСьогодні твоя норма — близько ${liters(water)} л${trainDay ? " — сьогодні ще й тренування" : ""}.`);
  }
  return json({ hour, day: now.day, targets: (targets ?? []).length, sent });
});
