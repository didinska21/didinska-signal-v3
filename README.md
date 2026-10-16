# DidinskaGridV2 v2.03 - Provider AI Bisa Custom

ZIP ini hanya berisi file yang berubah dari v2.02 (pasang di atas v2.02):
DidinskaGridV2.mq5, Include/GroqClient.mqh, worker/ea-proxy-worker.js.

## Provider yang didukung
| Pilihan di EA (InpAIProvider) | Keterangan |
|---|---|
| AIP_GROQ | Groq (bawaan) |
| AIP_OPENROUTER | OpenRouter (https://openrouter.ai/api/v1) |
| AIP_OPENAI | OpenAI (https://api.openai.com/v1) |
| AIP_ANTHROPIC | Claude lewat Messages API native |
| AIP_CUSTOM | Penyedia lain yang OpenAI-compatible (FastRouter, DeepSeek, Together, dll). Cek dokumen penyedia: harus punya endpoint chat/completions |

Isi juga `InpAIModel` dengan NAMA MODEL SESUAI PROVIDER (beda provider beda penamaan).

## Jalur Worker (disarankan) - langkah
1. Cloudflare -> Worker `ea-proxy` -> Edit code -> tempel isi `worker/ea-proxy-worker.js` baru -> Deploy.
2. Settings -> Variables and Secrets. Key dipisah per provider:
   - Groq: `GROQ_API_KEYS`
   - OpenRouter: `OPENROUTER_API_KEYS`
   - OpenAI: `OPENAI_API_KEYS`
   - Anthropic: `ANTHROPIC_API_KEYS`
   - Custom: `CUSTOM_API_KEYS` DAN `CUSTOM_BASE_URL` (contoh https://api.penyedia.com/v1, wajib https)
   Tiap variabel: key dipisah koma atau satu baris satu key. Kalau lebih dari ~85 key, lanjutkan di
   `..._API_KEYS_2` sampai `_9`.
3. Buka URL Worker di browser: akan tampil jumlah key per provider, mis. {"groq":100,"openrouter":0,...}.
4. Di EA: InpProxyUrl + InpProxyToken (sama seperti sebelumnya), pilih InpAIProvider dan isi InpAIModel.
   Provider bisa diganti dari EA tanpa mengubah Worker (selama key provider itu sudah ada di Worker).
5. Di MT5 cukup izinkan URL Worker di Allow WebRequest (alamat provider tidak diakses langsung oleh MT5).

## Jalur key langsung (tanpa Worker)
- Isi InpApiKeyPool / file groq_keys.txt / slot lama dengan key PROVIDER YANG DIPILIH.
- Untuk Custom, isi `InpAIBaseUrl`. Untuk provider lain boleh dikosongkan.
- Izinkan host provider di Allow WebRequest (mis. https://openrouter.ai, https://api.anthropic.com).

## Catatan per provider
- Anthropic: tidak ada "JSON mode". Prompt sudah meminta JSON dan Worker membersihkan pembungkus ```json.
  Kredit habis dilaporkan sebagai HTTP 400; ini sudah dikenali (key diistirahatkan).
- OpenAI: model seri gpt-5/o menolak `temperature` selain bawaan -> isi InpAITemperature = -1 (tidak dikirim).
  Field batas token otomatis `max_completion_tokens`.
- OpenRouter: nama model berformat vendor/model. Ada model yang tidak mendukung response_format;
  kalau muncul error 400, set InpAIExtraJson menjadi kosong.
- Groq/model reasoning: bawaan `reasoning_effort=low`. Di provider lain field ini TIDAK dikirim.
- InpAIExtraJson: potongan JSON TANPA kurung kurawal, contoh:
  "response_format":{"type":"json_object"}
  Untuk provider yang ingin dikustom lebih jauh. Di mode Worker nilai ini dikirim ke Worker sebagai objek.

## Keamanan
- EA TIDAK mengirim alamat provider ke Worker. Alamat ada di kode Worker (atau CUSTOM_BASE_URL milik Anda).
  Jadi kalau token EA bocor, key tidak bisa dibelokkan ke server orang lain.
- Key tiap provider terpisah; key Groq tidak pernah dikirim ke OpenRouter dan sebaliknya.
- Prompt berisi data pasar & ringkasan kalender (bukan data pribadi). Router pihak ketiga
  meneruskan prompt ke model di belakangnya; ketahui kebijakan data penyedianya.

## Yang belum diuji
Worker diuji dengan server tiruan untuk tiap bentuk respons provider (OpenAI pretty-print,
Groq ringkas, Anthropic dengan blok thinking, content null, kredit habis, model salah). Belum diuji
ke API asli, dan bagian EA belum dikompilasi. Perilaku parameter model pihak ketiga bisa berubah;
kalau ada HTTP 400, pesan error provider kini ikut tampil di log.
Pindah provider/model = ubah satu hal per putaran, lalu bandingkan akurasi di jurnal.
