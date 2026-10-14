//+------------------------------------------------------------------+
//|                                                  GroqClient.mqh   |
//|         Didinska Grid V2 - Lapisan Komunikasi Groq API Bersama    |
//|                                                                    |
//|   Modul ini adalah SATU-SATUNYA titik yang boleh memanggil Groq   |
//|   API secara langsung di seluruh EA. Semua 10 AI analis dan 1 AI  |
//|   Penyimpul WAJIB lewat CGroqClient::Call() supaya:                |
//|     - Skema 12 API key (10 analis + 1 penyimpul + 1 cadangan)      |
//|       dikelola konsisten di satu tempat, tidak duplikat logic.     |
//|     - Deteksi rate-limit (HTTP 429) dan fallback ke key cadangan   |
//|       berjalan seragam untuk semua pemanggil.                      |
//|     - Parsing amplop respons (OpenAI/Groq chat.completions) dan    |
//|       unescape isi "content" hanya perlu ditulis & diuji sekali.   |
//+------------------------------------------------------------------+
// PENJELASAN SKEMA 12 API KEY (bahasa sederhana):
//   Slot 0-9   -> khusus 10 AI analis (1 slot per analis, biar kuota/rate
//                 limit tidak saling rebutan antar analis).
//   Slot 10    -> khusus AI Penyimpul (model reasoning, butuh token lebih
//                 besar, dipisah supaya tidak berebut kuota dengan analis).
//   Slot 11    -> CADANGAN UNIVERSAL. Kalau slot 0-10 (siapa pun, bahkan
//                 lebih dari satu sekaligus) kena rate limit/gagal, modul
//                 ini otomatis mencoba ulang panggilan itu memakai key di
//                 slot 11. Jadi 1 key cadangan menutupi semua kemungkinan
//                 kegagalan, tidak perlu 1 cadangan per analis.
//
//   Kalau slot cadangan (11) SENDIRI juga gagal/kosong, panggilan itu
//   dianggap gagal untuk siklus ini -> pemanggil (Analysts.mqh /
//   AISummarizer.mqh) harus siap menangani hasil kosong (skip opini AI
//   tersebut, jangan sampai EA crash atau salah membaca data kosong
//   sebagai sinyal valid).
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

//+------------------------------------------------------------------+
//| Jumlah total slot API key yang dikelola modul ini                  |
//+------------------------------------------------------------------+
#define GROQ_TOTAL_SLOTS   12
#define GROQ_RESERVE_SLOT  11   // index slot cadangan universal (slot ke-12)

//+------------------------------------------------------------------+
//| Hasil mentah satu kali pemanggilan AI                              |
//+------------------------------------------------------------------+
// PENJELASAN: struct ini dikembalikan oleh Call() ke pemanggil (misalnya
// CAnalystEngine di Analysts.mqh). Isinya masih berupa TEKS JSON hasil
// analisa AI (sudah dibongkar dari amplop chat.completions, sudah
// di-unescape) -- parsing field spesifik seperti "signal"/"bias" tetap
// jadi tanggung jawab pemanggil, karena tiap analis punya skema JSON
// yang berbeda-beda.
struct GroqCallResult
{
   bool     success;          // true kalau berhasil dapat balasan dari AI
   string   content;          // isi JSON hasil analisa AI (mentah, sudah di-unescape)
   int      http_status;      // status HTTP percobaan TERAKHIR (untuk debug/log)
   bool     used_reserve_key; // true kalau yang berhasil menjawab adalah slot cadangan (11)
   string   error_message;    // penjelasan singkat kalau success = false
};

//+------------------------------------------------------------------+
//| CGroqClient - pengelola koneksi Groq API bersama                   |
//+------------------------------------------------------------------+
class CGroqClient
{
private:
   string      m_api_keys[GROQ_TOTAL_SLOTS];   // 12 API key, index 0..11
   bool        m_key_filled[GROQ_TOTAL_SLOTS]; // true kalau slot itu diisi user (bukan string kosong)
   datetime    m_cooldown_until[GROQ_TOTAL_SLOTS]; // slot ini "istirahat" sampai jam berapa (rate limit)

   string      m_base_url;
   string      m_model;
   int         m_max_tokens;
   double      m_temperature;
   int         m_timeout_ms;

   // --- Mode PROXY (Cloudflare Worker): 1 request -> Worker memanggil Groq paralel ---
   bool        m_use_proxy;
   string      m_proxy_url;
   string      m_proxy_token;

   //+---------------------------------------------------------------+
   //| Escape teks biasa supaya aman ditaruh sebagai value JSON        |
   //+---------------------------------------------------------------+
   // PENJELASAN: urutan penggantian TIDAK BOLEH diacak -- backslash wajib
   // diganti PALING AWAL, supaya backslash baru yang ditambahkan pada
   // langkah berikutnya (untuk kutip/baris baru) tidak ikut ke-escape lagi.
   string JsonEscape(const string text)
   {
      string result = text;
      StringReplace(result, "\\", "\\\\");
      StringReplace(result, "\"", "\\\"");
      StringReplace(result, "\r", "");
      StringReplace(result, "\n", "\\n");
      StringReplace(result, "\t", "\\t");
      return result;
   }

   //+---------------------------------------------------------------+
   //| Bongkar field "content" dari amplop chat.completions Groq/OpenAI |
   //+---------------------------------------------------------------+
   // PENJELASAN: balasan mentah Groq berbentuk:
   //   {"choices":[{"message":{"content":"{\"signal\":\"BUY\",...}"}}]}
   // JSON hasil analisa AI yang sebenarnya ada DI DALAM field "content"
   // sebagai teks ter-escape. Fungsi ini membongkarnya karakter demi
   // karakter (bukan regex, MQL5 tidak punya regex native) supaya escape
   // sequence (\", \\, \n, \t) diproses dengan benar.
   string ExtractMessageContent(const string api_response)
   {
      string marker = "\"content\":\"";
      int start = StringFind(api_response, marker);
      if(start < 0) return "";
      start += StringLen(marker);

      int len = StringLen(api_response);
      string content = "";
      int i = start;
      while(i < len)
      {
         ushort ch = StringGetCharacter(api_response, i);

         if(ch == '\\' && i + 1 < len)
         {
            ushort next = StringGetCharacter(api_response, i + 1);
            if(next == '"')  { content += "\""; i += 2; continue; }
            if(next == '\\') { content += "\\"; i += 2; continue; }
            if(next == 'n')  { content += "\n"; i += 2; continue; }
            if(next == 't')  { content += "\t"; i += 2; continue; }
            if(next == 'r')  { i += 2; continue; }
            // Escape sequence tidak dikenal -> lewati backslash-nya saja
            i += 1;
            continue;
         }

         if(ch == '"') break; // tanda kutip TANPA backslash = akhir string

         content += StringSubstr(api_response, i, 1);
         i++;
      }

      return content;
   }

   //+---------------------------------------------------------------+
   //| Cari nilai header "retry-after" (detik) dari response headers   |
   //+---------------------------------------------------------------+
   int ExtractRetryAfterSeconds(const string response_headers)
   {
      string lower_headers = response_headers;
      StringToLower(lower_headers);

      int pos = StringFind(lower_headers, "retry-after:");
      if(pos < 0) return 0;

      pos += StringLen("retry-after:");
      // Lewati spasi setelah titik dua
      while(pos < StringLen(lower_headers) && StringGetCharacter(lower_headers, pos) == ' ')
         pos++;

      string value = "";
      while(pos < StringLen(lower_headers))
      {
         ushort ch = StringGetCharacter(lower_headers, pos);
         if(ch == '\r' || ch == '\n') break;
         value += StringSubstr(lower_headers, pos, 1);
         pos++;
      }

      int seconds = (int)StringToInteger(value);
      return MathMax(0, seconds);
   }

   //+---------------------------------------------------------------+
   //| Kirim satu kali request HTTP POST ke Groq chat/completions      |
   //+---------------------------------------------------------------+
   int SendRequest(const string api_key, const string payload, string &out_body, string &out_headers)
   {
      string url = m_base_url + "chat/completions";

      char post_data[];
      StringToCharArray(payload, post_data, 0, StringLen(payload));

      char result[];
      string request_headers = "Authorization: Bearer " + api_key + "\r\n" +
                                "Content-Type: application/json\r\n";
      out_headers = "";

      ResetLastError();
      int status = WebRequest("POST", url, request_headers, m_timeout_ms, post_data, result, out_headers);

      if(status < 0)
      {
         Print("GroqClient: WebRequest gagal total (error=", GetLastError(),
               "). Cek apakah https://api.groq.com sudah diizinkan di Tools > Options > Expert Advisors > Allow WebRequest.");
         out_body = "";
         return -1;
      }

      out_body = (ArraySize(result) > 0) ? CharArrayToString(result) : "";
      return status;
   }

   //+---------------------------------------------------------------+
   //| Bangun payload JSON chat/completions siap kirim                 |
   //+---------------------------------------------------------------+
   string BuildPayload(const string system_prompt, const string user_prompt)
   {
      string safe_system = JsonEscape(system_prompt);
      string safe_user   = JsonEscape(user_prompt);

      string payload = "{";
      payload += "\"model\":\"" + m_model + "\",";
      payload += "\"messages\":[";
      payload += "{\"role\":\"system\",\"content\":\"" + safe_system + "\"},";
      payload += "{\"role\":\"user\",\"content\":\"" + safe_user + "\"}";
      payload += "],";
      payload += "\"max_tokens\":" + IntegerToString(m_max_tokens) + ",";
      payload += "\"temperature\":" + DoubleToString(m_temperature, 2) + ",";
      // PENJELASAN FIX: openai/gpt-oss-120b adalah model reasoning -- dia
      // "berpikir" dulu (memakai sebagian max_tokens) sebelum menulis
      // jawaban akhir. Kalau reasoning_effort dibiarkan default ("medium"),
      // pada prompt yang kompleks (terutama AI Penyimpul yang merangkum 10
      // opini) token bisa habis duluan di fase reasoning sebelum sempat
      // menulis JSON -> Groq balas HTTP 400 "json_validate_failed" dengan
      // failed_generation KOSONG (bukan salah format, tapi memang belum
      // sempat menulis apa-apa). "low" mengurangi token yang dipakai untuk
      // reasoning, menyisakan lebih banyak jatah untuk JSON akhir.
      payload += "\"reasoning_effort\":\"low\",";
      payload += "\"response_format\":{\"type\":\"json_object\"}";
      payload += "}";

      return payload;
   }

   //+---------------------------------------------------------------+
   //| BLOK PROXY: helper komunikasi ke Cloudflare Worker                |
   //+---------------------------------------------------------------+
   bool AnyDirectKeyFilled()
   {
      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
         if(m_key_filled[i]) return true;
      return false;
   }

   // Body request untuk 1 panggilan tunggal ke Worker (/call)
   string BuildProxyCallBody(const string system_prompt, const string user_prompt)
   {
      string b = "{";
      b += "\"model\":\"" + m_model + "\",";
      b += "\"max_tokens\":" + IntegerToString(m_max_tokens) + ",";
      b += "\"temperature\":" + DoubleToString(m_temperature, 2) + ",";
      b += "\"system\":\"" + JsonEscape(system_prompt) + "\",";
      b += "\"user\":\"" + JsonEscape(user_prompt) + "\"";
      b += "}";
      return b;
   }

   // Kirim POST ke Worker. Mengembalikan status HTTP (-1 = gagal total)
   int SendProxyRequest(const string path, const string body, const int timeout_ms, string &out_body)
   {
      char post_data[];
      StringToCharArray(body, post_data, 0, StringLen(body), CP_UTF8);

      char result[];
      string request_headers = "Content-Type: application/json\r\n" +
                                "X-EA-Token: " + m_proxy_token + "\r\n";
      string response_headers = "";

      ResetLastError();
      int status = WebRequest("POST", m_proxy_url + path, request_headers, timeout_ms,
                               post_data, result, response_headers);

      if(status < 0)
      {
         Print("GroqClient[PROXY]: WebRequest gagal total (error=", GetLastError(),
               "). Pastikan URL Worker sudah diizinkan di Tools > Options > Expert Advisors > Allow WebRequest.");
         out_body = "";
         return -1;
      }

      out_body = (ArraySize(result) > 0) ? CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8) : "";
      return status;
   }

   bool ProxyCall(const string system_prompt, const string user_prompt, GroqCallResult &result)
   {
      string body = "";
      int status = SendProxyRequest("/call", BuildProxyCallBody(system_prompt, user_prompt),
                                     m_timeout_ms + 15000, body);
      result.http_status = status;

      if(status == 200 && StringFind(body, "\"ok\":true") >= 0)
      {
         string inner = ExtractMessageContent(body);
         if(inner != "")
         {
            result.success = true;
            result.content = inner;
            result.error_message = "";
            return true;
         }
         result.success = false;
         result.error_message = "Proxy HTTP 200 tapi field content kosong";
         return false;
      }

      result.success = false;
      result.error_message = "Proxy HTTP status " + IntegerToString(status);
      return false;
   }

   //+---------------------------------------------------------------+
   //| Coba satu slot key tertentu. Mengisi cooldown kalau kena limit  |
   //+---------------------------------------------------------------+
   bool TryOneSlot(const int slot, const string payload, GroqCallResult &result)
   {
      string body = "";
      string headers = "";
      int status = SendRequest(m_api_keys[slot], payload, body, headers);

      result.http_status = status;

      if(status == 200 && body != "")
      {
         string inner = ExtractMessageContent(body);
         if(inner == "")
         {
            result.success = false;
            result.error_message = "HTTP 200 tapi gagal membongkar field content (format respons berubah?)";
            return false;
         }

         result.success = true;
         result.content = inner;
         result.error_message = "";
         return true;
      }

      // HTTP 429 = rate limited -> catat cooldown slot ini sesuai header retry-after
      if(status == 429)
      {
         int retry_after = ExtractRetryAfterSeconds(headers);
         if(retry_after <= 0) retry_after = 30; // fallback aman kalau header tidak ada
         m_cooldown_until[slot] = TimeCurrent() + retry_after;

         Print("GroqClient: slot ", slot, " kena rate limit (429), cooldown ", retry_after, " detik.");
      }
      else if(status != 200)
      {
         string snippet = (StringLen(body) > 200) ? StringSubstr(body, 0, 200) : body;
         Print("GroqClient: slot ", slot, " gagal, HTTP status=", status, " body=", snippet);
      }

      result.success = false;
      result.error_message = "HTTP status " + IntegerToString(status);
      return false;
   }

public:
   //+---------------------------------------------------------------+
   //| Constructor - nilai default aman kalau belum di-Initialize()    |
   //+---------------------------------------------------------------+
   CGroqClient()
   {
      m_base_url    = "https://api.groq.com/openai/v1/";
      m_use_proxy   = false;
      m_proxy_url   = "";
      m_proxy_token = "";
      m_model       = "openai/gpt-oss-120b";
      m_max_tokens  = 1000;
      m_temperature = 0.3;
      m_timeout_ms  = 30000;

      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
      {
         m_api_keys[i]        = "";
         m_key_filled[i]      = false;
         m_cooldown_until[i]  = 0;
      }
   }

   //+---------------------------------------------------------------+
   //| Inisialisasi dengan 12 API key + parameter model                |
   //+---------------------------------------------------------------+
   // PENJELASAN: dipanggil dari OnInit() EA utama, isi keys[0..11] persis
   // urutan slot (0-9 analis, 10 penyimpul, 11 cadangan). String kosong
   // untuk slot yang memang belum diisi user dianggap valid (slot itu
   // otomatis dilewati saat Call() dipanggil untuknya, lihat catatan di
   // Call()).
   void Initialize(string &keys[], const string model = "openai/gpt-oss-120b",
                    const int max_tokens = 1000, const double temperature = 0.3,
                    const int timeout_ms = 30000)
   {
      m_model       = model;
      m_max_tokens  = max_tokens;
      m_temperature = temperature;
      m_timeout_ms  = timeout_ms;

      int count = MathMin(ArraySize(keys), GROQ_TOTAL_SLOTS);
      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
      {
         m_api_keys[i]   = (i < count) ? keys[i] : "";
         m_key_filled[i] = (StringLen(m_api_keys[i]) > 0);
         m_cooldown_until[i] = 0;
      }

      if(!m_use_proxy && !m_key_filled[GROQ_RESERVE_SLOT])
      {
         Print("GroqClient PERINGATAN: slot cadangan (slot 12) kosong. ",
               "Kalau salah satu dari 11 slot lain kena rate limit, TIDAK ADA fallback.");
      }

      int filled_count = 0;
      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
         if(m_key_filled[i]) filled_count++;

      Print("GroqClient: Initialize selesai. ", filled_count, "/", GROQ_TOTAL_SLOTS, " slot API key terisi.");
   }

   //+---------------------------------------------------------------+
   //| Apakah slot tertentu sedang dalam masa cooldown (rate limit)?   |
   //+---------------------------------------------------------------+
   bool IsSlotCoolingDown(const int slot)
   {
      if(slot < 0 || slot >= GROQ_TOTAL_SLOTS) return true;
      return TimeCurrent() < m_cooldown_until[slot];
   }

   //+---------------------------------------------------------------+
   //| MODE PROXY: SetProxy / IsProxyEnabled / CallBatch                |
   //+---------------------------------------------------------------+
   // PENJELASAN: kalau URL Worker diisi, EA memanggil Worker (bukan Groq
   // langsung). Worker memegang API key (tidak ada key di kode/EA) dan
   // memanggil 10 analis SECARA PARALEL, jadi total tunggu ~1 panggilan,
   // bukan 10 panggilan berurutan.
   void SetProxy(const string url, const string token)
   {
      string u = url;
      StringTrimLeft(u);
      StringTrimRight(u);
      while(StringLen(u) > 0 && StringGetCharacter(u, StringLen(u) - 1) == '/')
         u = StringSubstr(u, 0, StringLen(u) - 1);

      m_proxy_url   = u;
      m_proxy_token = token;
      m_use_proxy   = (StringLen(u) > 0);

      if(m_use_proxy)
         Print("GroqClient: mode PROXY aktif -> ", m_proxy_url);
   }

   bool IsProxyEnabled() { return m_use_proxy; }

   // Panggil N analis sekaligus lewat Worker (/analysts).
   // results[] selalu berukuran N; item gagal ditandai success=false.
   bool CallBatch(const string &system_prompts[], const string &user_prompts[], GroqCallResult &results[])
   {
      int n = MathMin(ArraySize(system_prompts), ArraySize(user_prompts));
      ArrayResize(results, n);
      for(int i = 0; i < n; i++)
      {
         results[i].success          = false;
         results[i].content          = "";
         results[i].http_status      = 0;
         results[i].used_reserve_key = false;
         results[i].error_message    = "Belum dipanggil";
      }
      if(!m_use_proxy || n <= 0) return false;

      string b = "{";
      b += "\"model\":\"" + m_model + "\",";
      b += "\"max_tokens\":" + IntegerToString(m_max_tokens) + ",";
      b += "\"temperature\":" + DoubleToString(m_temperature, 2) + ",";
      b += "\"items\":[";
      for(int i = 0; i < n; i++)
      {
         if(i > 0) b += ",";
         b += "{\"system\":\"" + JsonEscape(system_prompts[i]) + "\",";
         b += "\"user\":\"" + JsonEscape(user_prompts[i]) + "\"}";
      }
      b += "]}";

      string body = "";
      int status = SendProxyRequest("/analysts", b, m_timeout_ms * 2, body);

      if(status != 200 || body == "")
      {
         for(int i = 0; i < n; i++)
         {
            results[i].http_status   = status;
            results[i].error_message = "Proxy batch HTTP status " + IntegerToString(status);
         }
         Print("GroqClient[PROXY]: batch gagal, HTTP status=", status);
         return false;
      }

      // Pecah respons: tiap item diawali {"ok":
      string marker = "{\"ok\":";
      int starts[];
      ArrayResize(starts, 0);
      int pos = 0;
      while(true)
      {
         int p = StringFind(body, marker, pos);
         if(p < 0) break;
         int sz = ArraySize(starts);
         ArrayResize(starts, sz + 1);
         starts[sz] = p;
         pos = p + StringLen(marker);
      }

      int found = ArraySize(starts);
      int total_len = StringLen(body);
      for(int i = 0; i < n && i < found; i++)
      {
         int seg_end = (i + 1 < found) ? starts[i + 1] : total_len;
         string seg = StringSubstr(body, starts[i], seg_end - starts[i]);

         results[i].http_status = 200;
         if(StringFind(seg, "{\"ok\":true") == 0)
         {
            string inner = ExtractMessageContent(seg);
            if(inner != "")
            {
               results[i].success       = true;
               results[i].content       = inner;
               results[i].error_message = "";
               continue;
            }
            results[i].error_message = "Proxy item ok tapi content kosong";
         }
         else
         {
            results[i].error_message = "Proxy item gagal (Groq menolak/limit)";
         }
      }

      return true;
   }

   //+---------------------------------------------------------------+
   //| Panggilan utama - satu-satunya fungsi yang dipakai pemanggil    |
   //+---------------------------------------------------------------+
   // PARAMETER:
   //   slot          -> 0-9 untuk analis ke-(slot+1), 10 untuk Penyimpul.
   //                    JANGAN pernah panggil dengan slot=11 (GROQ_RESERVE_SLOT)
   //                    secara langsung dari luar -- itu murni cadangan internal.
   //   system_prompt -> instruksi peran AI (system message)
   //   user_prompt   -> data pasar & pertanyaan analisa (user message)
   //
   // ALUR:
   //   1. Kalau slot utama kosong (belum diisi user) atau sedang cooldown,
   //      langsung lompat ke slot cadangan (11) tanpa buang waktu mencoba
   //      slot yang sudah diketahui akan gagal.
   //   2. Kalau slot utama tersedia, coba dulu. Kalau gagal (429/error apa
   //      pun) DAN itu bukan slot cadangan itu sendiri, otomatis retry satu
   //      kali pakai slot cadangan (11).
   //   3. Kalau slot cadangan juga gagal/kosong -> result.success = false,
   //      pemanggil WAJIB menangani ini (skip opini analis tsb di siklus
   //      ini, jangan dianggap error fatal EA).
   GroqCallResult Call(const int slot, const string system_prompt, const string user_prompt,
                        const bool skip_proxy = false)
   {
      GroqCallResult result;
      result.success          = false;
      result.content          = "";
      result.http_status      = 0;
      result.used_reserve_key = false;
      result.error_message    = "";

      if(slot < 0 || slot >= GROQ_TOTAL_SLOTS)
      {
         result.error_message = "Nomor slot tidak valid: " + IntegerToString(slot);
         Print("GroqClient: ", result.error_message);
         return result;
      }

      // Mode PROXY: coba Worker dulu. Kalau gagal dan ada key langsung -> lanjut jalur lama.
      if(m_use_proxy && !skip_proxy)
      {
         if(ProxyCall(system_prompt, user_prompt, result))
         {
            result.used_reserve_key = false;
            return result;
         }
         if(!AnyDirectKeyFilled())
         {
            Print("GroqClient: proxy gagal (", result.error_message,
                  ") dan tidak ada API key langsung sebagai cadangan.");
            return result;
         }
         Print("GroqClient: proxy gagal (", result.error_message, "), mencoba key langsung...");
      }

      string payload = BuildPayload(system_prompt, user_prompt);

      bool primary_usable = m_key_filled[slot] && !IsSlotCoolingDown(slot);
      bool primary_is_reserve = (slot == GROQ_RESERVE_SLOT);

      if(primary_usable)
      {
         if(TryOneSlot(slot, payload, result))
         {
            result.used_reserve_key = primary_is_reserve;
            return result;
         }
      }
      else if(!m_key_filled[slot])
      {
         result.error_message = "Slot " + IntegerToString(slot) + " belum diisi API key.";
      }
      else
      {
         result.error_message = "Slot " + IntegerToString(slot) + " sedang cooldown rate limit.";
      }

      // Primary gagal/tidak tersedia -> coba cadangan, KECUALI slot yang
      // diminta memang sudah slot cadangan itu sendiri (hindari panggil 2x).
      if(!primary_is_reserve)
      {
         bool reserve_usable = m_key_filled[GROQ_RESERVE_SLOT] && !IsSlotCoolingDown(GROQ_RESERVE_SLOT);
         if(reserve_usable)
         {
            Print("GroqClient: slot ", slot, " gagal (", result.error_message,
                  "), mencoba slot cadangan (12)...");

            GroqCallResult reserve_result;
            if(TryOneSlot(GROQ_RESERVE_SLOT, payload, reserve_result))
            {
               reserve_result.used_reserve_key = true;
               return reserve_result;
            }

            result = reserve_result;
            result.used_reserve_key = true;
         }
      }

      if(!result.success)
      {
         Print("GroqClient: panggilan untuk slot ", slot, " gagal total (primer & cadangan). ",
               "Detail: ", result.error_message);
      }

      return result;
   }
};
