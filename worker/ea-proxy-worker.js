// =====================================================================
// Didinska EA Proxy - Cloudflare Worker  (v3: multi-provider + banyak key)
// ---------------------------------------------------------------------
// Provider yang didukung (dipilih EA lewat field "provider"):
//   groq        Groq (OpenAI-compatible)
//   openrouter  OpenRouter (OpenAI-compatible)
//   openai      OpenAI
//   anthropic   Anthropic (Messages API native)
//   custom      Provider OpenAI-compatible lain (FastRouter, DeepSeek, Together, dll)
//               -> alamat diatur di Worker lewat variabel CUSTOM_BASE_URL
//
// KEAMANAN:
//   * EA TIDAK PERNAH mengirim alamat (URL) provider. Alamat ditetapkan di kode
//     Worker (atau CUSTOM_BASE_URL milik Anda). Jadi sekalipun token EA bocor,
//     key Anda tidak bisa diarahkan ke server orang lain.
//   * Key dipisah per provider (GROQ_..., OPENROUTER_..., dst). Key Groq tidak
//     pernah dikirim ke OpenRouter, dan sebaliknya.
//   * CUSTOM_BASE_URL wajib https.
//
// Endpoint:
//   GET  /          -> cek hidup + jumlah key per provider (tanpa membuka key)
//   POST /analysts  body: {provider,model,max_tokens,temperature,extra,items:[{system,user},...]}
//                   -> {results:[{ok:true,content:"..."} | {ok:false,error:"..."}, ...]}
//   POST /call      body: {provider,model,max_tokens,temperature,extra,system,user}
//                   -> {ok:true,content:"..."} | {ok:false,error:"..."}
//   temperature: angka 0-1, atau null untuk TIDAK mengirim (perlu untuk sebagian model OpenAI).
//   extra: objek JSON opsional yang digabung ke body request provider
//          (kalau tidak dikirim -> bawaan provider; {} -> tanpa tambahan).
//
// Secrets / Variables di dashboard Cloudflare:
//   EA_TOKEN                 (wajib) sama dengan InpProxyToken di EA
//   <PREFIX>_API_KEYS        key dipisah KOMA atau baris baru. PREFIX = GROQ | OPENROUTER |
//                            OPENAI | ANTHROPIC | CUSTOM
//   <PREFIX>_API_KEYS_2..9   lanjutan kalau key banyak (batas ~5 KB per variabel = ~85 key)
//   <PREFIX>_API_KEY, <PREFIX>_API_KEY_2   (cara lama, tetap dibaca)
//   <PREFIX>_MODEL           (opsional) model bawaan kalau EA tidak mengirim model
//   CUSTOM_BASE_URL          (hanya provider custom) mis. https://api.contoh.com/v1
//   KEY_STATE                (opsional) KV namespace binding: ingatan key mati tahan restart
// =====================================================================

const MAX_ITEMS = 12;
const MAX_ATTEMPTS = 6;                       // maks key BERBEDA per item (6 item x 6 = 36 < batas 50 subrequest paket gratis)
const DEAD_AUTH_MS = 12 * 3600 * 1000;        // 401/402/403 -> istirahat 12 jam
const DEAD_QUOTA_MS = 6 * 3600 * 1000;        // saldo/kuota habis -> 6 jam
const CREDIT_WORDS = /quota|billing|credit|insufficient|spend|balance|payment/i;

const JSON_MODE = { response_format: { type: "json_object" } };

const PROVIDERS = {
  groq: {
    type: "openai", prefix: "GROQ", url: "https://api.groq.com/openai/v1/chat/completions",
    model: "openai/gpt-oss-120b", tokenParam: "max_tokens",
    extra: { reasoning_effort: "low", ...JSON_MODE },
  },
  openrouter: {
    type: "openai", prefix: "OPENROUTER", url: "https://openrouter.ai/api/v1/chat/completions",
    model: "openai/gpt-oss-120b", tokenParam: "max_tokens", extra: { ...JSON_MODE },
  },
  openai: {
    type: "openai", prefix: "OPENAI", url: "https://api.openai.com/v1/chat/completions",
    model: "gpt-4o-mini", tokenParam: "max_completion_tokens", extra: { ...JSON_MODE },
  },
  anthropic: {
    type: "anthropic", prefix: "ANTHROPIC", url: "https://api.anthropic.com/v1/messages",
    model: "claude-haiku-5-5", tokenParam: "max_tokens", extra: {},
  },
  custom: {
    type: "openai", prefix: "CUSTOM", urlFromEnv: "CUSTOM_BASE_URL",
    model: "", tokenParam: "max_tokens", extra: {},
  },
};

// Status key (hidup selama isolate Worker hidup; opsional dipersist ke KV)
const state = {
  cooldown: new Map(),   // id -> waktu (ms) key boleh dipakai lagi
  dead: new Map(),       // id -> waktu (ms) key diistirahatkan sampai
  kvLoadedAt: 0,
  dirty: false,
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function clamp(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

// ---------------------------------------------------------------------
// Key
// ---------------------------------------------------------------------
function parseKeys(text) {
  return String(text || "").split(/[\s,;]+/).map((k) => k.trim()).filter((k) => k.length >= 10);
}

function keyVarNames(prefix) {
  const names = [`${prefix}_API_KEYS`];
  for (let i = 2; i <= 9; i++) names.push(`${prefix}_API_KEYS_${i}`);
  names.push(`${prefix}_API_KEY`, `${prefix}_API_KEY_2`);
  return names;
}

function collectKeys(env, prefix) {
  const seen = new Set();
  const all = [];
  for (const name of keyVarNames(prefix)) {
    for (const k of parseKeys(env[name])) {
      if (!seen.has(k)) { seen.add(k); all.push(k); }
    }
  }
  return all;
}

// ID key untuk status/KV: hash seluruh key (cyrb53) + nama provider.
// Tidak bisa dibalik jadi key dan tidak membuka satu karakter pun dari key.
const idCache = new Map();
function keyId(provider, key) {
  const ck = provider + "|" + key;
  let id = idCache.get(ck);
  if (id) return id;
  let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
  for (let i = 0; i < ck.length; i++) {
    const ch = ck.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  id = provider + ":" + (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
  idCache.set(ck, id);
  return id;
}

const isBlocked = (id, now) => (state.dead.get(id) || 0) > now || (state.cooldown.get(id) || 0) > now;
function markDead(id, ms) { state.dead.set(id, Date.now() + ms); state.dirty = true; }
function markCooldown(id, ms) { state.cooldown.set(id, Date.now() + ms); }

function countBlocked(provider, keys) {
  const now = Date.now();
  let n = 0;
  for (const k of keys) if (isBlocked(keyId(provider, k), now)) n++;
  return n;
}

async function loadKvState(env) {
  if (!env.KEY_STATE) return;
  const now = Date.now();
  if (now - state.kvLoadedAt < 60000) return;
  state.kvLoadedAt = now;
  try {
    const raw = await env.KEY_STATE.get("dead");
    if (!raw) return;
    for (const [id, until] of Object.entries(JSON.parse(raw))) {
      if (Number(until) > now) state.dead.set(id, Math.max(Number(until), state.dead.get(id) || 0));
    }
  } catch (e) { /* KV hanya optimasi */ }
}

async function saveKvState(env) {
  if (!env.KEY_STATE || !state.dirty) return;
  state.dirty = false;
  const now = Date.now();
  const obj = {};
  for (const [id, until] of state.dead) if (until > now) obj[id] = until;
  try { await env.KEY_STATE.put("dead", JSON.stringify(obj), { expirationTtl: 86400 }); } catch (e) { /* abaikan */ }
}

// ---------------------------------------------------------------------
// Provider: URL, payload, header, ekstraksi jawaban
// ---------------------------------------------------------------------
function resolveUrl(spec, env) {
  if (spec.url) return spec.url;
  let base = String(env[spec.urlFromEnv] || "").trim();
  if (!base.startsWith("https://")) return null;          // wajib https
  base = base.replace(/\/+$/, "");
  if (!/\/chat\/completions$/.test(base)) base += "/chat/completions";
  return base;
}

function buildPayload(spec, d, system, user) {
  const payload = { model: d.model };
  if (spec.type === "anthropic") {
    payload.max_tokens = d.maxTokens;
    payload.system = system;
    payload.messages = [{ role: "user", content: user }];
  } else {
    payload.messages = [{ role: "system", content: system }, { role: "user", content: user }];
    payload[spec.tokenParam] = d.maxTokens;
  }
  if (d.temperature !== null) payload.temperature = d.temperature;
  return Object.assign(payload, d.extra);
}

function buildHeaders(spec, key) {
  if (spec.type === "anthropic") {
    return { "x-api-key": key, "anthropic-version": "2023-06-01", "Content-Type": "application/json" };
  }
  return { Authorization: "Bearer " + key, "Content-Type": "application/json" };
}

function extractText(spec, data) {
  if (spec.type === "anthropic") {
    const blocks = Array.isArray(data && data.content) ? data.content : [];
    return blocks.filter((b) => b && b.type === "text" && typeof b.text === "string").map((b) => b.text).join("");
  }
  const msg = data && data.choices && data.choices[0] && data.choices[0].message;
  const c = msg ? msg.content : "";
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.map((p) => (p && typeof p.text === "string" ? p.text : "")).join("");
  return "";
}

// Beberapa model membungkus JSON dengan ```json ... ``` atau menambah kalimat -> ambil objeknya saja
function cleanJson(text) {
  let t = String(text).trim();
  t = t.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  const a = t.indexOf("{");
  const b = t.lastIndexOf("}");
  return a >= 0 && b > a ? t.slice(a, b + 1) : t;
}

function providerErrorText(text) {
  try {
    const o = JSON.parse(text);
    const m = (o && o.error && (o.error.message || o.error)) || o.message;
    if (m) return String(typeof m === "string" ? m : JSON.stringify(m)).slice(0, 160);
  } catch (e) { /* bukan JSON */ }
  return String(text || "").slice(0, 120);
}

// ---------------------------------------------------------------------
// Satu panggilan AI: coba beberapa key berbeda sampai berhasil
// ---------------------------------------------------------------------
async function callAI(ctx, item, index) {
  const { provider, spec, url, keys, defaults, startOffset } = ctx;
  if (keys.length === 0) {
    return { ok: false, error: `Tidak ada API key untuk provider "${provider}" (isi ${spec.prefix}_API_KEYS)` };
  }
  const system = String((item && item.system) ?? "");
  const user = String((item && item.user) ?? "");
  if (!user) return { ok: false, error: "prompt user kosong" };

  const payload = buildPayload(spec, defaults, system, user);
  await sleep(index * 60);   // jeda kecil antar item

  let tried = 0;
  let lastError = "unknown";

  for (let step = 0; step < keys.length && tried < MAX_ATTEMPTS; step++) {
    const key = keys[(startOffset + index + step) % keys.length];
    const id = keyId(provider, key);
    if (isBlocked(id, Date.now())) continue;

    tried++;
    try {
      const res = await fetch(url, { method: "POST", headers: buildHeaders(spec, key), body: JSON.stringify(payload) });

      if (res.ok) {
        const data = await res.json();
        const text = extractText(spec, data);
        if (text.length > 0) return { ok: true, content: cleanJson(text) };
        lastError = "respons provider kosong";
        continue;
      }

      const status = res.status;
      const text = await res.text().catch(() => "");
      lastError = `${provider} HTTP ${status}`;

      if (status === 401 || status === 402 || status === 403) {
        markDead(id, DEAD_AUTH_MS);
        lastError += ": " + providerErrorText(text);
        continue;
      }
      if (status === 429) {
        if (CREDIT_WORDS.test(text)) {
          markDead(id, DEAD_QUOTA_MS);
          lastError = `${provider} HTTP 429 (saldo/kuota habis)`;
        } else {
          const ra = parseFloat(res.headers.get("retry-after") || "0");
          markCooldown(id, clamp(ra, 5, 120, 60) * 1000);
        }
        continue;
      }
      if (status === 400 && CREDIT_WORDS.test(text)) {   // mis. Anthropic: "credit balance is too low"
        markDead(id, DEAD_QUOTA_MS);
        lastError = `${provider} HTTP 400 (saldo/kredit habis)`;
        continue;
      }
      if (status >= 500) continue;                        // gangguan sisi provider -> key lain
      lastError += ": " + providerErrorText(text);        // 400/404 dll: salah model/parameter, ganti key tidak membantu
      break;
    } catch (err) {
      lastError = "jaringan: " + String(err);
      await sleep(300);
    }
  }

  if (tried === 0) lastError = "semua key sedang diistirahatkan (mati/saldo habis/rate limit)";
  return { ok: false, error: `${lastError} (dicoba ${tried} key; ${keys.length - countBlocked(provider, keys)}/${keys.length} key aktif)` };
}

function readDefaults(env, spec, body) {
  let extra = spec.extra;
  if (body.extra !== undefined && body.extra !== null && typeof body.extra === "object" && !Array.isArray(body.extra)) {
    extra = body.extra;
  }
  return {
    model: String(body.model || env[`${spec.prefix}_MODEL`] || spec.model || ""),
    maxTokens: clamp(body.max_tokens, 200, 8000, 1500),
    temperature: body.temperature === null ? null : clamp(body.temperature, 0, 1, 0.3),
    extra,
  };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      const keys = {};
      for (const [name, spec] of Object.entries(PROVIDERS)) keys[name] = collectKeys(env, spec.prefix).length;
      return json({ service: "didinska-ea-proxy", status: "hidup", keys });
    }
    if (request.method !== "POST") return json({ ok: false, error: "method tidak diizinkan" }, 405);

    const token = request.headers.get("X-EA-Token") || "";
    if (!env.EA_TOKEN || token !== env.EA_TOKEN) return json({ ok: false, error: "tidak diizinkan" }, 401);

    let body;
    try { body = await request.json(); } catch (e) { return json({ ok: false, error: "JSON tidak valid" }, 400); }

    const provider = String(body.provider || "groq").toLowerCase();
    const spec = PROVIDERS[provider];
    if (!spec) return json({ ok: false, error: `provider "${provider}" tidak dikenal` }, 400);

    const endpoint = resolveUrl(spec, env);
    if (!endpoint) return json({ ok: false, error: `${spec.urlFromEnv} belum di-set atau bukan https` }, 400);

    const keys = collectKeys(env, spec.prefix);
    await loadKvState(env);

    const cctx = {
      provider, spec, url: endpoint, keys,
      defaults: readDefaults(env, spec, body),
      startOffset: keys.length > 0 ? Math.floor(Math.random() * keys.length) : 0,
    };
    if (!cctx.defaults.model) return json({ ok: false, error: "model belum ditentukan (kirim dari EA atau set " + spec.prefix + "_MODEL)" }, 400);

    let response;
    if (url.pathname === "/analysts") {
      const items = Array.isArray(body.items) ? body.items.slice(0, MAX_ITEMS) : [];
      if (items.length === 0) return json({ ok: false, error: "items kosong" }, 400);
      const results = await Promise.all(items.map((it, idx) => callAI(cctx, it, idx)));
      response = json({ results });
    } else if (url.pathname === "/call") {
      response = json(await callAI(cctx, body, 0));
    } else {
      return json({ ok: false, error: "endpoint tidak ditemukan" }, 404);
    }

    if (state.dirty) {
      if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(saveKvState(env));
      else await saveKvState(env);
    }
    return response;
  },
};
