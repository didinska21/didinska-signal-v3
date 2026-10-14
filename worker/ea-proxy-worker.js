// =====================================================================
// Didinska EA Proxy - Cloudflare Worker
// ---------------------------------------------------------------------
// Fungsi:
//   * EA mengirim 1 request berisi 10 prompt analis -> Worker memanggil
//     Groq SECARA PARALEL -> EA menerima semua hasil sekaligus.
//   * API key Groq disimpan di Worker (Secret), BUKAN di kode EA.
//   * EA wajib mengirim header X-EA-Token yang cocok dengan Secret EA_TOKEN.
//
// Endpoint (semua POST, kecuali GET / untuk cek hidup):
//   POST /analysts  body: {model,max_tokens,temperature,items:[{system,user},...]}
//                   -> {results:[{ok:true,content:"..."} | {ok:false,error:"..."}, ...]}
//   POST /call      body: {model,max_tokens,temperature,system,user}
//                   -> {ok:true,content:"..."} | {ok:false,error:"..."}
//
// Secrets / Variables yang harus di-set di dashboard Cloudflare:
//   EA_TOKEN         (wajib)  token rahasia, sama dengan InpProxyToken di EA
//   GROQ_API_KEY     (wajib)  API key Groq utama
//   GROQ_API_KEY_2   (opsional) key cadangan, dipakai saat key utama kena limit
//   GROQ_MODEL       (opsional) default model, kalau EA tidak mengirim model
// =====================================================================

const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";
const DEFAULT_MODEL = "openai/gpt-oss-120b";
const MAX_ITEMS = 12;

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function clamp(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

// Satu panggilan Groq dengan retry (429/5xx) dan fallback ke key cadangan.
async function callGroq(env, item, defaults, index) {
  const keys = [env.GROQ_API_KEY, env.GROQ_API_KEY_2].filter(Boolean);
  if (keys.length === 0) return { ok: false, error: "GROQ_API_KEY belum di-set di Worker" };

  const system = String((item && item.system) ?? "");
  const user = String((item && item.user) ?? "");
  if (!user) return { ok: false, error: "prompt user kosong" };

  const payload = {
    model: defaults.model,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
    max_tokens: defaults.maxTokens,
    temperature: defaults.temperature,
    reasoning_effort: "low",
    response_format: { type: "json_object" },
  };

  // Jeda kecil antar item supaya 10 request tidak menabrak limit di detik yang sama
  await sleep(index * 120);

  let lastError = "unknown";
  for (let attempt = 0; attempt < 3; attempt++) {
    const key = keys[attempt % keys.length];
    try {
      const res = await fetch(GROQ_URL, {
        method: "POST",
        headers: {
          Authorization: "Bearer " + key,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      if (res.ok) {
        const data = await res.json();
        const content = data && data.choices && data.choices[0] && data.choices[0].message
          ? data.choices[0].message.content
          : "";
        if (typeof content === "string" && content.length > 0) {
          return { ok: true, content };
        }
        lastError = "respons Groq kosong";
        continue;
      }

      lastError = "Groq HTTP " + res.status;
      if (res.status === 429 || res.status >= 500) {
        const retryAfter = parseFloat(res.headers.get("retry-after") || "0");
        const waitMs = Math.min(Math.max(retryAfter, 1), 6) * 1000 + index * 150;
        await sleep(waitMs);
        continue; // coba lagi (key berikutnya kalau ada)
      }
      break; // 4xx lain (key salah, payload salah) -> tidak ada gunanya diulang
    } catch (err) {
      lastError = "jaringan: " + String(err);
      await sleep(500);
    }
  }
  return { ok: false, error: lastError };
}

function readDefaults(env, body) {
  return {
    model: String(body.model || env.GROQ_MODEL || DEFAULT_MODEL),
    maxTokens: clamp(body.max_tokens, 200, 4000, 1500),
    temperature: clamp(body.temperature, 0, 1, 0.3),
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      return json({ service: "didinska-ea-proxy", status: "hidup" });
    }
    if (request.method !== "POST") return json({ ok: false, error: "method tidak diizinkan" }, 405);

    // Autentikasi: header X-EA-Token harus sama dengan secret EA_TOKEN
    const token = request.headers.get("X-EA-Token") || "";
    if (!env.EA_TOKEN || token !== env.EA_TOKEN) {
      return json({ ok: false, error: "tidak diizinkan" }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch (e) {
      return json({ ok: false, error: "JSON tidak valid" }, 400);
    }

    const defaults = readDefaults(env, body);

    if (url.pathname === "/analysts") {
      const items = Array.isArray(body.items) ? body.items.slice(0, MAX_ITEMS) : [];
      if (items.length === 0) return json({ ok: false, error: "items kosong" }, 400);
      const results = await Promise.all(items.map((it, idx) => callGroq(env, it, defaults, idx)));
      return json({ results });
    }

    if (url.pathname === "/call") {
      const result = await callGroq(env, body, defaults, 0);
      return json(result);
    }

    return json({ ok: false, error: "endpoint tidak ditemukan" }, 404);
  },
};
